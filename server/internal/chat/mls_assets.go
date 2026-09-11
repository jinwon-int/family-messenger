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

//go:embed vault_bundle.json
var vaultManifest []byte

//go:embed history_bundle.json
var historyManifest []byte

//go:embed history_bundle_v3.json
var retiredHistoryManifest []byte

//go:embed aggregate_bundle.json
var aggregateManifest []byte

//go:embed aggregate_history_bundle.json
var aggregateHistoryManifest []byte

//go:embed peer_bundle.json
var peerManifest []byte
var compiledPeerAssets fs.FS

//go:embed candidate_bundle.json
var candidateManifest []byte

var compiledCandidateAssets fs.FS

//go:embed successor_bundle.json
var successorManifest []byte
var compiledSuccessorAssets fs.FS
var compiledAggregateHistoryAssets fs.FS
var compiledAggregateAssets fs.FS
var compiledHistoryAssets fs.FS
var compiledVaultAssets fs.FS
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
type EncryptedAssets struct {
	files   map[string]encryptedAsset
	version int
}

var encryptedPaths = map[string]string{
	"chat.html": "/encrypted/", "chat.css": "/chat.css", "chat.js": "/chat.js", "native-worker.js": "/native-worker.js", "trust-directory.js": "/trust-directory.js",
	"pkg.js": "/pkg/family_mls_browser_experiment.js", "pkg.wasm": "/pkg/family_mls_browser_experiment_bg.wasm", "cargo-notices.txt": "/encrypted/licenses/cargo.txt", "rust-notices.txt": "/encrypted/licenses/rust.txt",
}

var vaultPaths = func() map[string]string {
	out := make(map[string]string)
	for file, path := range encryptedPaths {
		out[file] = path
	}
	for file, path := range map[string]string{
		"vault-chat.html": "/vault/", "vault-chat.js": "/vault-chat.js", "vault-native-worker.js": "/vault-native-worker.js", "native-vault-store.js": "/native-vault-store.js", "age-notices.txt": "/vault/licenses/age.txt", "sodium-notices.txt": "/vault/licenses/sodium.txt",
	} {
		out[file] = path
	}
	return out
}()

var historyPaths = func() map[string]string {
	out := make(map[string]string)
	for file, path := range vaultPaths {
		out[file] = path
	}
	for _, file := range []string{"history.css", "history-ui.js", "history-client.js", "history-worker.js", "history-export-worker.js"} {
		out[file] = "/" + file
	}
	out["history.html"] = "/history/"
	return out
}()

var aggregatePaths = map[string]string{
	"aggregate-chat.html":        "/aggregate/",
	"aggregate-chat.js":          "/aggregate-chat.js",
	"chat.css":                   "/chat.css",
	"native-worker.js":           "/native-worker.js",
	"trust-directory.js":         "/trust-directory.js",
	"aggregate-native-worker.js": "/aggregate-native-worker.js",
	"prepared-fork-worker.js":    "/prepared-fork-worker.js",
	"pkg.js":                     "/pkg/family_mls_browser_experiment.js",
	"pkg.wasm":                   "/pkg/family_mls_browser_experiment_bg.wasm",
	"cargo-notices.txt":          "/aggregate/licenses/cargo.txt",
	"rust-notices.txt":           "/aggregate/licenses/rust.txt",
	"aggregate-store.js":         "/aggregate-store.js",
	"age-notices.txt":            "/aggregate/licenses/age.txt",
	"sodium-notices.txt":         "/aggregate/licenses/sodium.txt",
}
var aggregateSources = map[string]string{
	"aggregate-chat.html":        "experiments/openmls-browser/web/aggregate-chat.html",
	"aggregate-chat.js":          "experiments/openmls-browser/web/aggregate-chat.js",
	"chat.css":                   "experiments/openmls-browser/web/chat.css",
	"native-worker.js":           "experiments/openmls-browser/web/native-worker.js",
	"trust-directory.js":         "experiments/openmls-browser/web/trust-directory.js",
	"aggregate-native-worker.js": "experiments/openmls-browser/web/aggregate-native-worker.js",
	"prepared-fork-worker.js":    "experiments/openmls-browser/web/prepared-fork-worker.js",
	"pkg.js":                     "bundle:family_mls_browser_experiment.js",
	"pkg.wasm":                   "bundle:family_mls_browser_experiment_bg.wasm",
	"cargo-notices.txt":          "experiments/openmls-browser/THIRD-PARTY-NOTICES.txt",
	"rust-notices.txt":           "experiments/openmls-browser/RUST-STDLIB-NOTICES.html",
	"aggregate-store.js":         "experiments/device-keystore/bundle/aggregate-store.js",
	"age-notices.txt":            "experiments/device-keystore/THIRD-PARTY-NOTICES.txt",
	"sodium-notices.txt":         "experiments/device-keystore/SODIUM-NOTICES.txt",
}

