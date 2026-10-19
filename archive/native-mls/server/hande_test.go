package main

import (
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testHandeHost = "hande.example.test"

func writeTestFile(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, name)), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// #431 stage 1: on the hande host every path outside /v2/ is a file of
// -hande-dir ("/" = index.html) with the hardening headers; dotfiles,
// traversal, directories and non-GET methods are refused; /v2/* is the API as
// on any host; every other host is unchanged (/app/ from -static-dir, no root
// document) and the hande host never serves the relay-app files.
func TestHandeHostServing(t *testing.T) {
	hande := t.TempDir()
	writeTestFile(t, hande, "index.html", "<!doctype html><title>hande</title>")
	writeTestFile(t, hande, "assets/app.js", "export const hande = 1;")
	writeTestFile(t, hande, "assets/font.woff2", "wOF2")
	writeTestFile(t, hande, "manifest.webmanifest", `{"name":"hande"}`)
	writeTestFile(t, hande, "pkg/x_bg.wasm", "\x00asm")
	writeTestFile(t, hande, ".env", "nope")
	writeTestFile(t, hande, "sub/.hidden/f.txt", "nope")
	writeTestFile(t, hande, "sub/ok.txt", "fine")
	// A file outside the hande root that a traversal would reach.
	if err := os.WriteFile(filepath.Join(filepath.Dir(hande), "outside.txt"), []byte("leak"), 0o644); err != nil {
		t.Fatal(err)
	}
	relayApp := t.TempDir()
	writeTestFile(t, relayApp, "relay-app.html", "<!doctype html><title>relay</title>")

	r, srv := newTestRelay(t, testPolicy())
	sroot, err := openStaticRoot(relayApp)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sroot.Close() })
	hroot, err := openHandeRoot(hande)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hroot.Close() })
	r.staticRoot = sroot
	r.handeHost = canonicalHost(testHandeHost)
	r.handeRoot = hroot
	srv.Config.Handler = r.routes()

	do := func(method, host, p string, headers map[string]string) (*http.Response, string) {
		t.Helper()
		req, err := http.NewRequest(method, srv.URL+p, nil)
		if err != nil {
			t.Fatal(err)
		}
		if host != "" {
			req.Host = host
		}
		for k, v := range headers {
			req.Header.Set(k, v)
		}
		resp, err := http.DefaultTransport.RoundTrip(req) // no redirect following
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp, string(b)
	}

	// Index at the root, with every hardening header.
	resp, body := do("GET", testHandeHost, "/", nil)
	if resp.StatusCode != 200 || !strings.Contains(body, "<title>hande</title>") || resp.Header.Get("Content-Type") != "text/html; charset=utf-8" {
		t.Fatalf("index: %d %q %s", resp.StatusCode, body, resp.Header.Get("Content-Type"))
	}
	for h, want := range map[string]string{
		"Content-Security-Policy":    handeCSP,
		"X-Content-Type-Options":     "nosniff",
		"Cache-Control":              "no-store",
		"Referrer-Policy":            "no-referrer",
		"Cross-Origin-Opener-Policy": "same-origin",
	} {
		if got := resp.Header.Get(h); got != want {
			t.Fatalf("%s: %q want %q", h, got, want)
		}
	}
	for _, s := range []string{"media-src blob:", "img-src 'self' data: blob:", "manifest-src 'self'", "frame-ancestors 'none'"} {
		if !strings.Contains(handeCSP, s) {
			t.Fatalf("csp lacks %q: %s", s, handeCSP)
		}
	}
	if resp, _ := do("GET", testHandeHost, "/index.html", nil); resp.StatusCode != 200 || resp.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("index.html: %d %s", resp.StatusCode, resp.Header.Get("Cache-Control"))
	}
	// Host match is case-insensitive and ignores the port.
	for _, host := range []string{"HANDE.Example.Test", testHandeHost + ":8443"} {
		if resp, body := do("GET", host, "/", nil); resp.StatusCode != 200 || !strings.Contains(body, "<title>hande</title>") {
			t.Fatalf("host %s: %d %q", host, resp.StatusCode, body)
		}
	}

	// Nested asset: revalidated (no-cache) and 304 on If-Modified-Since.
	resp, body = do("GET", testHandeHost, "/assets/app.js", nil)
	if resp.StatusCode != 200 || body != "export const hande = 1;" || resp.Header.Get("Content-Type") != "text/javascript; charset=utf-8" ||
		resp.Header.Get("Cache-Control") != "no-cache" || resp.Header.Get("Content-Security-Policy") != handeCSP {
		t.Fatalf("js: %d %q %s %s", resp.StatusCode, body, resp.Header.Get("Content-Type"), resp.Header.Get("Cache-Control"))
	}
	if lm := resp.Header.Get("Last-Modified"); lm == "" {
		t.Fatal("js: no Last-Modified")
	} else if resp, _ := do("GET", testHandeHost, "/assets/app.js", map[string]string{"If-Modified-Since": lm}); resp.StatusCode != http.StatusNotModified {
		t.Fatalf("if-modified-since: %d", resp.StatusCode)
	}
	for p, ctype := range map[string]string{
		"/assets/font.woff2":    "font/woff2",
		"/manifest.webmanifest": "application/manifest+json",
		"/pkg/x_bg.wasm":        "application/wasm",
	} {
		if resp, _ := do("GET", testHandeHost, p, nil); resp.StatusCode != 200 || resp.Header.Get("Content-Type") != ctype {
			t.Fatalf("%s: %d %s", p, resp.StatusCode, resp.Header.Get("Content-Type"))
		}
	}
	if resp, _ := do("HEAD", testHandeHost, "/sub/ok.txt", nil); resp.StatusCode != 200 {
		t.Fatalf("head: %d", resp.StatusCode)
	}

	// Refused: dotfiles, traversal (encoded and literal), directories, missing,
	// and the relay-app files which live only in -static-dir.
	for _, p := range []string{"/.env", "/sub/.hidden/f.txt", "/%2e%2e/outside.txt", "/../outside.txt", "/sub/..%2f..%2foutside.txt",
		"/sub/", "/sub", "/missing.js", "/outside.txt", "/app/relay-app.html", "/app/", "/app"} {
		if resp, body := do("GET", testHandeHost, p, nil); resp.StatusCode != 404 || strings.Contains(body, "leak") || strings.Contains(body, "nope") || strings.Contains(body, "relay") {
			t.Fatalf("%s: %d %q", p, resp.StatusCode, body)
		}
	}
	if resp, _ := do("POST", testHandeHost, "/", nil); resp.StatusCode != 405 || resp.Header.Get("Allow") != "GET, HEAD" {
		t.Fatalf("post: %d allow=%q", resp.StatusCode, resp.Header.Get("Allow"))
	}
	if resp, _ := do("PUT", testHandeHost, "/assets/app.js", nil); resp.StatusCode != 405 {
		t.Fatalf("put: %d", resp.StatusCode)
	}

	// /v2/* on the hande host is the API exactly as elsewhere.
	if resp, body := do("GET", testHandeHost, "/v2/health", nil); resp.StatusCode != 200 || !strings.Contains(body, `"ok":true`) || resp.Header.Get("Content-Security-Policy") != "" {
		t.Fatalf("hande health: %d %s", resp.StatusCode, body)
	}
	if resp, _ := do("POST", testHandeHost, "/v2/health", nil); resp.StatusCode != 405 {
		t.Fatalf("hande post health: %d", resp.StatusCode)
	}
	if resp, _ := do("GET", testHandeHost, "/v2/", nil); resp.StatusCode != 404 {
		t.Fatalf("hande /v2/: %d", resp.StatusCode)
	}

	// Every other host is untouched: no root document, /app/ from -static-dir,
	// hande files unreachable.
	for _, host := range []string{"", "other.example.test", "hande.example.test.evil.example"} {
		if resp, body := do("GET", host, "/app/", nil); resp.StatusCode != 200 || !strings.Contains(body, "<title>relay</title>") {
			t.Fatalf("host %q /app/: %d %q", host, resp.StatusCode, body)
		}
		for _, p := range []string{"/", "/index.html", "/assets/app.js"} {
			if resp, body := do("GET", host, p, nil); resp.StatusCode != 404 || strings.Contains(body, "hande") {
				t.Fatalf("host %q %s: %d %q", host, p, resp.StatusCode, body)
			}
		}
		if resp, body := do("GET", host, "/v2/health", nil); resp.StatusCode != 200 || !strings.Contains(body, `"ok":true`) {
			t.Fatalf("host %q health: %d %s", host, resp.StatusCode, body)
		}
	}
}

