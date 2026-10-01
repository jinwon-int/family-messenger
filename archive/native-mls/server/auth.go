// native-mls v2 relay caller authentication (#177 §3 "CF Access JWT → actor",
// review C1). Cloudflare Access fronts the relay and injects a signed JWT in
// Cf-Access-Jwt-Assertion (Authorization: Bearer is accepted as a tooling
// fallback). The relay verifies it with stdlib crypto only — ES256 or RS256
// against the JWKS the operator points it at — and the handlers then bind
// claims.sub to the device-policy subject of the device the request claims
// to act as. A device id on its own is never trusted.
package main

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	accessModeRequired = "required"
	accessModeDisabled = "disabled"

	// accessLeeway absorbs clock skew between Cloudflare and the relay host
	// on exp/nbf.
	accessLeeway = 60 * time.Second
	// jwksRefreshMinGap bounds how often an unknown kid may trigger a reload
	// of the JWKS source (key rotation without restart, no refresh storms).
	jwksRefreshMinGap = time.Minute
	jwksMaxBytes      = 1 << 20
	minRSABits        = 2048
)

// errUnauthorized wraps every verification failure; handlers answer a bare
// 401 and log the reason, the body never carries it.
var errUnauthorized = errors.New("unauthorized")

func unauthorizedf(format string, args ...any) error {
	return fmt.Errorf("%w: %s", errUnauthorized, fmt.Sprintf(format, args...))
}

// accessClaims is the verified subset of the token the relay acts on.
type accessClaims struct {
	Subject   string
	Issuer    string
	Audience  []string
	ExpiresAt int64
	NotBefore int64
}

// accessVerifier validates CF Access JWTs against an in-memory JWKS cache
// loaded from a file path or an https URL.
type accessVerifier struct {
	issuer   string
	audience string
	source   string
	client   *http.Client
	now      func() time.Time

	mu          sync.Mutex
	keys        map[string]crypto.PublicKey
	lastRefresh time.Time
	// lastAttempt is when a reload was last *started*, successful or not
	// (review 2 G-M5): a broken JWKS source must not be hit once per
	// unknown-kid request, and the fetch itself runs outside mu.
	lastAttempt time.Time
}