var aggregateHistoryPaths = func() map[string]string {
	out := make(map[string]string)
	for file, path := range aggregatePaths {
		out[file] = path
	}
	for _, file := range []string{"aggregate-history.css", "aggregate-history-ui.js", "aggregate-history-client.js", "aggregate-history-worker.js", "aggregate-history-export-worker.js"} {
		out[file] = "/" + file
	}
	out["aggregate-history.html"] = "/aggregate-history/"
	return out
}()
var aggregateHistorySources = func() map[string]string {
	out := make(map[string]string)
	for file, source := range aggregateSources {
		out[file] = source
	}
	for _, file := range []string{"aggregate-history.html", "aggregate-history.css", "aggregate-history-ui.js", "aggregate-history-client.js"} {
		out[file] = "experiments/device-keystore/" + file
	}
	for _, file := range []string{"aggregate-history-worker.js", "aggregate-history-export-worker.js"} {
		out[file] = "experiments/device-keystore/bundle/" + file
	}
	return out
}()

// Current history profile has an explicit source allowlist as well as byte pins.
var historySources = map[string]string{
	"chat.html":                "experiments/openmls-browser/web/chat.html",
	"chat.css":                 "experiments/openmls-browser/web/chat.css",
	"chat.js":                  "experiments/openmls-browser/web/chat.js",
	"native-worker.js":         "experiments/openmls-browser/web/native-worker.js",
	"trust-directory.js":       "experiments/openmls-browser/web/trust-directory.js",
	"pkg.js":                   "bundle:family_mls_browser_experiment.js",
	"pkg.wasm":                 "bundle:family_mls_browser_experiment_bg.wasm",
	"cargo-notices.txt":        "experiments/openmls-browser/THIRD-PARTY-NOTICES.txt",
	"rust-notices.txt":         "experiments/openmls-browser/RUST-STDLIB-NOTICES.html",
	"vault-chat.html":          "experiments/openmls-browser/web/vault-chat.html",
	"vault-chat.js":            "experiments/openmls-browser/web/vault-chat.js",
	"vault-native-worker.js":   "experiments/openmls-browser/web/vault-native-worker.js",
	"native-vault-store.js":    "experiments/device-keystore/bundle/native-vault-store.js",
	"age-notices.txt":          "experiments/device-keystore/THIRD-PARTY-NOTICES.txt",
	"sodium-notices.txt":       "experiments/device-keystore/SODIUM-NOTICES.txt",
	"history.html":             "experiments/device-keystore/history.html",
	"history.css":              "experiments/device-keystore/history.css",
	"history-ui.js":            "experiments/device-keystore/history-ui.js",
	"history-client.js":        "experiments/device-keystore/history-client.js",
	"history-worker.js":        "experiments/device-keystore/bundle/history-worker.js",
	"history-export-worker.js": "experiments/device-keystore/bundle/history-export-worker.js",
}

