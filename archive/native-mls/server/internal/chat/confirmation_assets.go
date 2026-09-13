package chat

// Profile12 exposes only the protected confirmation graph.
var confirmationPaths = map[string]string{
	"confirmation-ceremony.html":       "/confirmation-ceremony/",
	"confirmation-ceremony.css":        "/confirmation-ceremony.css",
	"confirmation-ceremony-ui.js":      "/confirmation-ceremony-ui.js",
	"confirmation-ceremony-client.js":  "/confirmation-ceremony-client.js",
	"custody-ceremony-client.js":       "/custody-ceremony-client.js",
	"candidate-preparation-client.js":  "/candidate-preparation-client.js",
	"peer-preparation-client.js":       "/peer-preparation-client.js",
	"successor-handoff.js":             "/successor-handoff.js",
	"trust-directory.js":               "/trust-directory.js",
	"custody-declaration.js":           "/custody-declaration.js",
	"handshake-wire.js":                "/handshake-wire.js",
	"confirmation-wire.js":             "/confirmation-wire.js",
	"confirmation-worker.js":           "/confirmation-worker.js",
	"candidate-confirmation-worker.js": "/candidate-confirmation-worker.js",
	"peer-confirmation-worker.js":      "/peer-confirmation-worker.js",
	"pkg.js":                           "/pkg/family_mls_browser_experiment.js",
	"pkg.wasm":                         "/pkg/family_mls_browser_experiment_bg.wasm",
	"cargo-notices.txt":                "/confirmation-ceremony/licenses/cargo.txt",
	"rust-notices.txt":                 "/confirmation-ceremony/licenses/rust.txt",
	"age-notices.txt":                  "/confirmation-ceremony/licenses/age.txt",
	"sodium-notices.txt":               "/confirmation-ceremony/licenses/sodium.txt",
	"successor-confirmation-store.js":  "/successor-confirmation-store.js",
}
var confirmationSources = map[string]string{
	"confirmation-ceremony.html":       "experiments/openmls-browser/web/confirmation-ceremony.html",
	"confirmation-ceremony.css":        "experiments/openmls-browser/web/confirmation-ceremony.css",
	"confirmation-ceremony-ui.js":      "experiments/openmls-browser/web/confirmation-ceremony-ui.js",
	"confirmation-ceremony-client.js":  "experiments/openmls-browser/web/confirmation-ceremony-client.js",
	"custody-ceremony-client.js":       "experiments/openmls-browser/web/custody-ceremony-client.js",
	"candidate-preparation-client.js":  "experiments/openmls-browser/web/candidate-preparation-client.js",
	"peer-preparation-client.js":       "experiments/openmls-browser/web/peer-preparation-client.js",
	"successor-handoff.js":             "experiments/openmls-browser/web/successor-handoff.js",
	"trust-directory.js":               "experiments/openmls-browser/web/trust-directory.js",
	"custody-declaration.js":           "experiments/openmls-browser/web/custody-declaration.js",
	"handshake-wire.js":                "experiments/openmls-browser/web/handshake-wire.js",
	"confirmation-wire.js":             "experiments/openmls-browser/web/confirmation-wire.js",
	"confirmation-worker.js":           "experiments/openmls-browser/web/confirmation-worker.js",
	"candidate-confirmation-worker.js": "experiments/openmls-browser/web/candidate-confirmation-worker.js",
	"peer-confirmation-worker.js":      "experiments/openmls-browser/web/peer-confirmation-worker.js",
	"pkg.js":                           "bundle:family_mls_browser_experiment.js",
	"pkg.wasm":                         "bundle:family_mls_browser_experiment_bg.wasm",
	"cargo-notices.txt":                "experiments/openmls-browser/THIRD-PARTY-NOTICES.txt",
	"rust-notices.txt":                 "experiments/openmls-browser/RUST-STDLIB-NOTICES.html",
	"age-notices.txt":                  "experiments/device-keystore/THIRD-PARTY-NOTICES.txt",
	"sodium-notices.txt":               "experiments/device-keystore/SODIUM-NOTICES.txt",
	"successor-confirmation-store.js":  "experiments/device-keystore/bundle/successor-confirmation-store.js",
}

func LoadConfirmationAssets() (*EncryptedAssets, error) {
	return loadAssetProfile(compiledConfirmationAssets, confirmationManifest, confirmationPaths, 12)
}
