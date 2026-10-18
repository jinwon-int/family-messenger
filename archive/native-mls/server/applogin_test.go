package main

import (
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

// #271 §12-C A: GET /v2/app-login hands the verified edge token back to the
// app through the FIXED callback, in the fragment, with the app's state
// echoed. Everything else is refused — bad state 400, missing/invalid token
// bare 401 (no Location either way), non-GET 405 — and without a verifier
// the route does not exist. The data routes are untouched.
func TestAppLoginHandoff(t *testing.T) {
	r, srv := newTestRelay(t, testPolicy())
	iss := newTestIssuer(t)
	r.access = iss.verifier()
	srv.Config.Handler = r.routes()

	do := func(method, p string, headers map[string]string) (*http.Response, string) {
		t.Helper()
		req, err := http.NewRequest(method, srv.URL+p, nil)
		if err != nil {
			t.Fatal(err)
		}
		for k, v := range headers {
			req.Header.Set(k, v)
		}
		resp, err := http.DefaultTransport.RoundTrip(req) // never follow the hande:// redirect
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp, string(b)
	}
	assertion := func(tok string) map[string]string { return map[string]string{"Cf-Access-Jwt-Assertion": tok} }

	state := strings.Repeat("Ab-_9", 8) // 40 base64url chars
	token := iss.mint("subject-alice", nil)
	resp, body := do("GET", appLoginPath+"?state="+state, assertion(token))
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("valid: %d %q", resp.StatusCode, body)
	}
	// G-M8: the edge's login page sends the browser back here cross-site — the
	// one contract route that must stay reachable with Sec-Fetch-Site: cross-site.
	if cross, body := do("GET", appLoginPath+"?state="+state, map[string]string{"Cf-Access-Jwt-Assertion": token, "Sec-Fetch-Site": "cross-site"}); cross.StatusCode != http.StatusFound {
		t.Fatalf("cross-site app-login: %d %q", cross.StatusCode, body)
	}
	loc := resp.Header.Get("Location")
	if want := appLoginCallback + "#jwt=" + token + "&state=" + state; loc != want {
		t.Fatalf("location\n got %s\nwant %s", loc, want)
	}
	u, err := url.Parse(loc)
	if err != nil || u.Scheme != "hande" || u.Host != "auth" || u.RawQuery != "" || u.Path != "" {
		t.Fatalf("callback shape: %+v err=%v", u, err)
	}
	frag, err := url.ParseQuery(u.Fragment)
	if err != nil || frag.Get("jwt") != token || frag.Get("state") != state || len(frag) != 2 {
		t.Fatalf("fragment: %v err=%v", frag, err)
	}
	if strings.Contains(body, token) {
		t.Fatal("token must travel in the Location fragment only, not the body")
	}
	for h, want := range map[string]string{"Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff"} {
		if got := resp.Header.Get(h); got != want {
			t.Fatalf("%s: %q want %q", h, got, want)
		}
	}
	// Bearer fallback (tooling) hands back the same token.
	if resp, _ := do("GET", appLoginPath+"?state="+state, map[string]string{"Authorization": "Bearer " + token}); resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != loc {
		t.Fatalf("bearer fallback: %d %s", resp.StatusCode, resp.Header.Get("Location"))
	}

	// State faults → 400, never a Location (checked before the token so the
	// response shape does not depend on authentication).
	for name, q := range map[string]string{
		"missing":      "",
		"empty":        "?state=",
		"short":        "?state=" + strings.Repeat("a", appLoginStateMin-1),
		"long":         "?state=" + strings.Repeat("a", appLoginStateMax+1),
		"dollar":       "?state=" + strings.Repeat("a", 20) + "$",
		"plus":         "?state=" + strings.Repeat("a", 20) + "+",
		"slash":        "?state=" + strings.Repeat("a", 20) + "/",
		"space":        "?state=" + strings.Repeat("a", 20) + "%20",
		"equals(pad)":  "?state=" + strings.Repeat("a", 20) + "=",
		"wrong param":  "?nonce=" + state,
		"fragment-ish": "?state=" + strings.Repeat("a", 20) + "%23x",
	} {
		resp, body := do("GET", appLoginPath+q, assertion(token))
		if resp.StatusCode != http.StatusBadRequest || resp.Header.Get("Location") != "" || !strings.Contains(body, "bad_state") {
			t.Fatalf("state %s: %d loc=%q %q", name, resp.StatusCode, resp.Header.Get("Location"), body)
		}
	}
	// Max-length state is accepted.
	if resp, _ := do("GET", appLoginPath+"?state="+strings.Repeat("z", appLoginStateMax), assertion(token)); resp.StatusCode != http.StatusFound {
		t.Fatalf("max-length state: %d", resp.StatusCode)
	}

	// Token faults → bare 401 like every contract route, no Location.
	for name, headers := range map[string]map[string]string{
		"none":     {},
		"garbage":  assertion("not.a.jwt"),
		"expired":  assertion(iss.mint("s", func(c map[string]any) { c["exp"] = time.Now().Unix() - 120 })),
		"wrongaud": assertion(iss.mint("s", func(c map[string]any) { c["aud"] = []string{"someone-else"} })),
		"cookie":   {"Cookie": "CF_Authorization=" + token}, // origin reads headers only (edge would have injected)
	} {
		resp, body := do("GET", appLoginPath+"?state="+state, headers)
		if resp.StatusCode != http.StatusUnauthorized || resp.Header.Get("Location") != "" || strings.Contains(body, token) {
			t.Fatalf("token %s: %d loc=%q %q", name, resp.StatusCode, resp.Header.Get("Location"), body)
		}
	}

	// Method and neighbours.
	if resp, _ := do("POST", appLoginPath+"?state="+state, assertion(token)); resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("post: %d", resp.StatusCode)
	}
	if resp, _ := do("GET", appLoginPath+"/", assertion(token)); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("trailing slash: %d", resp.StatusCode)
	}
	if resp, body := do("GET", "/v2/health", nil); resp.StatusCode != 200 || !strings.Contains(body, `"ok":true`) {
		t.Fatalf("health: %d %s", resp.StatusCode, body)
	}
}

// Without caller authentication there is no edge token to hand back: the
// route is not registered at all (fail closed, not a 500 or an empty token).
func TestAppLoginAbsentWithoutVerifier(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	req, _ := http.NewRequest("GET", srv.URL+appLoginPath+"?state="+strings.Repeat("a", 32), nil)
	req.Header.Set("Cf-Access-Jwt-Assertion", "x.y.z")
	resp, err := http.DefaultTransport.RoundTrip(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound || resp.Header.Get("Location") != "" {
		t.Fatalf("without verifier: %d loc=%q", resp.StatusCode, resp.Header.Get("Location"))
	}
}

func TestAppLoginLocationEncoding(t *testing.T) {
	// A real token is base64url segments joined by dots: none of it is
	// escaped, so the app can compare the fragment value byte for byte.
	tok := "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJhIn0.c2ln-_X"
	if got, want := appLoginLocation(tok, "st-_09"), "hande://auth#jwt="+tok+"&state=st-_09"; got != want {
		t.Fatalf("got %s want %s", got, want)
	}
	// Anything outside the token alphabet would be percent-encoded rather
	// than break the fragment syntax (defence in depth; the verifier never
	// lets such a token through).
	if got := appLoginLocation("a&b#c", "s"); strings.ContainsAny(strings.TrimPrefix(got, appLoginCallback+"#"), "#") || !strings.Contains(got, "jwt=a%26b%23c") {
		t.Fatalf("escaping: %s", got)
	}
}