// newAccessVerifier loads the JWKS once (fail-closed: an unreadable or empty
// key set refuses to construct) and returns a verifier for the given issuer
// and audience.
func newAccessVerifier(issuer, audience, source string) (*accessVerifier, error) {
	if issuer == "" || audience == "" || source == "" {
		return nil, errors.New("access issuer, audience and jwks source are all required")
	}
	if strings.Contains(source, "://") && !strings.HasPrefix(source, "https://") {
		return nil, errors.New("access jwks URL must be https:// (or a local file path)")
	}
	v := &accessVerifier{
		issuer:   issuer,
		audience: audience,
		source:   source,
		client:   &http.Client{Timeout: 10 * time.Second},
		now:      time.Now,
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if err := v.refreshLocked(); err != nil {
		return nil, err
	}
	if len(v.keys) == 0 {
		return nil, errors.New("access jwks holds no usable ES256/RS256 key with a kid")
	}
	return v, nil
}

func (v *accessVerifier) isURL() bool { return strings.HasPrefix(v.source, "https://") }

// load fetches the raw JWKS document from the configured source.
func (v *accessVerifier) load() ([]byte, error) {
	if !v.isURL() {
		raw, err := os.ReadFile(v.source)
		if err != nil {
			return nil, fmt.Errorf("read jwks file: %w", err)
		}
		if len(raw) > jwksMaxBytes {
			return nil, errors.New("jwks file exceeds 1 MiB")
		}
		return raw, nil
	}
	resp, err := v.client.Get(v.source)
	if err != nil {
		return nil, fmt.Errorf("fetch jwks: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("fetch jwks: status %d", resp.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, jwksMaxBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read jwks body: %w", err)
	}
	if len(raw) > jwksMaxBytes {
		return nil, errors.New("jwks response exceeds 1 MiB")
	}
	return raw, nil
}

// refreshLocked replaces the key cache from the source; the old cache stays
// in place when the reload fails. Caller holds mu (constructor only — the
// request path uses key(), which fetches outside the lock).
func (v *accessVerifier) refreshLocked() error {
	keys, err := v.fetchKeys()
	if err != nil {
		return err
	}
	v.keys = keys
	v.lastRefresh = v.now()
	return nil
}

// fetchKeys loads and parses the source without touching the cache. An empty
// result is an error: a JWKS that lost every usable key must not replace a
// working cache with "nothing verifies" (review 2 L1).
func (v *accessVerifier) fetchKeys() (map[string]crypto.PublicKey, error) {
	raw, err := v.load()
	if err != nil {
		return nil, err
	}
	keys, err := parseJWKS(raw)
	if err != nil {
		return nil, err
	}
	if len(keys) == 0 {
		return nil, errors.New("jwks holds no usable ES256/RS256 key with a kid")
	}
	return keys, nil
}

// jwkWire is the lenient JWKS member shape: issuers add fields freely, so
// unknown keys are ignored rather than rejected (unlike the request bodies).
type jwkWire struct {
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	Alg string `json:"alg"`
	Use string `json:"use"`
	Crv string `json:"crv"`
	X   string `json:"x"`
	Y   string `json:"y"`
	N   string `json:"n"`
	E   string `json:"e"`
}

// parseJWKS extracts every P-256 EC and ≥2048-bit RSA signing key carrying a
// kid. Other key types are skipped; a repeated kid rejects the document.
func parseJWKS(raw []byte) (map[string]crypto.PublicKey, error) {
	var doc struct {
		Keys []jwkWire `json:"keys"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("jwks: %w", err)
	}
	keys := map[string]crypto.PublicKey{}
	for i, k := range doc.Keys {
		if k.Kid == "" || (k.Use != "" && k.Use != "sig") {
			continue
		}
		var pub crypto.PublicKey
		switch k.Kty {
		case "EC":
			if k.Crv != "P-256" || (k.Alg != "" && k.Alg != "ES256") {
				continue
			}
			x, errX := base64.RawURLEncoding.DecodeString(k.X)
			y, errY := base64.RawURLEncoding.DecodeString(k.Y)
			if errX != nil || errY != nil || len(x) != 32 || len(y) != 32 {
				return nil, fmt.Errorf("jwks: keys[%d] has malformed P-256 coordinates", i)
			}
			point := append(append([]byte{4}, x...), y...)
			ec, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), point)
			if err != nil {
				return nil, fmt.Errorf("jwks: keys[%d]: %w", i, err)
			}
			pub = ec
		case "RSA":
			if k.Alg != "" && k.Alg != "RS256" {
				continue
			}
			n, errN := base64.RawURLEncoding.DecodeString(k.N)
			e, errE := base64.RawURLEncoding.DecodeString(k.E)
			if errN != nil || errE != nil || len(n) == 0 || len(e) == 0 || len(e) > 4 {
				return nil, fmt.Errorf("jwks: keys[%d] has malformed RSA parameters", i)
			}
			modulus := new(big.Int).SetBytes(n)
			exponent := int(new(big.Int).SetBytes(e).Int64())
			if modulus.BitLen() < minRSABits || exponent < 3 || exponent%2 == 0 {
				return nil, fmt.Errorf("jwks: keys[%d] RSA key is too small or has a bad exponent", i)
			}
			pub = &rsa.PublicKey{N: modulus, E: exponent}
		default:
			continue
		}
		if _, dup := keys[k.Kid]; dup {
			return nil, fmt.Errorf("jwks: duplicate kid %q", k.Kid)
		}
		keys[k.Kid] = pub
	}
	return keys, nil
}

// key resolves a kid from the cache, reloading the source at most once per
// jwksRefreshMinGap when the kid is unknown (rotation without a restart).
func (v *accessVerifier) key(kid string) (crypto.PublicKey, error) {
	v.mu.Lock()
	if k, ok := v.keys[kid]; ok {
		v.mu.Unlock()
		return k, nil
	}
	now := v.now()
	// The gap is measured from the last attempt, not the last success: a
	// source that is down must not be re-fetched for every unknown kid (the
	// kid is attacker-chosen — it comes before signature verification).
	if now.Sub(v.lastRefresh) < jwksRefreshMinGap || now.Sub(v.lastAttempt) < jwksRefreshMinGap {
		v.mu.Unlock()
		return nil, unauthorizedf("unknown kid")
	}
	v.lastAttempt = now
	v.mu.Unlock()
	// Network/file I/O outside the lock: concurrent requests for known kids
	// keep verifying while this one reloads (at most one reload per gap).
	keys, err := v.fetchKeys()
	v.mu.Lock()
	defer v.mu.Unlock()
	if err != nil {
		return nil, unauthorizedf("unknown kid and jwks refresh failed: %v", err)
	}
	v.keys = keys
	v.lastRefresh = v.now()
	if k, ok := v.keys[kid]; ok {
		return k, nil
	}
	return nil, unauthorizedf("unknown kid")
}

// verify checks structure, signature (ES256/RS256 by kid), iss, aud, exp/nbf
// with leeway and a non-empty sub. Every failure wraps errUnauthorized.
func (v *accessVerifier) verify(token string) (accessClaims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return accessClaims{}, unauthorizedf("malformed token")
	}
	headerRaw, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return accessClaims{}, unauthorizedf("malformed header")
	}
	var header struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}
	if err := json.Unmarshal(headerRaw, &header); err != nil {
		return accessClaims{}, unauthorizedf("malformed header")
	}
	if header.Alg != "ES256" && header.Alg != "RS256" {
		return accessClaims{}, unauthorizedf("unsupported alg")
	}
	if header.Kid == "" {
		return accessClaims{}, unauthorizedf("missing kid")
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return accessClaims{}, unauthorizedf("malformed signature")
	}
	pub, err := v.key(header.Kid)
	if err != nil {
		return accessClaims{}, err
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	switch k := pub.(type) {
	case *ecdsa.PublicKey:
		if header.Alg != "ES256" || len(sig) != 64 {
			return accessClaims{}, unauthorizedf("alg does not match key")
		}
		r := new(big.Int).SetBytes(sig[:32])
		s := new(big.Int).SetBytes(sig[32:])
		if !ecdsa.Verify(k, digest[:], r, s) {
			return accessClaims{}, unauthorizedf("bad signature")
		}
	case *rsa.PublicKey:
		if header.Alg != "RS256" {
			return accessClaims{}, unauthorizedf("alg does not match key")
		}
		if err := rsa.VerifyPKCS1v15(k, crypto.SHA256, digest[:], sig); err != nil {
			return accessClaims{}, unauthorizedf("bad signature")
		}
	default:
		return accessClaims{}, unauthorizedf("unsupported key")
	}

	payloadRaw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return accessClaims{}, unauthorizedf("malformed payload")
	}
	var payload struct {
		Iss string          `json:"iss"`
		Sub string          `json:"sub"`
		Aud json.RawMessage `json:"aud"`
		Exp *float64        `json:"exp"`
		Nbf *float64        `json:"nbf"`
	}
	if err := json.Unmarshal(payloadRaw, &payload); err != nil {
		return accessClaims{}, unauthorizedf("malformed payload")
	}
	claims := accessClaims{Subject: payload.Sub, Issuer: payload.Iss}
	if len(payload.Aud) > 0 {
		var one string
		if err := json.Unmarshal(payload.Aud, &one); err == nil {
			claims.Audience = []string{one}
		} else if err := json.Unmarshal(payload.Aud, &claims.Audience); err != nil {
			return accessClaims{}, unauthorizedf("malformed aud")
		}
	}
	if claims.Issuer != v.issuer {
		return accessClaims{}, unauthorizedf("issuer mismatch")
	}
	audOK := false
	for _, a := range claims.Audience {
		if a == v.audience {
			audOK = true
		}
	}
	if !audOK {
		return accessClaims{}, unauthorizedf("audience mismatch")
	}
	now := v.now()
	if payload.Exp == nil {
		return accessClaims{}, unauthorizedf("missing exp")
	}
	claims.ExpiresAt = int64(*payload.Exp)
	if !now.Before(time.Unix(claims.ExpiresAt, 0).Add(accessLeeway)) {
		return accessClaims{}, unauthorizedf("expired")
	}
	if payload.Nbf != nil {
		claims.NotBefore = int64(*payload.Nbf)
		if now.Add(accessLeeway).Before(time.Unix(claims.NotBefore, 0)) {
			return accessClaims{}, unauthorizedf("not yet valid")
		}
	}
	if claims.Subject == "" {
		return accessClaims{}, unauthorizedf("empty sub")
	}
	return claims, nil
}

// bearerToken extracts the CF Access assertion, falling back to a Bearer
// Authorization header.
func bearerToken(req *http.Request) string {
	if t := strings.TrimSpace(req.Header.Get("Cf-Access-Jwt-Assertion")); t != "" {
		return t
	}
	auth := req.Header.Get("Authorization")
	if len(auth) > 7 && strings.EqualFold(auth[:7], "bearer ") {
		return strings.TrimSpace(auth[7:])
	}
	return ""
}
