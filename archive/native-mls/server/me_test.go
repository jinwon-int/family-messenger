package main

import (
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"
)

// #431 stage 1: GET /v2/me echoes the verified subject of the edge token so
// the hande web app can fill its device registration. Missing/invalid token
// is a bare 401 like every contract route, cross-site is refused, non-GET is
// 405, and without a verifier the route does not exist.
func TestMeRoute(t *testing.T) {
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
		resp, err := http.DefaultTransport.RoundTrip(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp, string(b)
	}
	assertion := func(tok string) map[string]string { return map[string]string{"Cf-Access-Jwt-Assertion": tok} }

	token := iss.mint("subject-alice", nil)
	resp, body := do("GET", mePath, assertion(token))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("valid: %d %q", resp.StatusCode, body)
	}
	var got map[string]any
	if err := json.Unmarshal([]byte(body), &got); err != nil || got["subject"] != "subject-alice" || len(got) != 1 {
		t.Fatalf("body %q: %v err=%v", body, got, err)
	}
	for h, want := range map[string]string{
		"Content-Type":           "application/json; charset=utf-8",
		"Cache-Control":          "no-store",
		"X-Content-Type-Options": "nosniff",
	} {
		if got := resp.Header.Get(h); got != want {
			t.Fatalf("%s: %q want %q", h, got, want)
		}
	}
	// Bearer fallback (tooling) sees the same subject.
	if resp, body := do("GET", mePath, map[string]string{"Authorization": "Bearer " + iss.mint("subject-bob", nil)}); resp.StatusCode != 200 || body != `{"subject":"subject-bob"}` {
		t.Fatalf("bearer: %d %q", resp.StatusCode, body)
	}

	// Token faults → bare 401 like every contract route, no subject.
	for name, headers := range map[string]map[string]string{
		"none":     {},
		"garbage":  assertion("not.a.jwt"),
		"expired":  assertion(iss.mint("s", func(c map[string]any) { c["exp"] = time.Now().Unix() - 120 })),
		"wrongaud": assertion(iss.mint("s", func(c map[string]any) { c["aud"] = []string{"someone-else"} })),
		"cookie":   {"Cookie": "CF_Authorization=" + token},
	} {
		resp, body := do("GET", mePath, headers)
		if resp.StatusCode != http.StatusUnauthorized || resp.Header.Get("WWW-Authenticate") == "" || resp.Header.Get("Cache-Control") != "no-store" {
			t.Fatalf("token %s: %d %q", name, resp.StatusCode, body)
		}
		var e map[string]any
		if json.Unmarshal([]byte(body), &e) != nil || e["subject"] != nil || e["error"] != "unauthorized" {
			t.Fatalf("token %s: body %q", name, body)
		}
	}
	// G-M8: a cross-site navigation never learns the subject.
	if resp, _ := do("GET", mePath, map[string]string{"Cf-Access-Jwt-Assertion": token, "Sec-Fetch-Site": "cross-site"}); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("cross-site: %d", resp.StatusCode)
	}

	// Method and neighbours.
	if resp, _ := do("POST", mePath, assertion(token)); resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("post: %d", resp.StatusCode)
	}
	if resp, _ := do("GET", mePath+"/", assertion(token)); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("trailing slash: %d", resp.StatusCode)
	}
	if resp, body := do("GET", "/v2/health", nil); resp.StatusCode != 200 || body != "{\"ok\":true}\n" {
		t.Fatalf("health: %d %s", resp.StatusCode, body)
	}
}

// Without caller authentication there is no verified subject: the route is
// not registered at all (fail closed, not a 500 or an empty subject).
func TestMeAbsentWithoutVerifier(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	req, _ := http.NewRequest("GET", srv.URL+mePath, nil)
	req.Header.Set("Cf-Access-Jwt-Assertion", "x.y.z")
	resp, err := http.DefaultTransport.RoundTrip(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusNotFound || string(b) == `{"subject":""}` {
		t.Fatalf("without verifier: %d %q", resp.StatusCode, b)
	}
}
