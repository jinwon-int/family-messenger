package chat

import (
	"embed"
	"net/http"
)

//go:embed web/index.html web/app.js web/app.css
var assets embed.FS

func isAsset(path string) bool { return path == "/" || path == "/app.js" || path == "/app.css" }
func serveAsset(w http.ResponseWriter, r *http.Request) {
	name, kind := "web/index.html", "text/html; charset=utf-8"
	if r.URL.Path == "/app.js" {
		name, kind = "web/app.js", "text/javascript; charset=utf-8"
	}
	if r.URL.Path == "/app.css" {
		name, kind = "web/app.css", "text/css; charset=utf-8"
	}
	w.Header().Set("Content-Type", kind)
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Referrer-Policy", "no-referrer")
	data, e := assets.ReadFile(name)
	if e != nil {
		http.Error(w, "asset unavailable", 500)
		return
	}
	_, _ = w.Write(data)
}
