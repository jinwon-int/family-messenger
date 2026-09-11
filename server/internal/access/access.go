// Package access verifies CF-shaped application assertions against operator-pinned
// keys/enrollment. Request verification never fetches keys or enrolls accounts.
package access

import (
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

var ErrDenied = errors.New("identity not authorized")
var ErrConfig = errors.New("invalid identity configuration")

type Enrollment struct {
	Subject, Actor string
	Owner          bool
}
type Config struct {
	Issuer, Audience            string
	Keys                        map[string]*rsa.PublicKey
	People                      []Enrollment
	Devices                     []Device
	Successors                  *SuccessorPolicy
	Activations                 []Activation
	AdmissionPublic             string
	KeysFetchedAt, KeysExpireAt int64
}
type Principal struct {
	Actor string
	Owner bool
}

// Authority replacement is an explicit trusted in-process operation. No HTTP
// enrollment/role/key mutation endpoint exists. Constructors clone every input.
type Authority struct {
	mu         sync.RWMutex
	config     Config
	people     map[string]Enrollment
	generation uint64
	disabled   bool
}
type Grant struct {
	authority   *Authority
	generation  uint64
	principal   Principal
	expires     time.Time
	devices     []Device
	successors  []SuccessorIntent
	activations []Activation
}

func (g *Grant) Principal() Principal { return g.principal }

func identifier(s string, max int) bool {
	if len(s) < 1 || len(s) > max {
		return false
	}
	return strings.IndexFunc(s, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_')
	}) < 0
}
func clone(c Config) (Config, map[string]Enrollment, error) {
	u, e := url.Parse(c.Issuer)
	if e != nil || u.Scheme != "https" || u.User != nil || u.Port() != "" || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || c.Issuer != "https://"+u.Host || !strings.HasSuffix(u.Host, ".cloudflareaccess.com") || !identifier(strings.TrimSuffix(u.Host, ".cloudflareaccess.com"), 63) || !identifier(c.Audience, 128) || len(c.Keys) < 1 || len(c.Keys) > 16 || len(c.People) > 32 {
		return Config{}, nil, ErrConfig
	}
	if (c.KeysFetchedAt != 0 || c.KeysExpireAt != 0) && (c.KeysFetchedAt < 1 || c.KeysFetchedAt > 253402297199 || c.KeysExpireAt-c.KeysFetchedAt != int64(FetchedKeyLifetime/time.Second)) {
		return Config{}, nil, ErrConfig
	}
	out := Config{Issuer: c.Issuer, Audience: c.Audience, Keys: make(map[string]*rsa.PublicKey), KeysFetchedAt: c.KeysFetchedAt, KeysExpireAt: c.KeysExpireAt}
	for id, k := range c.Keys {
		if !identifier(id, 128) || k == nil || k.N == nil || k.N.Sign() <= 0 || k.N.BitLen() < 2048 || k.N.BitLen() > 4096 || k.N.Bit(0) != 1 || k.E != 65537 {
			return Config{}, nil, ErrConfig
		}
		out.Keys[id] = &rsa.PublicKey{N: new(big.Int).Set(k.N), E: k.E}
	}
	people := make(map[string]Enrollment)
	actors := make(map[string]bool)
	owners := 0
	for _, p := range c.People {
		if !identifier(p.Subject, 128) || !identifier(p.Actor, 64) || actors[p.Actor] {
			return Config{}, nil, ErrConfig
		}
		if _, ok := people[p.Subject]; ok {
			return Config{}, nil, ErrConfig
		}
		people[p.Subject] = p
		actors[p.Actor] = true
		out.People = append(out.People, p)
		if p.Owner {
			owners++
		}
	}
	if owners > 1 {
		return Config{}, nil, ErrConfig
	}
	out.Devices, e = cloneDevices(c.Devices, people)
	if e != nil {
		return Config{}, nil, e
	}
	out.Successors, e = cloneSuccessors(c)
	if e != nil {
		return Config{}, nil, e
	}
	out.Activations = c.Activations
	out.Activations, e = cloneActivations(out)
	if e != nil {
		return Config{}, nil, e
	}
	// The admission public key hex is already validated by the wire decoder;
	// clone keeps the exact committed value so the pin survives replacement.
	out.AdmissionPublic = c.AdmissionPublic
	return out, people, nil
}
func New(c Config) (*Authority, error) {
	out, people, e := clone(c)
	if e != nil {
		return nil, e
	}
	return &Authority{config: out, people: people, generation: 1}, nil
}

