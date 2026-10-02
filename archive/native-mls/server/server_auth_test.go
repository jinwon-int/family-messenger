// C1 caller-authentication tests (#177 §3 "CF Access JWT → actor"). The
// verifier is exercised directly with tokens minted here (ES256 and RS256,
// stdlib only) and the routes are driven over httptest with a device-policy
// chain whose subjects the tokens must match. Pinned: missing/invalid token
// → bare 401 on every contract route, subject mismatch / unknown / revoked
// device → one indistinguishable 403, Bearer fallback, JWKS reload on an
// unknown kid at most once a minute, and the /close member gate.
package main

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jinwon-int/family-messenger/archive/native-mls/server/internal/devicepolicy"
)

const (
	testIssuerURL = "https://family-test.cloudflareaccess.com"
	testAudience  = "native-mls-v2-relay-test"
)

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// testIssuer stands in for Cloudflare Access: one ES256 key (plus optional
// extra keys) published as a JWKS file, and token minting per subject.
type testIssuer struct {
	t        *testing.T
	key      *ecdsa.PrivateKey
	kid      string
	jwksPath string
	extra    []map[string]string
}

func newTestIssuer(t *testing.T) *testIssuer {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate ES256 key: %v", err)
	}
	i := &testIssuer{t: t, key: key, kid: "test-es256", jwksPath: filepath.Join(t.TempDir(), "jwks.json")}
	i.writeJWKS()
	return i
}

func ecJWK(kid string, pub *ecdsa.PublicKey) map[string]string {
	x := make([]byte, 32)
	y := make([]byte, 32)
	pub.X.FillBytes(x)
	pub.Y.FillBytes(y)
	return map[string]string{"kty": "EC", "crv": "P-256", "kid": kid, "alg": "ES256", "use": "sig", "x": b64url(x), "y": b64url(y)}
}

func (i *testIssuer) writeJWKS() {
	i.t.Helper()
	keys := append([]map[string]string{ecJWK(i.kid, &i.key.PublicKey)}, i.extra...)
	raw, err := json.Marshal(map[string]any{"keys": keys})
	if err != nil {
		i.t.Fatal(err)
	}
	if err := os.WriteFile(i.jwksPath, raw, 0o600); err != nil {
		i.t.Fatal(err)
	}
}

// signES256 produces header.payload.signature with the issuer's key (or an
// arbitrary key when given), raw r||s signature as JOSE requires.
func signES256(t *testing.T, key *ecdsa.PrivateKey, header, claims map[string]any) string {
	t.Helper()
	h, err := json.Marshal(header)
	if err != nil {
		t.Fatal(err)
	}
	c, err := json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}
	input := b64url(h) + "." + b64url(c)
	digest := sha256.Sum256([]byte(input))
	r, s, err := ecdsa.Sign(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return input + "." + b64url(sig)
}

func baseClaims(sub string) map[string]any {
	now := time.Now().Unix()
	return map[string]any{"iss": testIssuerURL, "aud": []string{testAudience}, "sub": sub, "iat": now, "nbf": now, "exp": now + 600}
}

// mint returns a valid token for sub, with mutate applied to the claims.
func (i *testIssuer) mint(sub string, mutate func(map[string]any)) string {
	claims := baseClaims(sub)
	if mutate != nil {
		mutate(claims)
	}
	return signES256(i.t, i.key, map[string]any{"alg": "ES256", "typ": "JWT", "kid": i.kid}, claims)
}

func (i *testIssuer) verifier() *accessVerifier {
	i.t.Helper()
	v, err := newAccessVerifier(testIssuerURL, testAudience, i.jwksPath)
	if err != nil {
		i.t.Fatalf("new verifier: %v", err)
	}
	return v
}

