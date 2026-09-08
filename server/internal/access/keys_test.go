package access

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func jwks(k *rsa.PublicKey, id string) []byte {
	b, _ := json.Marshal(map[string]any{"keys": []any{map[string]string{"kid": id, "kty": "RSA", "alg": "RS256", "use": "sig", "e": "AQAB", "n": base64.RawURLEncoding.EncodeToString(k.N.Bytes())}}, "public_cert": map[string]string{"cert": "unused"}, "public_certs": []any{}})
	return b
}

// Only this unexported test helper overrides dialing/trust. TLS still verifies
// the configured CF hostname against a generated certificate and root.
func keyTLS(t *testing.T, handler http.Handler, hostname string) (*http.Client, *httptest.Server) {
	t.Helper()
	_, k := fixture(t)
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: hostname}, DNSNames: []string{hostname}, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, e := x509.CreateCertificate(rand.Reader, template, template, &k.PublicKey, k)
	if e != nil {
		t.Fatal(e)
	}
	cert, _ := x509.ParseCertificate(der)
	roots := x509.NewCertPool()
	roots.AddCert(cert)
	server := httptest.NewUnstartedServer(handler)
	server.TLS = &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: k}}}
	server.StartTLS()
	t.Cleanup(server.Close)
	client := keyClient()
	tr := client.Transport.(*http.Transport)
	tr.TLSClientConfig.RootCAs = roots
	tr.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "tcp", server.Listener.Addr().String())
	}
	t.Cleanup(client.CloseIdleConnections)
	return client, server
}

func TestJWKSStrictAndBounded(t *testing.T) {
	c, k := fixture(t)
	good := jwks(&k.PublicKey, "key-1")
	got, e := parseKeys(good)
	if e != nil || got["key-1"].N.Cmp(k.N) != 0 {
		t.Fatal(e)
	}
	invalid := [][]byte{
		[]byte(`{"keys":[]}`), []byte(`{"keys":null}`), append(good, good...), []byte(strings.Repeat("x", MaxJWKSBytes+1)),
		bytes.Replace(good, []byte(`"keys":`), []byte(`"Keys":`), 1),
		bytes.Replace(good, []byte(`"keys":`), []byte(`"keys":[],"keys":`), 1),
	}
	for _, pair := range [][2]string{{`"kid":"key-1"`, `"kid":"key-1","kid":"other"`}, {`"kid":"key-1"`, `"KID":"key-1"`}, {`"alg":"RS256"`, `"alg":"HS256"`}, {`"use":"sig"`, `"use":"enc"`}, {`"e":"AQAB"`, `"e":"AAEAAQ"`}, {`"kty":"RSA"`, `"kty":"EC"`}, {`"kid":"key-1"`, `"kid":"key-1","d":"private"`}, {`"kid":"key-1"`, `"kid":"key-1","x5u":"https://example.invalid"`}} {
		invalid = append(invalid, bytes.Replace(good, []byte(pair[0]), []byte(pair[1]), 1))
	}
	var top map[string]any
	json.Unmarshal(good, &top)
	one := top["keys"].([]any)[0]
	top["keys"] = []any{one, one}
	b, _ := json.Marshal(top)
	invalid = append(invalid, b)
	many := []any{}
	for i := 0; i < 17; i++ {
		many = append(many, one)
	}
	top["keys"] = many
	b, _ = json.Marshal(top)
	invalid = append(invalid, b)
	for i, b := range invalid {
		if _, e := parseKeys(b); e == nil {
			t.Fatalf("invalid case %d accepted", i)
		}
	}
	if c.Keys["key-1"].N.Cmp(k.N) != 0 {
		t.Fatal("mutated source")
	}
}