// Replace invalidates ALL earlier grants even if an identity is re-added. It
// waits for already admitted bounded operations/chunks, never network uploads.
func (a *Authority) Replace(c Config) error {
	out, people, e := clone(c)
	if e != nil {
		return e
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.generation != 0 {
		if e = deviceTransition(a.config.Devices, out.Devices); e != nil {
			return e
		}
		if e = activationForward(a.config, out); e != nil {
			return e
		}
		if e = successorForward(a.config, out); e != nil {
			return e
		}
	}
	a.config = out
	a.people = people
	a.generation++
	a.disabled = false
	return nil
}

// Run linearizes authorization with trusted replacement. Callers must use small
// bounded operations, never an upload read or entire SSE stream. Expiry stops the
// next operation; an already admitted chunk can complete within its deadline.
func (g *Grant) Run(fn func() error) error {
	if g == nil || g.authority == nil {
		return ErrDenied
	}
	a := g.authority
	a.mu.RLock()
	defer a.mu.RUnlock()
	if a.disabled || !keysCurrent(a.config, time.Now()) || g.generation != a.generation || !time.Now().Before(g.expires) {
		return ErrDenied
	}
	return fn()
}
func (g *Grant) RunOwner(fn func() error) error {
	return g.Run(func() error {
		if !g.principal.Owner {
			return ErrDenied
		}
		return fn()
	})
}

// Reject duplicate top-level fields so different JWT consumers cannot disagree
// about issuer/subject/header interpretation. The JWT library verifies crypto.
func object(encoded string) (map[string]json.RawMessage, error) {
	raw, e := base64.RawURLEncoding.Strict().DecodeString(encoded)
	if e != nil {
		return nil, ErrDenied
	}
	d := json.NewDecoder(strings.NewReader(string(raw)))
	t, e := d.Token()
	if e != nil || t != json.Delim('{') {
		return nil, ErrDenied
	}
	out := make(map[string]json.RawMessage)
	for d.More() {
		t, e = d.Token()
		if e != nil {
			return nil, ErrDenied
		}
		k, ok := t.(string)
		if !ok {
			return nil, ErrDenied
		}
		if _, ok = out[k]; ok {
			return nil, ErrDenied
		}
		var v json.RawMessage
		if d.Decode(&v) != nil {
			return nil, ErrDenied
		}
		out[k] = v
	}
	if _, e = d.Token(); e != nil {
		return nil, ErrDenied
	}
	if d.Decode(new(any)) != io.EOF {
		return nil, ErrDenied
	}
	return out, nil
}
func (a *Authority) Verify(r *http.Request) (*Grant, error) {
	h := r.Header.Values("Cf-Access-Jwt-Assertion")
	// No bearer/cookie/unsigned email fallback, including ambiguous mixed modes.
	if len(h) != 1 || len(h[0]) < 1 || len(h[0]) > 8192 || len(r.Header.Values("Authorization")) != 0 {
		return nil, ErrDenied
	}
	parts := strings.Split(h[0], ".")
	if len(parts) != 3 {
		return nil, ErrDenied
	}
	header, e := object(parts[0])
	if e != nil || len(header) != 3 {
		return nil, ErrDenied
	}
	if string(header["alg"]) != `"RS256"` || string(header["typ"]) != `"JWT"` {
		return nil, ErrDenied
	}
	fields, err := object(parts[1])
	if err != nil {
		return nil, ErrDenied
	}
	// RFC7519 claim names are case-sensitive. Go struct JSON binding is not;
	// use exact-key MapClaims and reject case-fold aliases to prevent different
	// consumers interpreting the same signed claims differently.
	for name := range fields {
		for _, canonical := range []string{"iss", "sub", "aud", "exp", "nbf", "iat", "jti", "type", "common_name"} {
			if name != canonical && strings.EqualFold(name, canonical) {
				return nil, ErrDenied
			}
		}
	}
	a.mu.RLock()
	defer a.mu.RUnlock()
	if a.disabled || !keysCurrent(a.config, time.Now()) {
		return nil, ErrDenied
	}
	c := jwt.MapClaims{}
	tok, e := jwt.ParseWithClaims(h[0], c, func(t *jwt.Token) (any, error) {
		kid, ok := t.Header["kid"].(string)
		if !ok || !identifier(kid, 128) {
			return nil, ErrDenied
		}
		key, ok := a.config.Keys[kid]
		if !ok {
			return nil, ErrDenied
		}
		return key, nil
	}, jwt.WithValidMethods([]string{"RS256"}), jwt.WithIssuer(a.config.Issuer), jwt.WithAudience(a.config.Audience), jwt.WithExpirationRequired(), jwt.WithIssuedAt(), jwt.WithStrictDecoding())
	if e != nil || !tok.Valid {
		return nil, ErrDenied
	}
	typ, ok := c["type"].(string)
	_, service := c["common_name"]
	issued, ie := c.GetIssuedAt()
	notBefore, ne := c.GetNotBefore()
	expires, ee := c.GetExpirationTime()
	subject, se := c.GetSubject()
	if !ok || typ != "app" || service || ie != nil || ne != nil || ee != nil || se != nil || issued == nil || notBefore == nil || expires == nil || !expires.After(issued.Time) || notBefore.After(expires.Time) {
		return nil, ErrDenied
	}
	p, ok := a.people[subject]
	if !ok {
		return nil, ErrDenied
	}
	g := &Grant{authority: a, generation: a.generation, principal: Principal{Actor: p.Actor, Owner: p.Owner}, expires: expires.Time, devices: append([]Device(nil), a.config.Devices...)}
	g.activations = append([]Activation(nil), a.config.Activations...)
	if a.config.Successors != nil {
		for _, intent := range a.config.Successors.Intents {
			person, enrolled := a.people[intent.Subject]
			if enrolled && person.Actor == intent.Actor && administratorCurrent(a.config, intent.Administrator) && intent.Status == "accepted" {
				g.successors = append(g.successors, intent)
			}
		}
	}
	return g, nil
}

// Suspend denies new verification and retires existing grants without fallback.
// AdmissionPublic returns the aggregate-admission Ed25519 public key hex
// committed through the signed policy document, or "" when the policy does
// not enable the aggregate admission service. This is the out-of-band pin
// channel: clients learn the key from here, not from an HTTP endpoint.
func (a *Authority) AdmissionPublic() string {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.config.AdmissionPublic
}

// Suspend denies new verification and retires existing grants without fallback.
func (a *Authority) Suspend() { a.mu.Lock(); defer a.mu.Unlock(); a.disabled = true; a.generation++ }
