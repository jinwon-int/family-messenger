package access

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

var once sync.Once
var key *rsa.PrivateKey

func fixture(t *testing.T) (Config, *rsa.PrivateKey) {
	t.Helper()
	once.Do(func() {
		var e error
		key, e = rsa.GenerateKey(rand.Reader, 2048)
		if e != nil {
			panic(e)
		}
	})
	return Config{Issuer: "https://synthetic.cloudflareaccess.com", Audience: "synthetic-app", Keys: map[string]*rsa.PublicKey{"key-1": &key.PublicKey}, People: []Enrollment{{"person-1", "alice", true}, {"person-2", "bob", false}}}, key
}
func values(c Config) jwt.MapClaims {
	now := time.Now().Unix()
	return jwt.MapClaims{"iss": c.Issuer, "aud": []string{c.Audience}, "sub": "person-1", "type": "app", "iat": now - 1, "nbf": now - 1, "exp": now + 60}
}
func sign(t *testing.T, c jwt.MapClaims, k *rsa.PrivateKey) string {
	t.Helper()
	token := jwt.NewWithClaims(jwt.SigningMethodRS256, c)
	token.Header["kid"] = "key-1"
	raw, e := token.SignedString(k)
	if e != nil {
		t.Fatal(e)
	}
	return raw
}
func verify(a *Authority, raw string) (*Grant, error) {
	r := httptest.NewRequest("GET", "http://127.0.0.1:1/", nil)
	r.Header.Set("Cf-Access-Jwt-Assertion", raw)
	return a.Verify(r)
}
func TestClaimsAndIdentityBoundary(t *testing.T) {
	c, k := fixture(t)
	a, e := New(c)
	if e != nil {
		t.Fatal(e)
	}
	tests := map[string]func(jwt.MapClaims){
		"wrong issuer":               func(m jwt.MapClaims) { m["iss"] = "https://other.cloudflareaccess.com" },
		"wrong audience":             func(m jwt.MapClaims) { m["aud"] = []string{"other"} },
		"missing audience":           func(m jwt.MapClaims) { delete(m, "aud") },
		"expired":                    func(m jwt.MapClaims) { m["exp"] = time.Now().Unix() - 1 },
		"no expiry":                  func(m jwt.MapClaims) { delete(m, "exp") },
		"future nbf":                 func(m jwt.MapClaims) { m["nbf"] = time.Now().Unix() + 30 },
		"future iat":                 func(m jwt.MapClaims) { m["iat"] = time.Now().Unix() + 30 },
		"no iat":                     func(m jwt.MapClaims) { delete(m, "iat") },
		"no nbf":                     func(m jwt.MapClaims) { delete(m, "nbf") },
		"unknown subject":            func(m jwt.MapClaims) { m["sub"] = "other"; m["email"] = "owner@example.invalid" },
		"empty service subject":      func(m jwt.MapClaims) { m["sub"] = ""; m["common_name"] = "machine.access" },
		"service with human subject": func(m jwt.MapClaims) { m["common_name"] = "machine.access" },
		"org token":                  func(m jwt.MapClaims) { m["type"] = "org" },
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			m := values(c)
			mutate(m)
			if _, e := verify(a, sign(t, m, k)); !errors.Is(e, ErrDenied) {
				t.Fatalf("accepted %s: %v", name, e)
			}
		})
	}
	m := values(c)
	m["sub"] = "person-2"
	m["role"] = "owner"
	m["email"] = "owner@example.invalid"
	g, e := verify(a, sign(t, m, k))
	if e != nil || g.Principal() != (Principal{Actor: "bob", Owner: false}) {
		t.Fatal("untrusted claim promoted principal", e)
	}
	ran := false
	if g.RunOwner(func() error { ran = true; return nil }) != ErrDenied || ran {
		t.Fatal("family can execute")
	}
	g, e = verify(a, sign(t, values(c), k))
	if e != nil {
		t.Fatal(e)
	}
	if g.RunOwner(func() error { ran = true; return nil }) != nil || !ran {
		t.Fatal("configured owner denied")
	}
}
func rawSign(t *testing.T, h, p string, k *rsa.PrivateKey) string {
	t.Helper()
	s := base64.RawURLEncoding.EncodeToString([]byte(h)) + "." + base64.RawURLEncoding.EncodeToString([]byte(p))
	hash := sha256.Sum256([]byte(s))
	sig, e := rsa.SignPKCS1v15(rand.Reader, k, crypto.SHA256, hash[:])
	if e != nil {
		t.Fatal(e)
	}
	return s + "." + base64.RawURLEncoding.EncodeToString(sig)
}
func TestHeaderSignatureAndParserAttacks(t *testing.T) {
	c, k := fixture(t)
	a, _ := New(c)
	body, _ := json.Marshal(values(c))
	valid := sign(t, values(c), k)
	bad := []string{"", strings.Repeat("x", 8193), valid + ".", "a.b.c", rawSign(t, `{"alg":"RS256","typ":"JWT","kid":"unknown"}`, string(body), k), rawSign(t, `{"alg":"RS256","typ":"JWT","kid":"key-1","jku":"http://127.0.0.1/secret"}`, string(body), k), rawSign(t, `{"alg":"RS256","alg":"RS256","typ":"JWT","kid":"key-1"}`, string(body), k), rawSign(t, `{"alg":"RS256","typ":"JWT","kid":"key-1"}`, strings.TrimSuffix(string(body), "}")+`,"sub":"person-2"}`, k)}
	hs := jwt.NewWithClaims(jwt.SigningMethodHS256, values(c))
	hs.Header["kid"] = "key-1"
	h, _ := hs.SignedString([]byte("public-test"))
	bad = append(bad, h)
	none := jwt.NewWithClaims(jwt.SigningMethodNone, values(c))
	none.Header["kid"] = "key-1"
	n, _ := none.SignedString(jwt.UnsafeAllowNoneSignatureType)
	bad = append(bad, n)
	other, e := rsa.GenerateKey(rand.Reader, 2048)
	if e != nil {
		t.Fatal(e)
	}
	bad = append(bad, sign(t, values(c), other))
	for i, raw := range bad {
		if _, e := verify(a, raw); e != ErrDenied {
			t.Fatalf("attack %d accepted: %v", i, e)
		}
	}
	for _, mode := range []string{"email", "bearer", "cookie", "duplicate", "mixed"} {
		r := httptest.NewRequest("GET", "http://127.0.0.1:1/", nil)
		switch mode {
		case "email":
			r.Header.Set("Cf-Access-Authenticated-User-Email", "owner@example.invalid")
		case "bearer":
			r.Header.Set("Authorization", "Bearer synthetic-alice")
		case "cookie":
			r.Header.Set("Cookie", "CF_Authorization="+valid)
		case "duplicate":
			r.Header.Add("Cf-Access-Jwt-Assertion", valid)
			r.Header.Add("Cf-Access-Jwt-Assertion", valid)
		case "mixed":
			r.Header.Set("Cf-Access-Jwt-Assertion", valid)
			r.Header.Set("Authorization", "Bearer synthetic-alice")
		}
		if _, e := a.Verify(r); e != ErrDenied {
			t.Fatalf("%s accepted", mode)
		}
	}
}
func TestReplacementExpiryAndConfigCopy(t *testing.T) {
	c, k := fixture(t)
	a, _ := New(c)
	raw := sign(t, values(c), k)
	g, _ := verify(a, raw)
	c.People[0].Actor = "changed"
	delete(c.Keys, "key-1")
	if got, e := verify(a, raw); e != nil || got.Principal().Actor != "alice" {
		t.Fatal("configuration aliased")
	}
	replacement, _ := fixture(t)
	replacement.People = replacement.People[1:]
	if a.Replace(replacement) != nil {
		t.Fatal("replace failed")
	}
	if _, e := verify(a, raw); e != ErrDenied {
		t.Fatal("revoked identity accepted")
	}
	if g.Run(func() error { return nil }) != ErrDenied {
		t.Fatal("old lease survived")
	}
	restored, _ := fixture(t)
	a.Replace(restored)
	if g.Run(func() error { return nil }) != ErrDenied {
		t.Fatal("re-add revived old lease")
	}
	g, _ = verify(a, raw)
	g.expires = time.Now().Add(-time.Second)
	if g.Run(func() error { return nil }) != ErrDenied {
		t.Fatal("expired grant accepted")
	}
	// Rotation is trusted replacement, unknown keys cause no fetch or fallback.
	rotated, _ := fixture(t)
	rotated.Keys = map[string]*rsa.PublicKey{"key-2": &k.PublicKey}
	a.Replace(rotated)
	if _, e := verify(a, raw); e != ErrDenied {
		t.Fatal("removed key accepted")
	}
	token := jwt.NewWithClaims(jwt.SigningMethodRS256, values(rotated))
	token.Header["kid"] = "key-2"
	signed, _ := token.SignedString(k)
	if _, e := verify(a, signed); e != nil {
		t.Fatal(e)
	}
}
func TestConfigBounds(t *testing.T) {
	c, _ := fixture(t)
	bad := []func(*Config){func(c *Config) { c.Issuer = "http://synthetic.cloudflareaccess.com" }, func(c *Config) { c.Issuer = "https://synthetic.cloudflareaccess.com/" }, func(c *Config) { c.Audience = "" }, func(c *Config) { c.People = append(c.People, c.People[0]) }, func(c *Config) { c.People[1].Owner = true }, func(c *Config) { c.Keys = map[string]*rsa.PublicKey{} }, func(c *Config) { c.Keys["key-1"] = nil }}
	for i, f := range bad {
		c, _ = fixture(t)
		f(&c)
		if _, e := New(c); e != ErrConfig {
			t.Fatalf("bad config %d", i)
		}
	}
}
func TestReplacementWaitsForBoundedOperation(t *testing.T) {
	c, k := fixture(t)
	a, _ := New(c)
	g, _ := verify(a, sign(t, values(c), k))
	entered, release, finished := make(chan struct{}), make(chan struct{}), make(chan struct{})
	go func() { g.Run(func() error { close(entered); <-release; return nil }) }()
	<-entered
	go func() { a.Replace(c); close(finished) }()
	select {
	case <-finished:
		t.Fatal("replacement committed over admitted op")
	case <-time.After(20 * time.Millisecond):
	}
	close(release)
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("replacement blocked")
	}
	if g.Run(func() error { return nil }) != ErrDenied {
		t.Fatal("grant not retired")
	}
}

