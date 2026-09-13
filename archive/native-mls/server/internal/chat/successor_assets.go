package chat

// Separate successor profile; prior profiles retain their exact source/route pins.
var successorPaths = map[string]string{
	"successor.html":                "/successor/",
	"successor-ui.js":               "/successor-ui.js",
	"successor-ui.css":              "/successor-ui.css",
	"successor-handoff.html":        "/successor-handoff/",
	"successor-handoff.js":          "/successor-handoff.js",
	"successor-handoff-ui.js":       "/successor-handoff-ui.js",
	"successor-lifecycle-worker.js": "/successor-lifecycle-worker.js",
	"candidate-lifecycle-worker.js": "/candidate-lifecycle-worker.js",
	"peer-lifecycle-worker.js":      "/peer-lifecycle-worker.js",
	"trust-directory.js":            "/trust-directory.js",
	"custody-declaration.js":        "/custody-declaration.js",
	"handshake-wire.js":             "/handshake-wire.js",
	"confirmation-wire.js":          "/confirmation-wire.js",
	"lease-wire.js":                 "/lease-wire.js",
	"enrollment-wire.js":            "/enrollment-wire.js",
	"closure-wire.js":               "/closure-wire.js",
	"pkg.js":                        "/pkg/family_mls_browser_experiment.js",
	"pkg.wasm":                      "/pkg/family_mls_browser_experiment_bg.wasm",
	"cargo-notices.txt":             "/successor/licenses/cargo.txt",
	"rust-notices.txt":              "/successor/licenses/rust.txt",
	"successor-closure-store.js":    "/successor-closure-store.js",
	"age-notices.txt":               "/successor/licenses/age.txt",
	"sodium-notices.txt":            "/successor/licenses/sodium.txt",
}
var successorSources = map[string]string{
	"successor.html":                "experiments/openmls-browser/web/successor.html",
	"successor-ui.js":               "experiments/openmls-browser/web/successor-ui.js",
	"successor-ui.css":              "experiments/openmls-browser/web/successor-ui.css",
	"successor-handoff.html":        "experiments/openmls-browser/web/successor-handoff.html",
	"successor-handoff.js":          "experiments/openmls-browser/web/successor-handoff.js",
	"successor-handoff-ui.js":       "experiments/openmls-browser/web/successor-handoff-ui.js",
	"successor-lifecycle-worker.js": "experiments/openmls-browser/web/successor-lifecycle-worker.js",
	"candidate-lifecycle-worker.js": "experiments/openmls-browser/web/candidate-lifecycle-worker.js",
	"peer-lifecycle-worker.js":      "experiments/openmls-browser/web/peer-lifecycle-worker.js",
	"trust-directory.js":            "experiments/openmls-browser/web/trust-directory.js",
	"custody-declaration.js":        "experiments/openmls-browser/web/custody-declaration.js",
	"handshake-wire.js":             "experiments/openmls-browser/web/handshake-wire.js",
	"confirmation-wire.js":          "experiments/openmls-browser/web/confirmation-wire.js",
	"lease-wire.js":                 "experiments/openmls-browser/web/lease-wire.js",
	"enrollment-wire.js":            "experiments/openmls-browser/web/enrollment-wire.js",
	"closure-wire.js":               "experiments/openmls-browser/web/closure-wire.js",
	"pkg.js":                        "bundle:family_mls_browser_experiment.js",
	"pkg.wasm":                      "bundle:family_mls_browser_experiment_bg.wasm",
	"cargo-notices.txt":             "experiments/openmls-browser/THIRD-PARTY-NOTICES.txt",
	"rust-notices.txt":              "experiments/openmls-browser/RUST-STDLIB-NOTICES.html",
	"successor-closure-store.js":    "experiments/device-keystore/bundle/successor-closure-store.js",
	"age-notices.txt":               "experiments/device-keystore/THIRD-PARTY-NOTICES.txt",
	"sodium-notices.txt":            "experiments/device-keystore/SODIUM-NOTICES.txt",
}

func LoadSuccessorAssets() (*EncryptedAssets, error) {
	return loadAssetProfile(compiledSuccessorAssets, successorManifest, successorPaths, 7)
}
