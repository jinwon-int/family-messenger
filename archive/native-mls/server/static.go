package main

// Static client serving for the human acceptance client (#243 2-a). The relay
// is the only origin the browser talks to, so the client page must be served
// from the relay itself: same-origin fetches carry the Cloudflare Access cookie
// and the edge injects Cf-Access-Jwt-Assertion on every /v2/* call. Static
// assets are public code (no secrets), so /app/* is unauthenticated; every
// data route stays behind the JWT. Nothing here is reachable unless the
// operator passes -static-dir.

import (
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path"
	"strings"
)

const staticPrefix = "/app/"

// staticCSP mirrors the kit server's policy plus inline styles for the
// human page (no third-party origins, workers and wasm from self only).
const staticCSP = "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; " +
	"connect-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; base-uri 'none'; " +
	"frame-ancestors 'none'; form-action 'none'"

var staticTypes = map[string]string{
	".html": "text/html; charset=utf-8",
	".js":   "text/javascript; charset=utf-8",
	".mjs":  "text/javascript; charset=utf-8",
	".wasm": "application/wasm",
	".json": "application/json; charset=utf-8",
	".txt":  "text/plain; charset=utf-8",
	".css":  "text/css; charset=utf-8",
	".png":  "image/png",
	".svg":  "image/svg+xml",
	".ico":  "image/x-icon",
}

// staticHandler serves files below root under /app/. The path is confined to
// root by os.Root (no traversal, no symlink escape), dotfiles and directories
// other than the index are 404, and only GET/HEAD are accepted.
func staticHandler(root *os.Root) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodGet && req.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		rel := strings.TrimPrefix(req.URL.Path, staticPrefix)
		if rel == "" {
			rel = "relay-app.html"
		}
		clean := path.Clean("/" + rel)[1:]
		if clean == "" || clean == "." || strings.Contains(clean, "..") || hasDotSegment(clean) {
			http.NotFound(w, req)
			return
		}
		f, err := root.Open(clean)
		if err != nil {
			http.NotFound(w, req)
			return
		}
		defer f.Close()
		info, err := f.Stat()
		if err != nil || !info.Mode().IsRegular() {
			http.NotFound(w, req)
			return
		}
		ctype, ok := staticTypes[strings.ToLower(path.Ext(clean))]
		if !ok {
			ctype = "application/octet-stream"
		}
		h := w.Header()
		h.Set("Content-Type", ctype)
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Cache-Control", "no-store")
		h.Set("Content-Security-Policy", staticCSP)
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		http.ServeContent(w, req, clean, info.ModTime(), f)
	})
}

func hasDotSegment(p string) bool {
	for _, seg := range strings.Split(p, "/") {
		if strings.HasPrefix(seg, ".") {
			return true
		}
	}
	return false
}

// openStaticRoot validates -static-dir: it must exist, be a directory and hold
// the client index. The os.Root keeps every later Open inside it.
func openStaticRoot(dir string) (*os.Root, error) {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return nil, fmt.Errorf("static dir: %w", err)
	}
	if _, err := fs.Stat(root.FS(), "relay-app.html"); err != nil {
		root.Close()
		if errors.Is(err, fs.ErrNotExist) {
			return nil, fmt.Errorf("static dir %s: relay-app.html missing (copy archive/experiments/openmls-browser/web/* and the built pkg/ bundle)", dir)
		}
		return nil, fmt.Errorf("static dir: %w", err)
	}
	log.Printf("static client served at %s from %s (unauthenticated assets; /v2/* stays behind the JWT)", staticPrefix, dir)
	return root, nil
}