func TestAccessVerifierClaims(t *testing.T) {
	iss := newTestIssuer(t)
	v := iss.verifier()

	claims, err := v.verify(iss.mint("subject-alice", nil))
	if err != nil || claims.Subject != "subject-alice" {
		t.Fatalf("valid token: claims=%+v err=%v", claims, err)
	}
	if _, err := v.verify(iss.mint("s", func(c map[string]any) { c["aud"] = testAudience })); err != nil {
		t.Fatalf("aud as a plain string must verify: %v", err)
	}
	if _, err := v.verify(iss.mint("s", func(c map[string]any) { c["exp"] = time.Now().Unix() - 30 })); err != nil {
		t.Fatalf("exp 30s ago is inside the 60s leeway: %v", err)
	}
	if _, err := v.verify(iss.mint("s", func(c map[string]any) { c["nbf"] = time.Now().Unix() + 30 })); err != nil {
		t.Fatalf("nbf 30s ahead is inside the 60s leeway: %v", err)
	}

	bad := map[string]func(map[string]any){
		"expired":        func(c map[string]any) { c["exp"] = time.Now().Unix() - 120 },
		"missing exp":    func(c map[string]any) { delete(c, "exp") },
		"not yet valid":  func(c map[string]any) { c["nbf"] = time.Now().Unix() + 120 },
		"wrong aud":      func(c map[string]any) { c["aud"] = []string{"someone-else"} },
		"wrong iss":      func(c map[string]any) { c["iss"] = "https://evil.example" },
		"empty sub":      func(c map[string]any) { c["sub"] = "" },
		"missing sub":    func(c map[string]any) { delete(c, "sub") },
		"missing aud":    func(c map[string]any) { delete(c, "aud") },
		"audience empty": func(c map[string]any) { c["aud"] = []string{} },
	}
	for name, mutate := range bad {
		if _, err := v.verify(iss.mint("s", mutate)); !errors.Is(err, errUnauthorized) {
			t.Fatalf("%s: err=%v, want errUnauthorized", name, err)
		}
	}

	// Signature and structure faults.
	otherKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	forged := signES256(t, otherKey, map[string]any{"alg": "ES256", "kid": iss.kid}, baseClaims("s"))
	if _, err := v.verify(forged); !errors.Is(err, errUnauthorized) {
		t.Fatalf("wrong key under a known kid: err=%v", err)
	}
	if _, err := v.verify(signES256(t, iss.key, map[string]any{"alg": "ES256", "kid": "nope"}, baseClaims("s"))); err == nil || !strings.Contains(err.Error(), "unknown kid") {
		t.Fatalf("unknown kid: err=%v", err)
	}
	for _, alg := range []string{"none", "HS256", "RS256"} {
		if _, err := v.verify(signES256(t, iss.key, map[string]any{"alg": alg, "kid": iss.kid}, baseClaims("s"))); !errors.Is(err, errUnauthorized) {
			t.Fatalf("alg %s with an EC key: err=%v", alg, err)
		}
	}
	valid := iss.mint("s", nil)
	parts := strings.Split(valid, ".")
	tampered := parts[0] + "." + b64url([]byte(`{"iss":"`+testIssuerURL+`","aud":["`+testAudience+`"],"sub":"mallory","exp":9999999999}`)) + "." + parts[2]
	if _, err := v.verify(tampered); !errors.Is(err, errUnauthorized) {
		t.Fatalf("tampered payload: err=%v", err)
	}
	for _, malformed := range []string{"", "a.b", "a.b.c.d", "!!.!!.!!", parts[0] + "." + parts[1] + ".AAAA"} {
		if _, err := v.verify(malformed); !errors.Is(err, errUnauthorized) {
			t.Fatalf("malformed %q: err=%v", malformed, err)
		}
	}
}

// G-M6: CF Access service tokens (the machine lane — CF-Access-Client-Id/
// Secret headers) mint JWTs with an empty `sub` and the identity in
// `common_name` (the Client-Id). The verifier falls back to it and refuses
// only when neither claim carries an identity; every other check is unchanged.
func TestAccessVerifierServiceTokenShape(t *testing.T) {
	iss := newTestIssuer(t)
	v := iss.verifier()
	service := "97f3e1c2ab5548f0.access"

	claims, err := v.verify(iss.mint("", func(c map[string]any) { c["common_name"] = service }))
	if err != nil || claims.Subject != service {
		t.Fatalf("service-token shape: claims=%+v err=%v", claims, err)
	}
	// The fallback must not depend on CF's optional `token_type` claim.
	claims, err = v.verify(iss.mint("", func(c map[string]any) { c["common_name"] = service; c["token_type"] = "service" }))
	if err != nil || claims.Subject != service {
		t.Fatalf("service-token shape with token_type: claims=%+v err=%v", claims, err)
	}
	// A user token keeps its `sub`; `common_name` never overrides it.
	claims, err = v.verify(iss.mint("subject-alice", func(c map[string]any) { c["common_name"] = service }))
	if err != nil || claims.Subject != "subject-alice" {
		t.Fatalf("sub wins over common_name: claims=%+v err=%v", claims, err)
	}
	// Neither identity: still refused, same as before G-M6.
	if _, err := v.verify(iss.mint("", nil)); !errors.Is(err, errUnauthorized) {
		t.Fatalf("empty sub without common_name: err=%v", err)
	}
	// The fallback rides on a verified token only: `common_name` cannot rescue
	// a token that fails any other check.
	if _, err := v.verify(iss.mint("", func(c map[string]any) { c["common_name"] = service; c["aud"] = []string{"someone-else"} })); !errors.Is(err, errUnauthorized) {
		t.Fatalf("common_name cannot rescue a wrong-aud token: err=%v", err)
	}
	if _, err := v.verify(iss.mint("", func(c map[string]any) { c["common_name"] = service; c["exp"] = time.Now().Unix() - 3600 })); !errors.Is(err, errUnauthorized) {
		t.Fatalf("common_name cannot rescue an expired token: err=%v", err)
	}
}