func TestTrustedKeyFetchTLSAndRequestBoundary(t *testing.T) {
	c, k := fixture(t)
	var hits atomic.Int32
	client, _ := keyTLS(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		if r.Host != "synthetic.cloudflareaccess.com" || r.URL.Path != "/cdn-cgi/access/certs" || r.Method != "GET" || r.URL.RawQuery != "" || r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" {
			t.Error("wrong trusted request boundary")
		}
		w.Header().Set("Cache-Control", "public, max-age=999999999")
		w.Write(jwks(&k.PublicKey, "key-1"))
	}), "synthetic.cloudflareaccess.com")
	fetched, e := fetchKeys(context.Background(), c, client)
	if e != nil || fetched.KeysExpireAt-fetched.KeysFetchedAt != 3600 || fetched.People[0] != c.People[0] || fetched.Audience != c.Audience || fetched.Issuer != c.Issuer {
		t.Fatal("fetch changed authority or deadline", e)
	}
	a, _ := New(fetched)
	for i := 0; i < 20; i++ {
		raw := rawSign(t, `{"alg":"RS256","typ":"JWT","kid":"unknown"}`, `{}`, k)
		if _, e := verify(a, raw); e != ErrDenied {
			t.Fatal("unknown kid accepted")
		}
	}
	if hits.Load() != 1 {
		t.Fatal("request-driven key fetch")
	}
	for _, issuer := range []string{"http://synthetic.cloudflareaccess.com", "https://evil.invalid", "https://synthetic.cloudflareaccess.com@127.0.0.1", "https://synthetic.cloudflareaccess.com/extra", "https://synthetic.cloudflareaccess.com?x=y"} {
		bad := c
		bad.Issuer = issuer
		if _, e := fetchKeys(context.Background(), bad, client); e == nil {
			t.Fatal("bad source accepted")
		}
	}
	if hits.Load() != 1 {
		t.Fatal("invalid issuer made request")
	}
	tr := keyClient().Transport.(*http.Transport)
	if tr.Proxy != nil || tr.TLSClientConfig.InsecureSkipVerify || tr.TLSClientConfig.MinVersion < tls.VersionTLS12 || !tr.DisableCompression || tr.MaxResponseHeaderBytes != 8192 {
		t.Fatal("unsafe default transport")
	}
	for _, kind := range []string{"hostname", "untrusted-root"} {
		t.Run(kind, func(t *testing.T) {
			bad, _ := keyTLS(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("untrusted TLS reached HTTP") }), "wrong.cloudflareaccess.com")
			if kind == "untrusted-root" {
				bad.Transport.(*http.Transport).TLSClientConfig.RootCAs = x509.NewCertPool()
			}
			if _, e := fetchKeys(context.Background(), c, bad); e == nil {
				t.Fatal("bad TLS accepted")
			}
		})
	}
}

