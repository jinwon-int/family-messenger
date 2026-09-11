package chat

// Explicit synthetic preparation/declaration profile; prior pins stay unchanged.
var custodyPaths = map[string]string{
	"custody-ceremony.html":           "/custody-ceremony/",
	"custody-ceremony.css":            "/custody-ceremony.css",
	"custody-ceremony-ui.js":          "/custody-ceremony-ui.js",
	"custody-ceremony-client.js":      "/custody-ceremony-client.js",
	"candidate-preparation-client.js": "/candidate-preparation-client.js",
	"peer-preparation-client.js":      "/peer-preparation-client.js",
	"successor-handoff.js":            "/successor-handoff.js",
	"trust-directory.js":              "/trust-directory.js",
	"candidate-worker.js":             "/candidate-worker.js",
	"successor-peer-worker.js":        "/successor-peer-worker.js",
	"candidate-custody-worker.js":     "/candidate-custody-worker.js",
	"peer-custody-worker.js":          "/peer-custody-worker.js",
	"custody-worker.js":               "/custody-worker.js",
	"custody-declaration.js":          "/custody-declaration.js",
	"pkg.js":                          "/pkg/family_mls_browser_experiment.js",
	"pkg.wasm":                        "/pkg/family_mls_browser_experiment_bg.wasm",
	"cargo-notices.txt":               "/custody-ceremony/licenses/cargo.txt",
	"rust-notices.txt":                "/custody-ceremony/licenses/rust.txt",
	"candidate-store.js":              "/candidate-store.js",
	"successor-peer-store.js":         "/successor-peer-store.js",
	"age-notices.txt":                 "/custody-ceremony/licenses/age.txt",
	"sodium-notices.txt":              "/custody-ceremony/licenses/sodium.txt",
}
var custodySources = map[string]string{
	"custody-ceremony.html":           "experiments/openmls-browser/web/custody-ceremony.html",
	"custody-ceremony.css":            "experiments/openmls-browser/web/custody-ceremony.css",
	"custody-ceremony-ui.js":          "experiments/openmls-browser/web/custody-ceremony-ui.js",
	"custody-ceremony-client.js":      "experiments/openmls-browser/web/custody-ceremony-client.js",
	"candidate-preparation-client.js": "experiments/openmls-browser/web/candidate-preparation-client.js",
	"peer-preparation-client.js":      "experiments/openmls-browser/web/peer-preparation-client.js",
	"successor-handoff.js":            "experiments/openmls-browser/web/successor-handoff.js",
	"trust-directory.js":              "experiments/openmls-browser/web/trust-directory.js",
	"candidate-worker.js":             "experiments/openmls-browser/web/candidate-worker.js",
	"successor-peer-worker.js":        "experiments/openmls-browser/web/successor-peer-worker.js",
	"candidate-custody-worker.js":     "experiments/openmls-browser/web/candidate-custody-worker.js",
	"peer-custody-worker.js":          "experiments/openmls-browser/web/peer-custody-worker.js",
	"custody-worker.js":               "experiments/openmls-browser/web/custody-worker.js",
	"custody-declaration.js":          "experiments/openmls-browser/web/custody-declaration.js",
	"pkg.js":                          "bundle:family_mls_browser_experiment.js",
	"pkg.wasm":                        "bundle:family_mls_browser_experiment_bg.wasm",
	"cargo-notices.txt":               "experiments/openmls-browser/THIRD-PARTY-NOTICES.txt",
	"rust-notices.txt":                "experiments/openmls-browser/RUST-STDLIB-NOTICES.html",
	"candidate-store.js":              "experiments/device-keystore/bundle/candidate-store.js",
	"successor-peer-store.js":         "experiments/device-keystore/bundle/successor-peer-store.js",
	"age-notices.txt":                 "experiments/device-keystore/THIRD-PARTY-NOTICES.txt",
	"sodium-notices.txt":              "experiments/device-keystore/SODIUM-NOTICES.txt",
}

func LoadCustodyAssets() (*EncryptedAssets, error) {
	return loadAssetProfile(compiledCustodyAssets, custodyManifest, custodyPaths, 10)
}
