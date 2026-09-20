package chat

import (
	"bytes"
	"encoding/json"
	"io/fs"
	"testing"
	"testing/fstest"
)

func TestConfirmationAssetClosedProfile(t *testing.T) {
	for _, change := range []string{"valid", "missing", "extra", "corrupt", "symlink", "directory", "version", "source", "url", "mime", "duplicate", "trailing"} {
		t.Run(change, func(t *testing.T) {
			files, raw := assetProfileFixture(t, confirmationManifest)
			var spec encryptedManifestSpec
			json.Unmarshal(raw, &spec)
			switch change {
			case "missing":
				delete(files, "successor-confirmation-store.js")
			case "extra":
				files["secret"] = &fstest.MapFile{Data: []byte("retained")}
			case "corrupt":
				files["successor-confirmation-store.js"].Data[0] ^= 1
			case "symlink":
				files["successor-confirmation-store.js"].Mode = fs.ModeSymlink | 0600
			case "directory":
				files["successor-confirmation-store.js"].Mode = fs.ModeDir | 0700
			case "version":
				spec.Version = 6
			case "source":
				spec.Files[0].Source = "tests/fixtures/forged.js"
			case "url":
				spec.Files[0].URL = "/main.js"
			case "mime":
				spec.Files[0].Type = "text/javascript; charset=utf-8"
			}
			if change == "version" || change == "source" || change == "url" || change == "mime" {
				raw, _ = json.MarshalIndent(spec, "", "  ")
				raw = append(raw, '\n')
			}
			if change == "duplicate" {
				raw = bytes.Replace(raw, []byte(`"version":`), []byte(`"version": 1, "version":`), 1)
			}
			if change == "trailing" {
				raw = append(raw, []byte(`{}`)...)
			}
			b, e := loadAssetProfile(files, raw, confirmationPaths, 12)
			if change == "valid" {
				if e != nil || len(b.files) != 22 {
					t.Fatal(e)
				}
			} else if e == nil {
				t.Fatal("accepted", change)
			}
		})
	}
	for _, pin := range [][]byte{encryptedManifest, vaultManifest, historyManifest, retiredHistoryManifest, aggregateManifest, aggregateHistoryManifest, successorManifest, candidateManifest, peerManifest, custodyManifest, welcomeManifest} {
		f, r := assetProfileFixture(t, pin)
		if _, e := loadAssetProfile(f, r, confirmationPaths, 12); e == nil {
			t.Fatal("old profile substituted")
		}
	}
}

func TestConfirmationAssetAdmissionAndLegacy(t *testing.T) {
	testAssetAdmissionRoutingAndLegacyPreservation(t, confirmationManifest, confirmationPaths, 12)
}

func TestCompiledConfirmationExplicitSelection(t *testing.T) {
	b, e := LoadConfirmationAssets()
	if compiledConfirmationAssets == nil {
		if e == nil || b != nil {
			t.Fatal("implicit assets")
		}
		return
	}
	if e != nil || b.version != 12 || len(b.files) != 22 {
		t.Fatal(e)
	}
	for _, p := range []string{"/main.js", "/native-worker.js", "/closure-original-store.js", "/closure-instrumented.js", "/aggregate/", "/history/", "/encrypted/", "/vault/"} {
		if _, ok := b.files[p]; ok {
			t.Fatal("foreign asset", p)
		}
	}
}