func loadEncryptedAssets(source fs.FS, manifest []byte) (*EncryptedAssets, error) {
	return loadAssetProfile(source, manifest, encryptedPaths, 1)
}
func loadAssetProfile(source fs.FS, manifest []byte, paths map[string]string, version int) (*EncryptedAssets, error) {
	if source == nil || len(manifest) > 8192 {
		return nil, fmt.Errorf("encrypted assets absent or invalid; build with prepared assets for the selected synthetic UI")
	}
	var spec encryptedManifestSpec
	decoder := json.NewDecoder(bytes.NewReader(manifest))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&spec) != nil || decoder.Decode(new(any)) != io.EOF || spec.Version != version || spec.WorkerState != 4 || len(spec.Files) != len(paths) {
		return nil, ErrInvalid
	}
	canonical, e := json.MarshalIndent(spec, "", "  ")
	if e != nil || !bytes.Equal(append(canonical, '\n'), manifest) {
		return nil, ErrInvalid
	}
	entries, e := fs.ReadDir(source, ".")
	if e != nil || len(entries) != len(paths) {
		return nil, ErrInvalid
	}
	for _, entry := range entries {
		if entry.Type() != 0 || paths[entry.Name()] == "" {
			return nil, ErrInvalid
		}
	}
	out := &EncryptedAssets{files: make(map[string]encryptedAsset), version: version}
	total := 0
	for _, entry := range spec.Files {
		if paths[entry.File] != entry.URL || entry.URL == "" || entry.Bytes <= 0 || entry.Bytes > 2*1024*1024 || len(entry.SHA256) != 64 {
			return nil, ErrInvalid
		}
		if _, exists := out.files[entry.URL]; exists {
			return nil, ErrInvalid
		}
		kind := "text/javascript; charset=utf-8"
		switch entry.File {
		case "chat.html", "vault-chat.html", "history.html", "aggregate-chat.html", "aggregate-history.html", "successor.html", "successor-handoff.html", "candidate-preparation.html", "peer-preparation.html":
			kind = "text/html; charset=utf-8"
		case "chat.css", "history.css", "aggregate-history.css", "successor-ui.css", "candidate-preparation.css", "peer-preparation.css":
			kind = "text/css; charset=utf-8"
		case "pkg.wasm":
			kind = "application/wasm"
		case "cargo-notices.txt", "rust-notices.txt", "age-notices.txt", "sodium-notices.txt":
			kind = "text/plain; charset=utf-8"
		}
		if entry.Type != kind || (version == 4 && aggregateSources[entry.File] != entry.Source) || (version == 5 && historySources[entry.File] != entry.Source) || (version == 6 && aggregateHistorySources[entry.File] != entry.Source) || (version == 7 && successorSources[entry.File] != entry.Source) || (version == 8 && candidateSources[entry.File] != entry.Source) || (version == 9 && peerSources[entry.File] != entry.Source) {
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
func LoadVaultAssets() (*EncryptedAssets, error) {
	return loadAssetProfile(compiledVaultAssets, vaultManifest, vaultPaths, 2)
}
func LoadHistoryAssets() (*EncryptedAssets, error) {
	return loadAssetProfile(compiledHistoryAssets, historyManifest, historyPaths, 5)
}
func LoadAggregateAssets() (*EncryptedAssets, error) {
	return loadAssetProfile(compiledAggregateAssets, aggregateManifest, aggregatePaths, 4)
}
func LoadAggregateHistoryAssets() (*EncryptedAssets, error) {
	return loadAssetProfile(compiledAggregateHistoryAssets, aggregateHistoryManifest, aggregateHistoryPaths, 6)
}
func NewEncryptedAccessHandler(store *Store, authority *access.Authority, bundle *EncryptedAssets, admission *AdmissionAuthority) (http.Handler, error) {
	if bundle == nil || (bundle.version != 1 && bundle.version != 2 && bundle.version != 5 && bundle.version != 4 && bundle.version != 6 && bundle.version != 7 && bundle.version != 8 && bundle.version != 9) || (bundle.version == 1 && len(bundle.files) != len(encryptedPaths)) || (bundle.version == 2 && len(bundle.files) != len(vaultPaths)) || (bundle.version == 5 && len(bundle.files) != len(historyPaths)) || (bundle.version == 4 && len(bundle.files) != len(aggregatePaths)) || (bundle.version == 6 && len(bundle.files) != len(aggregateHistoryPaths)) || (bundle.version == 7 && len(bundle.files) != len(successorPaths)) || (bundle.version == 8 && len(bundle.files) != len(candidatePaths)) || (bundle.version == 9 && len(bundle.files) != len(peerPaths)) {
		return nil, ErrInvalid
	}
	handler, e := NewAccessHandler(store, authority, admission)
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
