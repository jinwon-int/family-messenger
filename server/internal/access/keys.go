package access

import (
	"context"
	"crypto/rsa"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"time"
)

const FetchedKeyLifetime = time.Hour
const KeyFetchTimeout = 3 * time.Second
const MaxJWKSBytes = 64 * 1024

var ErrKeyFetch = errors.New("trusted key acquisition failed; prior policy unchanged")

func keysCurrent(c Config, now time.Time) bool {
	return c.KeysFetchedAt == 0 || (now.Unix() >= c.KeysFetchedAt && now.Unix() < c.KeysExpireAt)
}

// Parse only the CF-documented RSA signing JWK representation. PEM presentation
// fields are bounded opaque JSON, not alternative key sources. No URL or private
// key material is interpreted. The existing JWT library verifies signatures.
func parseKeys(data []byte) (map[string]*rsa.PublicKey, error) {
	if len(data) == 0 || len(data) > MaxJWKSBytes {
		return nil, ErrKeyFetch
	}
	top, e := object(base64.RawURLEncoding.EncodeToString(data))
	if e != nil {
		return nil, ErrKeyFetch
	}
	for k := range top {
		if k != "keys" && k != "public_cert" && k != "public_certs" {
			return nil, ErrKeyFetch
		}
	}
	var items []json.RawMessage
	if json.Unmarshal(top["keys"], &items) != nil || len(items) < 1 || len(items) > 16 {
		return nil, ErrKeyFetch
	}
	w := policyWire{Version: 1, Issuer: "https://synthetic.cloudflareaccess.com", Audience: "synthetic"}
	for _, raw := range items {
		m, e := object(base64.RawURLEncoding.EncodeToString(raw))
		if e != nil || len(m) != 6 {
			return nil, ErrKeyFetch
		}
		values := map[string]string{}
		for _, name := range []string{"kid", "kty", "alg", "use", "e", "n"} {
			var v string
			if json.Unmarshal(m[name], &v) != nil || v == "" {
				return nil, ErrKeyFetch
			}
			values[name] = v
		}
		if values["kty"] != "RSA" || values["alg"] != "RS256" || values["use"] != "sig" || values["e"] != "AQAB" {
			return nil, ErrKeyFetch
		}
		w.Keys = append(w.Keys, publicKey{ID: values["kid"], N: values["n"], E: 65537})
	}
	c, e := w.config()
	if e != nil {
		return nil, ErrKeyFetch
	}
	return c.Keys, nil
}

func keyClient() *http.Client {
	return &http.Client{
		Timeout:       KeyFetchTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		Transport: &http.Transport{
			Proxy:               nil, // No environment proxy or credential-bearing transport inheritance.
			DialContext:         (&net.Dialer{Timeout: KeyFetchTimeout}).DialContext,
			TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
			TLSHandshakeTimeout: KeyFetchTimeout, ResponseHeaderTimeout: KeyFetchTimeout,
			MaxResponseHeaderBytes: 8192, DisableCompression: true, DisableKeepAlives: true,
			MaxConnsPerHost: 1,
		},
	}
}

// FetchKeys performs one explicit trusted management fetch. It never runs from
// Verify or an unknown kid. The caller must CAS against the policy read before
// fetching, so concurrent enrollment/revocation cannot be overwritten.
func FetchKeys(ctx context.Context, c Config) (Config, error) {
	client := keyClient()
	defer client.CloseIdleConnections()
	return fetchKeys(ctx, c, client)
}
func fetchKeys(ctx context.Context, c Config, client *http.Client) (Config, error) {
	c, _, e := clone(c)
	if e != nil {
		return Config{}, e
	}
	started := time.Now()
	// Use request context as well as Client.Timeout to cover body reads. Neither
	// policy nor identity locks are held while waiting on network I/O.
	ctx, cancel := context.WithTimeout(ctx, KeyFetchTimeout)
	defer cancel()
	r, e := http.NewRequestWithContext(ctx, "GET", c.Issuer+"/cdn-cgi/access/certs", nil)
	if e != nil {
		return Config{}, ErrKeyFetch
	}
	r.Header.Set("Accept", "application/json")
	r.Header.Set("Accept-Encoding", "identity")
	resp, e := client.Do(r)
	if e != nil {
		return Config{}, ErrKeyFetch
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || resp.Header.Get("Content-Encoding") != "" || resp.ContentLength > MaxJWKSBytes {
		return Config{}, ErrKeyFetch
	}
	data, e := io.ReadAll(io.LimitReader(resp.Body, MaxJWKSBytes+1))
	if e != nil || len(data) > MaxJWKSBytes || ctx.Err() != nil {
		return Config{}, ErrKeyFetch
	}
	keys, e := parseKeys(data)
	if e != nil {
		return Config{}, e
	}
	c.Keys = keys
	// Start the hard lifetime before the fetch, never extend it via HTTP cache
	// headers, failures, unknown kids or repeated request verification.
	c.KeysFetchedAt = started.Unix()
	c.KeysExpireAt = c.KeysFetchedAt + int64(FetchedKeyLifetime/time.Second)
	return c, nil
}

// AcquireKeys is the CLI transaction: read/compare under lock, fetch without the
// lock, then compare-and-swap the complete configuration. No automatic retry.
func (s *PolicyStore) AcquireKeys(ctx context.Context, expected uint64) (PolicyInfo, error) {
	return s.acquireKeys(ctx, expected, FetchKeys)
}
func (s *PolicyStore) acquireKeys(ctx context.Context, expected uint64, fetch func(context.Context, Config) (Config, error)) (PolicyInfo, error) {
	info, c, e := s.Read()
	if e != nil {
		return PolicyInfo{}, e
	}
	if info.Revision != expected {
		return PolicyInfo{}, ErrPolicyConflict
	}
	c, e = fetch(ctx, c)
	if e != nil {
		return PolicyInfo{}, e
	}
	return s.Commit(expected, c)
}
