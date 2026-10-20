package main

// Host-based root serving for the hande web app (#431 stage 1). The PC
// browser version of the hande iOS app is a static bundle that has to live at
// the site root of its own hostname (service-worker scope, manifest, deep
// links), while the relay API stays at /v2/* on every host. When the operator
// passes -hande-host and -hande-dir, a request whose Host matches the name is
// served from the hande directory for every path outside /v2/; any other Host
// behaves exactly as before (including the /app/ acceptance client from
// -static-dir, which the hande host never serves). Like /app/, the assets are
// public code and unauthenticated; every data route stays behind the JWT.

import (
	"errors"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"strings"
)

// handeIndex is the document served for "/" and required at startup.
const handeIndex = "index.html"

// handeCSP: same shape as staticCSP, plus blob: images / media (attachments
// decrypted in the browser are shown through object URLs). No frame-src: with
// default-src 'none' the page embeds nothing unless -hande-frame-src names the
// origins (handeCSPWith).
const handeCSP = "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; " +
	"connect-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src blob:; " +
	"font-src 'self'; manifest-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"

// handeCSPWith appends "frame-src <origins>" for the iframes the operator allows
// on the hande host (the family filebox pane, web/hande/filebox.js). Empty =
// handeCSP unchanged, so a relay without the flag serves exactly what it did.
func handeCSPWith(frameSrc []string) string {
	if len(frameSrc) == 0 {
		return handeCSP
	}
	return handeCSP + "; frame-src " + strings.Join(frameSrc, " ")
}

// parseFrameSrc validates -hande-frame-src: comma-separated https origins
// (scheme + host[:port], nothing else), lower-cased host, duplicates dropped.
// Anything that is not a bare https origin is refused — a path or a scheme
// like javascript: would widen the policy in ways the flag does not promise.
func parseFrameSrc(raw string) ([]string, error) {
	var out []string
	seen := map[string]bool{}
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		u, err := url.Parse(part)
		if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil ||
			u.Path != "" || u.RawQuery != "" || u.Fragment != "" || u.Opaque != "" {
			return nil, fmt.Errorf("%q is not an https origin (expected https://host[:port])", part)
		}
		origin := "https://" + strings.ToLower(u.Host)
		if !seen[origin] {
			seen[origin] = true
			out = append(out, origin)
		}
	}
	return out, nil
}

// canonicalHost strips an optional :port and lower-cases the name so the
// operator's -hande-host and the request Host compare the same way.
func canonicalHost(h string) string {
	if host, _, err := net.SplitHostPort(h); err == nil {
		h = host
	}
	return strings.ToLower(h)
}

// handeHandler routes by Host: on the hande host everything outside /v2/ is a
// file below root; every other request (other hosts, and /v2/* on any host)
// goes to the API mux untouched.
type handeHandler struct {
	host string
	root *os.Root
	csp  string // handeCSPWith(frame-src) — fixed at startup
	api  http.Handler
}

func (h *handeHandler) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	if canonicalHost(req.Host) != h.host || strings.HasPrefix(req.URL.Path, "/v2/") {
		h.api.ServeHTTP(w, req)
		return
	}
	serveHandeFile(w, req, h.root, h.csp)
}

// serveHandeFile mirrors staticHandler's confinement: os.Root (no traversal,
// no symlink escape), dotfiles / dot segments / ".." / directories / missing
// files are 404, only GET and HEAD are accepted. "/" is the index.
func serveHandeFile(w http.ResponseWriter, req *http.Request, root *os.Root, csp string) {
	if req.Method != http.MethodGet && req.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	rel := strings.TrimPrefix(req.URL.Path, "/")
	if rel == "" {
		rel = handeIndex
	}
	clean := path.Clean("/" + rel)[1:]
	if clean == "" || clean == "." || strings.Contains(rel, "..") || hasDotSegment(clean) {
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
	ext := strings.ToLower(path.Ext(clean))
	ctype, ok := staticTypes[ext]
	if !ok {
		ctype = "application/octet-stream"
	}
	// Documents are never cached (they name the current bundle); assets are
	// revalidated — http.ServeContent answers If-Modified-Since with 304.
	cache := "no-cache"
	if ext == ".html" {
		cache = "no-store"
	}
	h := w.Header()
	h.Set("Content-Type", ctype)
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Cache-Control", cache)
	h.Set("Content-Security-Policy", csp)
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Cross-Origin-Opener-Policy", "same-origin")
	http.ServeContent(w, req, clean, info.ModTime(), f)
}

// openHandeRoot validates -hande-dir: it must exist, be a directory and hold
// index.html. The os.Root keeps every later Open inside it.
func openHandeRoot(dir string) (*os.Root, error) {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return nil, fmt.Errorf("hande dir: %w", err)
	}
	if _, err := fs.Stat(root.FS(), handeIndex); err != nil {
		root.Close()
		if errors.Is(err, fs.ErrNotExist) {
			return nil, fmt.Errorf("hande dir %s: %s missing (copy the built hande web bundle)", dir, handeIndex)
		}
		return nil, fmt.Errorf("hande dir: %w", err)
	}
	return root, nil
}
