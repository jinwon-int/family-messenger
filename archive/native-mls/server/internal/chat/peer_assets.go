package chat

// Explicit peer-only profile; no change to any existing pin.
var peerPaths = map[string]string{
	"peer-preparation.html":      "/peer-preparation/",
	"peer-preparation.css":       "/peer-preparation.css",
	"peer-preparation-ui.js":     "/peer-preparation-ui.js",
	"peer-preparation-client.js": "/peer-preparation-client.js",
	"successor-handoff.js":       "/successor-handoff.js",
	"successor-peer-worker.js":   "/successor-peer-worker.js",
	"trust-directory.js":         "/trust-directory.js",
	"pkg.js":                     "/pkg/family_mls_browser_experiment.js",
	"pkg.wasm":                   "/pkg/family_mls_browser_experiment_bg.wasm",
	"cargo-notices.txt":          "/peer-preparation/licenses/cargo.txt",
	"rust-notices.txt":           "/peer-preparation/licenses/rust.txt",
	"successor-peer-store.js":    "/successor-peer-store.js",
	"age-notices.txt":            "/peer-preparation/licenses/age.txt",
	"sodium-notices.txt":         "/peer-preparation/licenses/sodium.txt",
}
var peerSources = map[string]string{
	"peer-preparation.html":      "experiments/openmls-browser/web/peer-preparation.html",
	"peer-preparation.css":       "experiments/openmls-browser/web/peer-preparation.css",
	"peer-preparation-ui.js":     "experiments/openmls-browser/web/peer-preparation-ui.js",
	"peer-preparation-client.js": "experiments/openmls-browser/web/peer-preparation-client.js",
	"successor-handoff.js":       "experiments/openmls-browser/web/successor-handoff.js",
	"successor-peer-worker.js":   "experiments/openmls-browser/web/successor-peer-worker.js",
	"trust-directory.js":         "experiments/openmls-browser/web/trust-directory.js",
	"pkg.js":                     "bundle:family_mls_browser_experiment.js",
	"pkg.wasm":                   "bundle:family_mls_browser_experiment_bg.wasm",
	"cargo-notices.txt":          "experiments/openmls-browser/THIRD-PARTY-NOTICES.txt",
	"rust-notices.txt":           "experiments/openmls-browser/RUST-STDLIB-NOTICES.html",
	"successor-peer-store.js":    "experiments/device-keystore/bundle/successor-peer-store.js",
	"age-notices.txt":            "experiments/device-keystore/THIRD-PARTY-NOTICES.txt",
	"sodium-notices.txt":         "experiments/device-keystore/SODIUM-NOTICES.txt",
}

func LoadPeerAssets() (*EncryptedAssets, error) {
	return loadAssetProfile(compiledPeerAssets, peerManifest, peerPaths, 9)
}
