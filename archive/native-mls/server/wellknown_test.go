package main

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

// Server discovery (#584, wellknown.go): the document is fixed from the flags,
// public and cacheable, served on the API host and on the hande host alike
// (ahead of file serving), absent without -well-known-public-url, and the
// public URL is validated rather than guessed from the request.
func TestWellKnownDocumentAndRouting(t *testing.T) {
	hande := t.TempDir()
	writeTestFile(t, hande, "index.html", "<!doctype html><title>hande</title>")
	// A static file at the discovery path must never shadow the route.
	writeTestFile(t, hande, ".well-known/hande", `{"version":99}`)
	r, srv := newTestRelay(t, testPolicy())
	hroot, err := openHandeRoot(hande)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hroot.Close() })
	r.handeHost = canonicalHost(testHandeHost)
	r.handeRoot = hroot
	doc, err := newWellKnownDoc("HTTPS://Relay.Example:8443/base/", "서윤 가족", r.handeHost, "0.1.0", "")
	if err != nil {
		t.Fatal(err)
	}
	r.wellKnown = doc
	srv.Config.Handler = r.routes()

	do := func(method, host string) (*http.Response, string) {
		t.Helper()
		req, err := http.NewRequest(method, srv.URL+wellKnownPath, nil)
		if err != nil {
			t.Fatal(err)
		}
		if host != "" {
			req.Host = host
		}
		resp, err := http.DefaultTransport.RoundTrip(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp, string(b)
	}
	for _, host := range []string{"", testHandeHost, strings.ToUpper(testHandeHost) + ":443"} {
		resp, body := do("GET", host)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("host %q: %d %s", host, resp.StatusCode, body)
		}
		var got map[string]any
		if err := json.Unmarshal([]byte(body), &got); err != nil {
			t.Fatalf("host %q: body %q: %v", host, body, err)
		}
		relay := got["relay"].(map[string]any)
		if got["version"] != float64(1) || relay["base_url"] != "https://relay.example:8443/base" || relay["app_login"] != appLoginPath || got["name"] != "서윤 가족" {
			t.Fatalf("host %q: doc %s", host, body)
		}
		if got["hande"].(map[string]any)["web_url"] != "https://"+r.handeHost {
			t.Fatalf("host %q: hande %s", host, body)
		}
		minApp := got["min_app"].(map[string]any)
		if minApp["ios"] != "0.1.0" || minApp["android"] != nil {
			t.Fatalf("host %q: min_app %s", host, body)
		}
		for h, want := range map[string]string{
			"Content-Type":                "application/json; charset=utf-8",
			"Cache-Control":               "public, max-age=300",
			"X-Content-Type-Options":      "nosniff",
			"Access-Control-Allow-Origin": "*",
		} {
			if got := resp.Header.Get(h); got != want {
				t.Fatalf("host %q: %s = %q want %q", host, h, got, want)
			}
		}
	}
	if resp, body := do("HEAD", testHandeHost); resp.StatusCode != http.StatusOK || body != "" {
		t.Fatalf("HEAD: %d %q", resp.StatusCode, body)
	}
	if resp, _ := do("POST", ""); resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("POST: %d", resp.StatusCode)
	}
	// Health and the hande index keep working beside it.
	if resp, body := do("GET", ""); resp.StatusCode != 200 || !strings.Contains(body, `"version":1`) {
		t.Fatalf("api host: %d %s", resp.StatusCode, body)
	}

	// Without the public URL the route does not exist, on either host.
	r2, srv2 := newTestRelay(t, testPolicy())
	r2.handeHost, r2.handeRoot = r.handeHost, hroot
	srv2.Config.Handler = r2.routes()
	for _, host := range []string{"", testHandeHost} {
		req, _ := http.NewRequest("GET", srv2.URL+wellKnownPath, nil)
		if host != "" {
			req.Host = host
		}
		resp, err := http.DefaultTransport.RoundTrip(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound {
			t.Fatalf("off, host %q: %d", host, resp.StatusCode)
		}
	}
}

func TestWellKnownFlagValidation(t *testing.T) {
	if doc, err := newWellKnownDoc("", "", "", "", ""); err != nil || doc != nil {
		t.Fatalf("empty: %v %v", doc, err)
	}
	for name, c := range map[string]struct{ url, sname, ios string }{
		"name without url": {"", "x", ""},
		"http":             {"http://relay.example", "", ""},
		"no host":          {"https://", "", ""},
		"userinfo":         {"https://u:p@relay.example", "", ""},
		"query":            {"https://relay.example/?x=1", "", ""},
		"dotdot":           {"https://relay.example/a/../b", "", ""},
		"long name":        {"https://relay.example", strings.Repeat("n", 65), ""},
		"newline name":     {"https://relay.example", "a\nb", ""},
		"bad version":      {"https://relay.example", "", "v1"},
	} {
		if _, err := newWellKnownDoc(c.url, c.sname, "", c.ios, ""); err == nil {
			t.Fatalf("%s: accepted", name)
		}
	}
	for raw, want := range map[string]string{
		"https://relay.example":          "https://relay.example",
		"https://relay.example/":         "https://relay.example",
		"https://Relay.Example/mls/":     "https://relay.example/mls",
		"http://localhost:18921":         "http://localhost:18921",
		"http://127.0.0.1:18921/relay":   "http://127.0.0.1:18921/relay",
		"  https://relay.example:8443  ": "https://relay.example:8443",
	} {
		got, err := publicBaseURL(raw)
		if err != nil || got != want {
			t.Fatalf("publicBaseURL(%q) = %q, %v; want %q", raw, got, err, want)
		}
	}
	doc, err := newWellKnownDoc("https://relay.example", "", "", "", "1.2")
	if err != nil || doc.Hande != nil || doc.Name != "" || doc.MinApp == nil || doc.MinApp.Android != "1.2" || doc.MinApp.IOS != "" {
		t.Fatalf("minimal doc: %+v %v", doc, err)
	}
	raw, _ := json.Marshal(doc)
	if s := string(raw); strings.Contains(s, `"hande"`) || strings.Contains(s, `"name"`) || strings.Contains(s, `"ios"`) {
		t.Fatalf("omitempty: %s", s)
	}
}
