package chat

// Explicit candidate-only profile; no change to any existing pin.
var candidatePaths = map[string]string{
	"candidate-preparation.html":      "/candidate-preparation/",
	"candidate-preparation.css":       "/candidate-preparation.css",
	"candidate-preparation-ui.js":     "/candidate-preparation-ui.js",
	"candidate-preparation-client.js": "/candidate-preparation-client.js",
	"candidate-attempts.js":           "/candidate-attempts.js",
	"successor-handoff.js":            "/successor-handoff.js",
	"candidate-worker.js":             "/candidate-worker.js",
	"trust-directory.js":              "/trust-directory.js",
	"pkg.js":                          "/pkg/family_mls_browser_experiment.js",
	"pkg.wasm":                        "/pkg/family_mls_browser_experiment_bg.wasm",
	"cargo-notices.txt":               "/candidate-preparation/licenses/cargo.txt",
	"rust-notices.txt":                "/candidate-preparation/licenses/rust.txt",
	"candidate-store.js":              "/candidate-store.js",
	"age-notices.txt":                 "/candidate-preparation/licenses/age.txt",
	"sodium-notices.txt":              "/candidate-preparation/licenses/sodium.txt",
}
var candidateSources = map[string]string{
	"candidate-preparation.html":      "experiments/openmls-browser/web/candidate-preparation.html",
	"candidate-preparation.css":       "experiments/openmls-browser/web/candidate-preparation.css",
	"candidate-preparation-ui.js":     "experiments/openmls-browser/web/candidate-preparation-ui.js",
	"candidate-preparation-client.js": "experiments/openmls-browser/web/candidate-preparation-client.js",
	"candidate-attempts.js":           "experiments/openmls-browser/web/candidate-attempts.js",
	"successor-handoff.js":            "experiments/openmls-browser/web/successor-handoff.js",
	"candidate-worker.js":             "experiments/openmls-browser/web/candidate-worker.js",
	"trust-directory.js":              "experiments/openmls-browser/web/trust-directory.js",
	"pkg.js":                          "bundle:family_mls_browser_experiment.js",
	"pkg.wasm":                        "bundle:family_mls_browser_experiment_bg.wasm",
	"cargo-notices.txt":               "experiments/openmls-browser/THIRD-PARTY-NOTICES.txt",
	"rust-notices.txt":                "experiments/openmls-browser/RUST-STDLIB-NOTICES.html",
	"candidate-store.js":              "experiments/device-keystore/bundle/candidate-store.js",
	"age-notices.txt":                 "experiments/device-keystore/THIRD-PARTY-NOTICES.txt",
	"sodium-notices.txt":              "experiments/device-keystore/SODIUM-NOTICES.txt",
}

func LoadCandidateAssets() (*EncryptedAssets, error) {
	return loadAssetProfile(compiledCandidateAssets, candidateManifest, candidatePaths, 8)
}
