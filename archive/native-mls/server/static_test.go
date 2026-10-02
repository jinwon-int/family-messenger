package main

import (
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// #243 2-a: the human client is served from the relay origin under /app/,
// confined to -static-dir, with the kit's hardening headers; everything
// outside the directory, dotfiles and non-GET methods are refused; the data
// routes are untouched.
func TestStaticClientServing(t *testing.T) {
	dir := t.TempDir()
	must := func(name, body string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, name)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	must("relay-app.html", "<!doctype html><title>relay</title>")
	must("relay-app.js", "export const x = 1;")
	must("pkg/x_bg.wasm", "\x00asm")
	must(".secret", "nope")
	must("sub/.hidden/f.txt", "nope")
	must("sub/ok.txt", "fine")
	// A file outside the root that a traversal would reach.
	if err := os.WriteFile(filepath.Join(filepath.Dir(dir), "outside.txt"), []byte("leak"), 0o644); err != nil {
		t.Fatal(err)
	}

	r, srv := newTestRelay(t, testPolicy())
	root, err := openStaticRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { root.Close() })
	r.staticRoot = root
	srv.Config.Handler = r.routes()

	get := func(method, p string) (*http.Response, string) {
		t.Helper()
		req, _ := http.NewRequest(method, srv.URL+p, nil)
		resp, err := http.DefaultTransport.RoundTrip(req) // no redirect following
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp, string(b)
	}
	resp, body := get("GET", "/app/")
	if resp.StatusCode != 200 || !strings.Contains(body, "<title>relay</title>") || resp.Header.Get("Content-Type") != "text/html; charset=utf-8" {
		t.Fatalf("index: %d %q %s", resp.StatusCode, body, resp.Header.Get("Content-Type"))
	}
	for _, h := range []string{"Content-Security-Policy", "X-Content-Type-Options", "Cache-Control", "Referrer-Policy"} {
		if resp.Header.Get(h) == "" {
			t.Fatalf("missing header %s", h)
		}
	}
	if !strings.Contains(resp.Header.Get("Content-Security-Policy"), "'wasm-unsafe-eval'") {
		t.Fatalf("csp: %s", resp.Header.Get("Content-Security-Policy"))
	}
	if resp, _ := get("GET", "/app"); resp.StatusCode != 301 || resp.Header.Get("Location") != "/app/" {
		t.Fatalf("/app redirect: %d %s", resp.StatusCode, resp.Header.Get("Location"))
	}
	if resp, _ := get("GET", "/app/relay-app.js"); resp.StatusCode != 200 || resp.Header.Get("Content-Type") != "text/javascript; charset=utf-8" {
		t.Fatalf("js: %d %s", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	if resp, _ := get("GET", "/app/pkg/x_bg.wasm"); resp.StatusCode != 200 || resp.Header.Get("Content-Type") != "application/wasm" {
		t.Fatalf("wasm: %d %s", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	if resp, _ := get("HEAD", "/app/sub/ok.txt"); resp.StatusCode != 200 {
		t.Fatalf("head: %d", resp.StatusCode)
	}
	for _, p := range []string{"/app/.secret", "/app/sub/.hidden/f.txt", "/app/%2e%2e/outside.txt",
		"/app/sub/", "/app/sub", "/app/missing.js"} {
		if resp, body := get("GET", p); resp.StatusCode != 404 || strings.Contains(body, "leak") || strings.Contains(body, "nope") {
			t.Fatalf("%s: %d %q", p, resp.StatusCode, body)
		}
	}
	// A literal ".." is normalised by the mux into a redirect *out of* /app/
	// (never served from the root); the target is then an ordinary 404.
	if resp, body := get("GET", "/app/../outside.txt"); !((resp.StatusCode == 404) ||
		(resp.StatusCode/100 == 3 && !strings.HasPrefix(resp.Header.Get("Location"), staticPrefix))) || strings.Contains(body, "leak") {
		t.Fatalf("traversal: %d %s %q", resp.StatusCode, resp.Header.Get("Location"), body)
	}
	if resp, body := get("GET", "/outside.txt"); resp.StatusCode != 404 || strings.Contains(body, "leak") {
		t.Fatalf("outside: %d %q", resp.StatusCode, body)
	}
	if resp, _ := get("POST", "/app/relay-app.html"); resp.StatusCode != 405 {
		t.Fatalf("post: %d", resp.StatusCode)
	}
	// Data routes unchanged: still JSON API, no static leakage.
	if resp, body := get("GET", "/v2/health"); resp.StatusCode != 200 || !strings.Contains(body, `"ok":true`) {
		t.Fatalf("health: %d %s", resp.StatusCode, body)
	}
}

func TestStaticRootRequiresIndex(t *testing.T) {
	if _, err := openStaticRoot(t.TempDir()); err == nil || !strings.Contains(err.Error(), "relay-app.html") {
		t.Fatalf("empty dir accepted: %v", err)
	}
	if _, err := openStaticRoot(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("missing dir accepted")
	}
	r, srv := newTestRelay(t, testPolicy())
	srv.Config.Handler = r.routes()
	resp, err := http.Get(srv.URL + "/app/")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 404 {
		t.Fatalf("without -static-dir /app/ must be 404, got %d", resp.StatusCode)
	}
}
