package chat

import (
	"bytes"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net/http"

	"github.com/jinwon-int/family-messenger/server/internal/access"
)

//go:embed mls_bundle.json
var encryptedManifest []byte
var compiledEncryptedAssets fs.FS // Set only by the explicit synthetic_mls build.

type encryptedFile struct {
	File   string `json:"file"`
	URL    string `json:"url"`
	Type   string `json:"type"`
	Bytes  int    `json:"bytes"`
	SHA256 string `json:"sha256"`
	Source string `json:"source"`
}
type encryptedManifestSpec struct {
	Version     int             `json:"version"`
	WorkerState int             `json:"worker_state"`
	Files       []encryptedFile `json:"files"`
}
type encryptedAsset struct {
	data []byte
	kind string
}

// EncryptedAssets is immutable compiled public content, never a runtime directory.
type EncryptedAssets struct{ files map[string]encryptedAsset }

var encryptedPaths = map[string]string{
	"chat.html": "/encrypted/", "chat.css": "/chat.css", "chat.js": "/chat.js", "native-worker.js": "/native-worker.js", "trust-directory.js": "/trust-directory.js",
	"pkg.js": "/pkg/family_mls_browser_experiment.js", "pkg.wasm": "/pkg/family_mls_browser_experiment_bg.wasm", "cargo-notices.txt": "/encrypted/licenses/cargo.txt", "rust-notices.txt": "/encrypted/licenses/rust.txt",
}

func loadEncryptedAssets(source fs.FS, manifest []byte) (*EncryptedAssets, error) {
	if source == nil || len(manifest) > 8192 {
		return nil, fmt.Errorf("encrypted assets absent or invalid; build with prepared synthetic_mls assets")
	}
	var spec encryptedManifestSpec
	decoder := json.NewDecoder(bytes.NewReader(manifest))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&spec) != nil || decoder.Decode(new(any)) != io.EOF || spec.Version != 1 || spec.WorkerState != 4 || len(spec.Files) != len(encryptedPaths) {
		return nil, ErrInvalid
	}
	canonical, e := json.MarshalIndent(spec, "", "  ")
	if e != nil || !bytes.Equal(append(canonical, '\n'), manifest) {
		return nil, ErrInvalid
	}
	entries, e := fs.ReadDir(source, ".")
	if e != nil || len(entries) != len(encryptedPaths) {
		return nil, ErrInvalid
	}
	for _, entry := range entries {
		if entry.Type() != 0 || encryptedPaths[entry.Name()] == "" {
			return nil, ErrInvalid
		}
	}
	out := &EncryptedAssets{files: make(map[string]encryptedAsset)}
	total := 0
	for _, entry := range spec.Files {
		if encryptedPaths[entry.File] != entry.URL || entry.URL == "" || entry.Bytes <= 0 || entry.Bytes > 2*1024*1024 || len(entry.SHA256) != 64 {
			return nil, ErrInvalid
		}
		if _, exists := out.files[entry.URL]; exists {
			return nil, ErrInvalid
		}
		kind := "text/javascript; charset=utf-8"
		switch entry.File {
		case "chat.html":
			kind = "text/html; charset=utf-8"
		case "chat.css":
			kind = "text/css; charset=utf-8"
		case "pkg.wasm":
			kind = "application/wasm"
		case "cargo-notices.txt", "rust-notices.txt":
			kind = "text/plain; charset=utf-8"
		}
		if entry.Type != kind {
			return nil, ErrInvalid
		}
		f, e := source.Open(entry.File)
		if e != nil {
			return nil, ErrInvalid
		}
		data, e := io.ReadAll(io.LimitReader(f, int64(entry.Bytes)+1))
		closeErr := f.Close()
		if e != nil || closeErr != nil || len(data) != entry.Bytes {
			return nil, ErrInvalid
		}
		sum := sha256.Sum256(data)
		if hex.EncodeToString(sum[:]) != entry.SHA256 {
			return nil, ErrInvalid
		}
		total += len(data)
		if total > 4*1024*1024 {
			return nil, ErrInvalid
		}
		out.files[entry.URL] = encryptedAsset{data, kind}
	}
	return out, nil
}
func LoadEncryptedAssets() (*EncryptedAssets, error) {
	return loadEncryptedAssets(compiledEncryptedAssets, encryptedManifest)
}
func NewEncryptedAccessHandler(store *Store, authority *access.Authority, bundle *EncryptedAssets) (http.Handler, error) {
	if bundle == nil || len(bundle.files) != len(encryptedPaths) {
		return nil, ErrInvalid
	}
	handler, e := NewAccessHandler(store, authority)
	if e != nil {
		return nil, e
	}
	handler.(*API).encrypted = bundle
	return handler, nil
}
func (a *API) encryptedAsset(path string) bool {
	if a.encrypted == nil {
		return false
	}
	_, ok := a.encrypted.files[path]
	return ok
}
func (a *API) serveEncryptedAsset(w http.ResponseWriter, r *http.Request) {
	// Static public code needs a fresh signed admission, not a lock held over a
	// slow 1.5MiB write. Revocation still gates every subsequent data/API request.
	if a.authority == nil {
		fail(w, ErrForbidden)
		return
	}
	if e := authorize(r, func() error { return nil }); e != nil {
		fail(w, e)
		return
	}
	asset := a.encrypted.files[r.URL.Path]
	w.Header().Set("Content-Type", asset.kind)
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; worker-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Referrer-Policy", "no-referrer")
	_, _ = w.Write(asset.data)
}