func TestKeyFetchFailuresAndLimits(t *testing.T) {
	c, k := fixture(t)
	cases := map[string]http.HandlerFunc{
		"redirect": func(w http.ResponseWriter, r *http.Request) {
			http.Redirect(w, r, "https://other.cloudflareaccess.com/never", 302)
		},
		"status":   func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(503) },
		"oversize": func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(strings.Repeat("x", MaxJWKSBytes+1))) },
		"headers": func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("X-Huge", strings.Repeat("x", 16000))
			w.Write(jwks(&k.PublicKey, "key-1"))
		},
		"encoded": func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Encoding", "gzip")
			w.Write(jwks(&k.PublicKey, "key-1"))
		},
		"empty":     func(w http.ResponseWriter, r *http.Request) {},
		"malformed": func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{"keys":[`)) },
		"truncated": func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Length", "5000")
			w.Write(jwks(&k.PublicKey, "key-1"))
		},
	}
	for name, h := range cases {
		t.Run(name, func(t *testing.T) {
			var hits atomic.Int32
			client, _ := keyTLS(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits.Add(1); h(w, r) }), "synthetic.cloudflareaccess.com")
			if _, e := fetchKeys(context.Background(), c, client); e == nil {
				t.Fatal("bad fetch succeeded")
			}
			if hits.Load() != 1 {
				t.Fatal("redirect/retry followed", hits.Load())
			}
		})
	}
}

func TestKeyFetchCancellationAndSlowBody(t *testing.T) {
	c, _ := fixture(t)
	for _, headers := range []bool{false, true} {
		t.Run(map[bool]string{false: "headers", true: "body"}[headers], func(t *testing.T) {
			client, _ := keyTLS(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if headers {
					w.Write([]byte(`{"keys":`))
					w.(http.Flusher).Flush()
				}
				<-r.Context().Done()
			}), "synthetic.cloudflareaccess.com")
			begin := time.Now()
			if _, e := fetchKeys(context.Background(), c, client); e == nil {
				t.Fatal("stalled fetch succeeded")
			}
			if time.Since(begin) > KeyFetchTimeout+time.Second {
				t.Fatal("fetch exceeded bound")
			}
		})
	}
	client, _ := keyTLS(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("canceled fetch reached server") }), "synthetic.cloudflareaccess.com")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, e := fetchKeys(ctx, c, client); e == nil {
		t.Fatal("canceled request succeeded")
	}
}

func TestFetchedKeyRotationExpiryAndNoFallback(t *testing.T) {
	c, k := fixture(t)
	second, e := rsa.GenerateKey(rand.Reader, 2048)
	if e != nil {
		t.Fatal(e)
	}
	var current atomic.Value
	current.Store(jwks(&k.PublicKey, "key-1"))
	client, _ := keyTLS(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(current.Load().([]byte)) }), "synthetic.cloudflareaccess.com")
	fetched, e := fetchKeys(context.Background(), c, client)
	if e != nil {
		t.Fatal(e)
	}
	a, _ := New(fetched)
	raw := sign(t, values(c), k)
	old, e := verify(a, raw)
	if e != nil {
		t.Fatal(e)
	}
	// Reuse a kid with new material as well as remove the old public key entirely.
	current.Store(jwks(&second.PublicKey, "key-1"))
	rotated, e := fetchKeys(context.Background(), c, client)
	if e != nil {
		t.Fatal(e)
	}
	if a.Replace(rotated) != nil {
		t.Fatal("replace")
	}
	if old.Run(func() error { return nil }) != ErrDenied {
		t.Fatal("old grant revived")
	}
	if _, e := verify(a, raw); e != ErrDenied {
		t.Fatal("old signing key accepted")
	}
	if _, e := verify(a, sign(t, values(c), second)); e != nil {
		t.Fatal("new key denied", e)
	}
	// A valid JWT with a later expiry cannot outlive the acquired key lease.
	rotated.KeysFetchedAt = time.Now().Unix() - 3599
	rotated.KeysExpireAt = rotated.KeysFetchedAt + 3600
	a.Replace(rotated)
	g, e := verify(a, sign(t, values(c), second))
	if e != nil {
		t.Fatal(e)
	}
	time.Sleep(time.Until(time.Unix(rotated.KeysExpireAt, 0)) + 10*time.Millisecond)
	if g.RunOwner(func() error { return nil }) != ErrDenied {
		t.Fatal("expired key grant usable")
	}
	if _, e := verify(a, sign(t, values(c), second)); e != ErrDenied {
		t.Fatal("expired fetched key accepted")
	}
	// No implicit fallback to original pinned configuration after lease expiry.
	if _, e := verify(a, raw); e != ErrDenied {
		t.Fatal("fixture/pin fallback")
	}
	if !keysCurrent(c, time.Now()) {
		t.Fatal("explicit manual pins changed semantics")
	}
}

func TestAcquisitionCASPreservesRevocationAndHistory(t *testing.T) {
	s, c := storePolicy(t)
	s.Commit(0, c)
	before, _ := os.ReadFile(filepath.Join(s.dir, revisionName(1)))
	entered, release := make(chan struct{}), make(chan struct{})
	done := make(chan error, 1)
	go func() {
		_, e := s.acquireKeys(context.Background(), 1, func(ctx context.Context, c Config) (Config, error) {
			close(entered)
			<-release
			c.KeysFetchedAt = time.Now().Unix()
			c.KeysExpireAt = c.KeysFetchedAt + 3600
			return c, nil
		})
		done <- e
	}()
	<-entered
	c.People = c.People[:1]
	if _, e := s.Commit(1, c); e != nil {
		t.Fatal("network held policy lock", e)
	}
	close(release)
	if e := <-done; e != ErrPolicyConflict {
		t.Fatal("stale key fetch overwrote enrollment", e)
	}
	info, latest, e := s.Read()
	if e != nil || info.Revision != 2 || len(latest.People) != 1 {
		t.Fatal("revocation lost")
	}
	after, _ := os.ReadFile(filepath.Join(s.dir, revisionName(1)))
	if !bytes.Equal(before, after) {
		t.Fatal("old policy rewritten")
	}
	called := false
	_, e = s.acquireKeys(context.Background(), 1, func(context.Context, Config) (Config, error) { called = true; return Config{}, nil })
	if e != ErrPolicyConflict || called {
		t.Fatal("stale expected revision fetched")
	}
	_, e = s.acquireKeys(context.Background(), 2, func(context.Context, Config) (Config, error) { return Config{}, ErrKeyFetch })
	if e != ErrKeyFetch {
		t.Fatal(e)
	}
	final, _, _ := s.Read()
	if final != info {
		t.Fatal("failed acquisition changed policy")
	}
}

func TestFetchedKeyPolicyRestartAndLegacyCompatibility(t *testing.T) {
	s, c := storePolicy(t)
	first, e := s.Commit(0, c)
	if e != nil {
		t.Fatal(e)
	}
	legacy, _ := os.ReadFile(filepath.Join(s.dir, revisionName(1)))
	if bytes.Contains(legacy, []byte("keys_fetched_at")) || bytes.Contains(legacy, []byte("keys_expire_at")) {
		t.Fatal("legacy serialization changed")
	}
	// Existing revision format stays byte-compatible because new fields omit zero.
	c.KeysFetchedAt = time.Now().Unix() - 3601
	c.KeysExpireAt = c.KeysFetchedAt + 3600
	if _, e := s.Commit(1, c); e != nil {
		t.Fatal(e)
	}
	m, e := OpenManaged(s.dir)
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	_, k := fixture(t)
	if _, e := verify(m.Authority, sign(t, values(c), k)); e != ErrDenied {
		t.Fatal("restart revived expired keys")
	}
	info, got, e := s.Read()
	if e != nil || info.Revision != 2 || got.KeysExpireAt != c.KeysExpireAt {
		t.Fatal("lease not durable", e)
	}
	retained, _ := os.ReadFile(filepath.Join(s.dir, revisionName(1)))
	if !bytes.Equal(legacy, retained) || first.SHA256 == info.SHA256 {
		t.Fatal("prior history altered")
	}
	for _, times := range [][2]int64{{0, 1}, {1, 0}, {-1, 3599}, {1, 4000}, {253402300799, 253402304399}} {
		bad := c
		bad.KeysFetchedAt, bad.KeysExpireAt = times[0], times[1]
		if _, e := EncodePolicy(bad); e == nil {
			t.Fatal("bad lease accepted")
		}
	}
	b, _ := EncodePolicy(c)
	b = bytes.Replace(b, []byte(`"keys_expire_at":`), []byte(`"Keys_expire_at":`), 1)
	if _, e := ParsePolicy(b); e == nil {
		t.Fatal("lease alias accepted")
	}
}

func TestAcquiredKeysApplyThroughManagedAuthority(t *testing.T) {
	s, c := storePolicy(t)
	_, k := fixture(t)
	s.Commit(0, c)
	m, e := OpenManaged(s.dir)
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	old, _ := verify(m.Authority, sign(t, values(c), k))
	client, _ := keyTLS(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(jwks(&k.PublicKey, "key-1")) }), "synthetic.cloudflareaccess.com")
	info, e := s.acquireKeys(context.Background(), 1, func(ctx context.Context, c Config) (Config, error) { return fetchKeys(ctx, c, client) })
	if e != nil || info.Revision != 2 {
		t.Fatal(e)
	}
	if old.Run(func() error { return nil }) != nil {
		t.Fatal("disk commit falsely treated as live apply")
	}
	if m.Refresh() != nil || old.Run(func() error { return nil }) != ErrDenied {
		t.Fatal("live apply did not retire grants")
	}
	raw := sign(t, values(c), k)
	if _, e := verify(m.Authority, raw); e != nil {
		t.Fatal(e)
	}
	data, _ := EncodePolicy(c)
	if bytes.Contains(data, []byte("keys_fetched")) {
		t.Fatal("source config mutated")
	}
	// A bad fetch cannot extend the hard deadline or mutate the active identity.
	_, e = s.acquireKeys(context.Background(), 2, func(context.Context, Config) (Config, error) { return Config{}, ErrKeyFetch })
	if !errors.Is(e, ErrKeyFetch) {
		t.Fatal(e)
	}
	got, _, _ := s.Read()
	if got != info {
		t.Fatal("failed refresh extended lease")
	}
	if _, e = verify(m.Authority, raw); e != nil {
		t.Fatal("failure unexpectedly replaced still-valid snapshot")
	}
}