func TestAccessVerifierRS256(t *testing.T) {
	rsaKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	jwk := map[string]string{"kty": "RSA", "kid": "test-rs256", "alg": "RS256", "use": "sig",
		"n": b64url(rsaKey.N.Bytes()), "e": b64url([]byte{1, 0, 1})}
	path := filepath.Join(t.TempDir(), "jwks.json")
	raw, _ := json.Marshal(map[string]any{"keys": []map[string]string{jwk}})
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	v, err := newAccessVerifier(testIssuerURL, testAudience, path)
	if err != nil {
		t.Fatalf("verifier: %v", err)
	}
	h, _ := json.Marshal(map[string]any{"alg": "RS256", "kid": "test-rs256"})
	c, _ := json.Marshal(baseClaims("subject-rsa"))
	input := b64url(h) + "." + b64url(c)
	digest := sha256.Sum256([]byte(input))
	sig, err := rsa.SignPKCS1v15(rand.Reader, rsaKey, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	claims, err := v.verify(input + "." + b64url(sig))
	if err != nil || claims.Subject != "subject-rsa" {
		t.Fatalf("RS256 token: claims=%+v err=%v", claims, err)
	}
	// ES256 header over an RSA key is refused.
	ecKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if _, err := v.verify(signES256(t, ecKey, map[string]any{"alg": "ES256", "kid": "test-rs256"}, baseClaims("s"))); !errors.Is(err, errUnauthorized) {
		t.Fatalf("ES256 against an RSA kid: err=%v", err)
	}
	// A 1024-bit RSA key is rejected at load time.
	small, _ := rsa.GenerateKey(rand.Reader, 1024)
	jwk["n"] = b64url(small.N.Bytes())
	raw, _ = json.Marshal(map[string]any{"keys": []map[string]string{jwk}})
	if _, err := parseJWKS(raw); err == nil {
		t.Fatal("1024-bit RSA key accepted")
	}
}

func TestAccessVerifierRefreshesOnUnknownKidOncePerMinute(t *testing.T) {
	iss := newTestIssuer(t)
	v := iss.verifier()
	base := time.Now()
	v.now = func() time.Time { return base }

	// A rotated key appears in the JWKS source after the initial load.
	key2, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	iss.extra = append(iss.extra, ecJWK("rotated", &key2.PublicKey))
	iss.writeJWKS()
	token2 := signES256(t, key2, map[string]any{"alg": "ES256", "kid": "rotated"}, baseClaims("s"))
	if _, err := v.verify(token2); err == nil {
		t.Fatal("kid seen within a minute of the last load must not trigger a reload")
	}
	v.now = func() time.Time { return base.Add(2 * time.Minute) }
	if _, err := v.verify(token2); err != nil {
		t.Fatalf("unknown kid after the refresh gap must reload the JWKS: %v", err)
	}
	// Right after that reload a third key is throttled again.
	key3, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	iss.extra = append(iss.extra, ecJWK("rotated-again", &key3.PublicKey))
	iss.writeJWKS()
	token3 := signES256(t, key3, map[string]any{"alg": "ES256", "kid": "rotated-again"}, baseClaims("s"))
	if _, err := v.verify(token3); err == nil {
		t.Fatal("second unknown kid within a minute of the reload must be throttled")
	}
	// A reload failure keeps the previous key set usable.
	v.now = func() time.Time { return base.Add(4 * time.Minute) }
	if err := os.WriteFile(iss.jwksPath, []byte("not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := v.verify(token3); err == nil {
		t.Fatal("broken JWKS source must not admit an unknown kid")
	}
	if _, err := v.verify(token2); err != nil {
		t.Fatalf("previously loaded key must survive a failed reload: %v", err)
	}
}

func TestAccessVerifierFailsClosedOnConfiguration(t *testing.T) {
	dir := t.TempDir()
	if _, err := newAccessVerifier(testIssuerURL, testAudience, filepath.Join(dir, "missing.json")); err == nil {
		t.Fatal("missing JWKS file accepted")
	}
	empty := filepath.Join(dir, "empty.json")
	if err := os.WriteFile(empty, []byte(`{"keys":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := newAccessVerifier(testIssuerURL, testAudience, empty); err == nil {
		t.Fatal("JWKS without usable keys accepted")
	}
	if _, err := newAccessVerifier(testIssuerURL, testAudience, "http://plain.example/certs"); err == nil {
		t.Fatal("plain-http JWKS URL accepted")
	}
	iss := newTestIssuer(t)
	for _, missing := range [][3]string{{"", testAudience, iss.jwksPath}, {testIssuerURL, "", iss.jwksPath}, {testIssuerURL, testAudience, ""}} {
		if _, err := newAccessVerifier(missing[0], missing[1], missing[2]); err == nil {
			t.Fatalf("verifier built with a missing setting: %v", missing)
		}
	}
}

// ---- route gating ----

// newAuthedRelay is newEnforcedRelay plus a CF Access verifier whose tokens
// are minted by the returned issuer. Device subjects in the chain are
// "subject-<actor>" (enrollDevice), so a token's sub picks an actor.
func newAuthedRelay(t *testing.T, pol policy) (*relay, *httptest.Server, *devicepolicy.DevicePolicyStore, map[string]string, *testIssuer) {
	t.Helper()
	r, srv, st, _, first := newEnforcedRelay(t, pol)
	iss := newTestIssuer(t)
	r.access = iss.verifier()
	return r, srv, st, first, iss
}

// doAuth performs one request carrying the CF Access assertion header.
func doAuth(t *testing.T, srv *httptest.Server, method, path string, body []byte, token string) (int, []byte) {
	t.Helper()
	return doHeaders(t, srv, method, path, body, map[string]string{"Cf-Access-Jwt-Assertion": token})
}

func doHeaders(t *testing.T, srv *httptest.Server, method, path string, body []byte, headers map[string]string) (int, []byte) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, srv.URL+path, rd)
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, raw
}

func TestAuthRequiredOnEveryContractRoute(t *testing.T) {
	_, srv, st, first, iss := newAuthedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "a2", "alice")
	enrollDevice(t, st, first, "b1", "bob")
	alice := iss.mint("subject-alice", nil)
	bob := iss.mint("subject-bob", nil)

	boot := postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}), []byte("bootstrap"))
	kp, _ := json.Marshal(keyPackagePost{Device: "a1", Packages: []keyPackageInput{{Ref: "k1", Bytes: []byte("pkg")}}})
	app := postEventBody(t, "a1", "c2", "application", 1, nil, nil, []byte("hello"))

	routes := []struct {
		name, method, path string
		body               []byte
	}{
		{"post events", "POST", "/v2/rooms/r/events", boot},
		{"get events", "GET", "/v2/rooms/r/events?device=a1", nil},
		{"post keypackages", "POST", "/v2/rooms/r/keypackages", kp},
		{"consume keypackage", "GET", "/v2/rooms/r/keypackages?device=b1&consumer=a1", nil},
		{"close", "POST", "/v2/rooms/r/close?device=a1", nil},
	}
	// No token and a garbage token: bare 401, nothing stored.
	for _, rt := range routes {
		code, raw := doJSON(t, srv, rt.method, rt.path, rt.body)
		if code != http.StatusUnauthorized || errField(t, raw) != "unauthorized" {
			t.Fatalf("%s without token: status=%d body=%s", rt.name, code, raw)
		}
		if e := decodeAPIError(t, raw); e.Detail != "" {
			t.Fatalf("%s: 401 body must not carry a reason: %s", rt.name, raw)
		}
		code, raw = doAuth(t, srv, rt.method, rt.path, rt.body, "garbage.token.here")
		if code != http.StatusUnauthorized {
			t.Fatalf("%s with garbage token: status=%d body=%s", rt.name, code, raw)
		}
		code, raw = doAuth(t, srv, rt.method, rt.path, rt.body, iss.mint("subject-alice", func(c map[string]any) { c["exp"] = time.Now().Unix() - 3600 }))
		if code != http.StatusUnauthorized {
			t.Fatalf("%s with expired token: status=%d body=%s", rt.name, code, raw)
		}
	}
	// Health stays open.
	if code, _ := doJSON(t, srv, "GET", "/v2/health", nil); code != http.StatusOK {
		t.Fatalf("health must not require a token: %d", code)
	}

	// Valid token for alice, acting as a1: bootstrap lands; Bearer works too.
	if code, raw := doAuth(t, srv, "POST", "/v2/rooms/r/events", boot, alice); code != http.StatusCreated {
		t.Fatalf("bootstrap as a1: status=%d body=%s", code, raw)
	}
	if code, raw := doHeaders(t, srv, "POST", "/v2/rooms/r/events", app, map[string]string{"Authorization": "Bearer " + alice}); code != http.StatusCreated {
		t.Fatalf("Bearer fallback: status=%d body=%s", code, raw)
	}
	if code, raw := doAuth(t, srv, "POST", "/v2/rooms/r/keypackages", kp, alice); code != http.StatusCreated {
		t.Fatalf("keypackages as a1: status=%d body=%s", code, raw)
	}
	if code, raw := doAuth(t, srv, "GET", "/v2/rooms/r/events?device=a1", nil, alice); code != http.StatusOK {
		t.Fatalf("get as a1: status=%d body=%s", code, raw)
	}

	// Subject mismatch: bob's token acting as a1 — one 403 on every route,
	// and the same 403 for an unknown device under a valid token.
	mismatch := []struct {
		name, method, path string
		body               []byte
		token              string
	}{
		{"post events as a1 with bob", "POST", "/v2/rooms/r/events", postEventBody(t, "a1", "x1", "application", 1, nil, nil, []byte("x")), bob},
		{"get events as a1 with bob", "GET", "/v2/rooms/r/events?device=a1", nil, bob},
		{"post keypackages as a1 with bob", "POST", "/v2/rooms/r/keypackages", kp, bob},
		{"consume as a1 with bob", "GET", "/v2/rooms/r/keypackages?device=a1&consumer=a1", nil, bob},
		{"close as a1 with bob", "POST", "/v2/rooms/r/close?device=a1", nil, bob},
		{"unknown device with alice", "POST", "/v2/rooms/r/events", postEventBody(t, "ghost", "g1", "application", 1, nil, nil, []byte("x")), alice},
		{"unknown device get with alice", "GET", "/v2/rooms/r/events?device=ghost", nil, alice},
	}
	for _, m := range mismatch {
		code, raw := doAuth(t, srv, m.method, m.path, m.body, m.token)
		if code != http.StatusForbidden || errField(t, raw) != "device_subject_mismatch" {
			t.Fatalf("%s: status=%d body=%s", m.name, code, raw)
		}
		if e := decodeAPIError(t, raw); e.Detail != "" {
			t.Fatalf("%s: 403 body must not say which check failed: %s", m.name, raw)
		}
	}
	// The consumer is the bound identity; the target device is not.
	if code, raw := doAuth(t, srv, "GET", "/v2/rooms/r/keypackages?device=a1&consumer=b1", nil, bob); code != http.StatusOK {
		t.Fatalf("b1 consuming a1's package: status=%d body=%s", code, raw)
	}

	// Revoked device under the right subject: the same 403, on GET as well
	// (with authentication on, the deny is no longer POST-only).
	revokeDevice(t, st, "a2")
	if code, raw := doAuth(t, srv, "POST", "/v2/rooms/r/events", postEventBody(t, "a2", "r1", "application", 1, nil, nil, []byte("x")), alice); code != http.StatusForbidden || errField(t, raw) != "device_subject_mismatch" {
		t.Fatalf("revoked a2 post: status=%d body=%s", code, raw)
	}
	if code, raw := doAuth(t, srv, "GET", "/v2/rooms/r/events?device=a2", nil, alice); code != http.StatusForbidden || errField(t, raw) != "device_subject_mismatch" {
		t.Fatalf("revoked a2 get: status=%d body=%s", code, raw)
	}
	// Nothing from the denied calls landed.
	if code, raw := doAuth(t, srv, "GET", "/v2/rooms/r/events?device=a1", nil, alice); code != http.StatusOK {
		t.Fatalf("get as a1: status=%d body=%s", code, raw)
	} else if got := decodeEventsResponse(t, raw); len(got.Events) != 2 {
		t.Fatalf("denied requests wrote events: %+v", got.Events)
	}
}

// G-M6 e2e: a bot device enrolled against its service-token identity — the
// CF Access `common_name` (the Client-Id, carrying a dot) — drives the
// contract routes with an empty-`sub` token, while any other identity stays
// locked out exactly as in TestAuthRequiredOnEveryContractRoute. The machine
// lane changes only which claim names the caller; every binding rule holds.
func TestServiceTokenSubjectBinding(t *testing.T) {
	_, srv, st, first, iss := newAuthedRelay(t, testPolicy())
	service := "97f3e1c2ab5548f0.access"
	enrollDeviceAs(t, st, first, "m1", "botsvc", service)
	enrollDevice(t, st, first, "a1", "alice")
	bot := iss.mint("", func(c map[string]any) { c["common_name"] = service })
	alice := iss.mint("subject-alice", nil)
	nameless := iss.mint("", nil)

	boot := postCommitBody(t, "m1", "c1", 0, nil, membersOf([2]string{"m1", "botsvc"}, [2]string{"a1", "alice"}), []byte("bootstrap"))
	kp, _ := json.Marshal(keyPackagePost{Device: "m1", Packages: []keyPackageInput{{Ref: "k1", Bytes: []byte("pkg")}}})

	// The machine lane works end to end: bootstrap, keypackages, reads.
	if code, raw := doAuth(t, srv, "POST", "/v2/rooms/r/events", boot, bot); code != http.StatusCreated {
		t.Fatalf("bootstrap as m1 (service token): status=%d body=%s", code, raw)
	}
	if code, raw := doAuth(t, srv, "POST", "/v2/rooms/r/keypackages", kp, bot); code != http.StatusCreated {
		t.Fatalf("keypackages as m1: status=%d body=%s", code, raw)
	}
	if code, raw := doAuth(t, srv, "GET", "/v2/rooms/r/events?device=m1", nil, bot); code != http.StatusOK {
		t.Fatalf("get as m1: status=%d body=%s", code, raw)
	}
	if code, raw := doAuth(t, srv, "GET", "/v2/rooms/r/keypackages?device=m1&consumer=a1", nil, alice); code != http.StatusOK {
		t.Fatalf("a1 consuming m1's package: status=%d body=%s", code, raw)
	}
	// Consume binds the consumer, not the target: a1 posts its own package,
	// then the bot consumes it as m1.
	kpA1, _ := json.Marshal(keyPackagePost{Device: "a1", Packages: []keyPackageInput{{Ref: "k2", Bytes: []byte("pkg2")}}})
	if code, raw := doAuth(t, srv, "POST", "/v2/rooms/r/keypackages", kpA1, alice); code != http.StatusCreated {
		t.Fatalf("keypackages as a1: status=%d body=%s", code, raw)
	}
	if code, raw := doAuth(t, srv, "GET", "/v2/rooms/r/keypackages?device=a1&consumer=m1", nil, bot); code != http.StatusOK {
		t.Fatalf("m1 consuming a1's packages: status=%d body=%s", code, raw)
	}

	// The binding is exact and one-sided: the bot's token must not act as
	// alice's device, alice's token must not act as the bot's device — the
	// same 403 (and the same silence about which check failed) either way.
	mismatch := []struct {
		name, method, path string
		body               []byte
		token              string
	}{
		{"post as a1 with bot", "POST", "/v2/rooms/r/events", postEventBody(t, "a1", "x1", "application", 1, nil, nil, []byte("x")), bot},
		{"get as a1 with bot", "GET", "/v2/rooms/r/events?device=a1", nil, bot},
		{"post as m1 with alice", "POST", "/v2/rooms/r/events", postEventBody(t, "m1", "x2", "application", 1, nil, nil, []byte("x")), alice},
		{"get as m1 with alice", "GET", "/v2/rooms/r/events?device=m1", nil, alice},
	}
	for _, m := range mismatch {
		code, raw := doAuth(t, srv, m.method, m.path, m.body, m.token)
		if code != http.StatusForbidden || errField(t, raw) != "device_subject_mismatch" {
			t.Fatalf("%s: status=%d body=%s", m.name, code, raw)
		}
		if e := decodeAPIError(t, raw); e.Detail != "" {
			t.Fatalf("%s: 403 body must not say which check failed: %s", m.name, raw)
		}
	}

	// An empty sub without common_name still 401s: no identity, no access.
	if code, raw := doAuth(t, srv, "POST", "/v2/rooms/r/events", postEventBody(t, "m1", "x3", "application", 1, nil, nil, []byte("x")), nameless); code != http.StatusUnauthorized {
		t.Fatalf("empty sub without common_name: status=%d body=%s", code, raw)
	}
}

func TestCloseRoomRequiresTrackedMember(t *testing.T) {
	_, srv, st, first, iss := newAuthedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "b1", "bob")
	enrollDevice(t, st, first, "c1", "carol")
	alice, bob, carol := iss.mint("subject-alice", nil), iss.mint("subject-bob", nil), iss.mint("subject-carol", nil)

	if code, raw := doAuth(t, srv, "POST", "/v2/rooms/r/events",
		postCommitBody(t, "a1", "c1", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}), []byte("bootstrap")), alice); code != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", code, raw)
	}
	if code, raw := doAuth(t, srv, "POST", "/v2/rooms/nope/close?device=a1", nil, alice); code != http.StatusNotFound || errField(t, raw) != "no_such_room" {
		t.Fatalf("close unknown room: status=%d body=%s", code, raw)
	}
	if code, raw := doAuth(t, srv, "POST", "/v2/rooms/r/close", nil, alice); code != http.StatusBadRequest || errField(t, raw) != "device_required" {
		t.Fatalf("close without device: status=%d body=%s", code, raw)
	}
	// c1 is policy-active and authenticated, but not a member of r.
	if code, raw := doAuth(t, srv, "POST", "/v2/rooms/r/close?device=c1", nil, carol); code != http.StatusForbidden || errField(t, raw) != "not_a_member" {
		t.Fatalf("close by non-member: status=%d body=%s", code, raw)
	}
	if code, raw := doAuth(t, srv, "GET", "/v2/rooms/r/events?device=b1", nil, bob); code != http.StatusOK {
		t.Fatalf("room must still be open after a refused close: status=%d body=%s", code, raw)
	}
	if code, raw := doAuth(t, srv, "POST", "/v2/rooms/r/close?device=b1", nil, bob); code != http.StatusOK {
		t.Fatalf("close by member: status=%d body=%s", code, raw)
	}
	if code, raw := doAuth(t, srv, "GET", "/v2/rooms/r/events?device=a1", nil, alice); code != http.StatusGone || errField(t, raw) != "room_closed" {
		t.Fatalf("get after close: status=%d body=%s", code, raw)
	}
	if code, raw := doAuth(t, srv, "POST", "/v2/rooms/r/events", postEventBody(t, "a1", "c9", "application", 1, nil, nil, []byte("x")), alice); code != http.StatusGone {
		t.Fatalf("post after close: status=%d body=%s", code, raw)
	}
	// Idempotent for a member, still 403 for a non-member.
	if code, raw := doAuth(t, srv, "POST", "/v2/rooms/r/close?device=a1", nil, alice); code != http.StatusOK {
		t.Fatalf("second close by member: status=%d body=%s", code, raw)
	}
	if code, raw := doAuth(t, srv, "POST", "/v2/rooms/r/close?device=c1", nil, carol); code != http.StatusForbidden {
		t.Fatalf("second close by non-member: status=%d body=%s", code, raw)
	}
}

// TestCloseRoomLegacyModeStillNamesTheCaller pins the disabled-auth path:
// without a device store there is no membership to check, but the caller
// still has to name a device and an unknown room is still 404.
func TestCloseRoomLegacyModeStillNamesTheCaller(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", postEventBody(t, "a1", "c1", "application", 0, nil, nil, []byte("x"))); code != http.StatusCreated {
		t.Fatalf("seed: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/close", nil); code != http.StatusBadRequest {
		t.Fatalf("close without device: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/nope/close?device=a1", nil); code != http.StatusNotFound {
		t.Fatalf("close unknown room: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/close?device=a1", nil); code != http.StatusOK {
		t.Fatalf("legacy close: status=%d body=%s", code, raw)
	}
	if code, _ := doJSON(t, srv, "GET", "/v2/rooms/r/events?device=a1", nil); code != http.StatusGone {
		t.Fatalf("get after legacy close: status=%d", code)
	}
}