func TestSecurityClaimNamesAreExact(t *testing.T) {
	c, k := fixture(t)
	a, _ := New(c)
	base := values(c)
	base["sub"] = "person-2"
	b, _ := json.Marshal(base)
	for _, name := range []string{"SUB", "EXP", "TYPE", "ISS", "AUD", "NBF", "IAT", "JTI", "COMMON_NAME", "ſub", "iſſ"} {
		t.Run(name, func(t *testing.T) {
			suffix, _ := json.Marshal(map[string]any{name: "person-1"})
			payload := strings.TrimSuffix(string(b), "}") + "," + strings.TrimPrefix(string(suffix), "{")
			raw := rawSign(t, `{"alg":"RS256","typ":"JWT","kid":"key-1"}`, payload, k)
			if _, e := verify(a, raw); e != ErrDenied {
				t.Fatal("noncanonical security field accepted")
			}
		})
	}
	// Exact canonical fields still work, and an empty enrollment denies all.
	if _, e := verify(a, sign(t, base, k)); e != nil {
		t.Fatal(e)
	}
	c.People = nil
	if a.Replace(c) != nil {
		t.Fatal("empty enrollment rejected")
	}
	if _, e := verify(a, sign(t, base, k)); e != ErrDenied {
		t.Fatal("empty enrollment authorized")
	}
}