func TestHandeRootRequiresIndex(t *testing.T) {
	if _, err := openHandeRoot(t.TempDir()); err == nil || !strings.Contains(err.Error(), "index.html") {
		t.Fatalf("empty dir accepted: %v", err)
	}
	if _, err := openHandeRoot(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("missing dir accepted")
	}
	// A relay-app directory is not a hande bundle.
	dir := t.TempDir()
	writeTestFile(t, dir, "relay-app.html", "<title>relay</title>")
	if _, err := openHandeRoot(dir); err == nil {
		t.Fatal("relay-app dir accepted as hande dir")
	}
	// Without -hande-host the hande host name is just another host: 404 at
	// the root, /v2/* as usual.
	_, srv := newTestRelay(t, testPolicy())
	req, _ := http.NewRequest("GET", srv.URL+"/", nil)
	req.Host = testHandeHost
	resp, err := http.DefaultTransport.RoundTrip(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 404 {
		t.Fatalf("without -hande-dir / on the hande host must be 404, got %d", resp.StatusCode)
	}
}

func TestCanonicalHost(t *testing.T) {
	for in, want := range map[string]string{
		"hande.example.test":       "hande.example.test",
		"HANDE.Example.TEST":       "hande.example.test",
		"hande.example.test:443":   "hande.example.test",
		"Hande.Example.Test:18921": "hande.example.test",
		"127.0.0.1:18921":          "127.0.0.1",
		"[::1]:18921":              "::1",
		"":                         "",
	} {
		if got := canonicalHost(in); got != want {
			t.Errorf("canonicalHost(%q) = %q want %q", in, got, want)
		}
	}
}
