package chat

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
	"time"
)

func assetFixture(t *testing.T) (fstest.MapFS, []byte) {
	t.Helper()
	var spec encryptedManifestSpec
	if json.Unmarshal(encryptedManifest, &spec) != nil {
		t.Fatal("manifest")
	}
	files := fstest.MapFS{}
	for i := range spec.Files {
		entry := &spec.Files[i]
		data := []byte("synthetic compiled public " + entry.File)
		sum := sha256.Sum256(data)
		entry.Bytes = len(data)
		entry.SHA256 = hex.EncodeToString(sum[:])
		files[entry.File] = &fstest.MapFile{Data: data, Mode: 0600}
	}
	data, e := json.MarshalIndent(spec, "", "  ")
	if e != nil {
		t.Fatal(e)
	}
	return files, append(data, '\n')
}
func TestEncryptedAssetIntegrityAndClosedManifest(t *testing.T) {
	files, manifest := assetFixture(t)
	bundle, e := loadEncryptedAssets(files, manifest)
	if e != nil || len(bundle.files) != 9 {
		t.Fatal(e)
	}
	for _, change := range []string{"missing", "unknown", "corrupt", "oversize", "symlink", "directory", "wrong-version", "wrong-worker", "duplicate-key", "alias", "trailing", "wrong-mime", "duplicate-file", "wrong-path"} {
		t.Run(change, func(t *testing.T) {
			files, raw := assetFixture(t)
			var spec encryptedManifestSpec
			json.Unmarshal(raw, &spec)
			switch change {
			case "missing":
				delete(files, "chat.js")
			case "unknown":
				files["unexpected"] = &fstest.MapFile{Data: []byte("retained")}
			case "corrupt":
				files["chat.js"].Data = []byte("changed")
			case "oversize":
				files["chat.js"].Data = bytes.Repeat([]byte{1}, 2*1024*1024+1)
			case "symlink":
				files["chat.js"].Mode = fs.ModeSymlink | 0600
			case "directory":
				files["chat.js"].Mode = fs.ModeDir | 0700
			case "wrong-version":
				spec.Version = 2
			case "wrong-worker":
				spec.WorkerState = 3
			case "wrong-mime":
				spec.Files[0].Type = "text/javascript"
			case "duplicate-file":
				spec.Files[1] = spec.Files[0]
			case "wrong-path":
				spec.Files[0].URL = "/../chat.html"
			}
			if strings.HasPrefix(change, "wrong-") || change == "duplicate-file" {
				raw, _ = json.MarshalIndent(spec, "", "  ")
				raw = append(raw, '\n')
			}
			switch change {
			case "duplicate-key":
				raw = bytes.Replace(raw, []byte(`"version": 1,`), []byte(`"version": 7, "version": 1,`), 1)
			case "alias":
				raw = bytes.Replace(raw, []byte(`"version"`), []byte(`"Version"`), 1)
			case "trailing":
				raw = append(raw, []byte(`{}`)...)
			}
			if _, e := loadEncryptedAssets(files, raw); e == nil {
				t.Fatal("accepted", change)
			}
		})
	}
	if _, e := loadEncryptedAssets(nil, manifest); e == nil {
		t.Fatal("missing compiled assets accepted")
	}
}
func TestEncryptedAssetAdmissionRoutingAndLegacyPreservation(t *testing.T) {
	store, authority, config, key, legacy := accessFixture(t)
	files, manifest := assetFixture(t)
	bundle, e := loadEncryptedAssets(files, manifest)
	if e != nil {
		t.Fatal(e)
	}
	h, e := NewEncryptedAccessHandler(store, authority, bundle)
	if e != nil {
		t.Fatal(e)
	}
	server := httptest.NewServer(h)
	defer server.Close()
	token := assertion(t, config, key, "owner", time.Now().Add(time.Minute))
	for _, entry := range encryptedPaths {
		code, _ := accessRequest(t, server, "", "GET", entry, nil, nil)
		if code != 401 {
			t.Fatalf("unauth %s %d", entry, code)
		}
		r, _ := http.NewRequest("GET", server.URL+entry, nil)
		r.Header.Set("Cf-Access-Jwt-Assertion", token)
		r.Header.Set("Sec-Fetch-Site", "none")
		response, e := server.Client().Do(r)
		if e != nil {
			t.Fatal(e)
		}
		data, _ := io.ReadAll(response.Body)
		response.Body.Close()
		if response.StatusCode != 200 || !bytes.Equal(data, bundle.files[entry].data) || response.Header.Get("Content-Type") != bundle.files[entry].kind || response.Header.Get("Cache-Control") != "no-store" || response.Header.Get("X-Content-Type-Options") != "nosniff" {
			t.Fatal("asset response", entry, response.StatusCode)
		}
		csp := response.Header.Get("Content-Security-Policy")
		if !strings.Contains(csp, "'wasm-unsafe-eval'") || strings.Contains(csp, "'unsafe-eval'") {
			t.Fatal("CSP")
		}
	}
	for _, path := range []string{"/encrypted", "/%65ncrypted/", "/encrypted/?v=1", "/pkg/unknown.wasm", "/encrypted/../chat.html"} {
		code, _ := accessRequest(t, server, token, "GET", path, nil, nil)
		if code == 200 {
			t.Fatal("alias served", path)
		}
	}
	for _, headers := range []map[string]string{{"Origin": "https://other.invalid"}, {"Sec-Fetch-Site": "cross-site"}, {"X-Family-Actor": "bob"}, {"Authorization": "Bearer synthetic-alice", "Cf-Access-Jwt-Assertion": "invalid"}} {
		code, _ := accessRequest(t, server, token, "GET", "/encrypted/", nil, headers)
		if code == 200 {
			t.Fatal("bad admission accepted")
		}
	}
	_, before := accessRequest(t, legacy, "", "GET", "/", nil, nil)
	code, after := accessRequest(t, server, "", "GET", "/", nil, nil)
	if code != 200 || !bytes.Equal(before, after) {
		t.Fatal("legacy changed")
	}
	code, _ = accessRequest(t, legacy, token, "GET", "/encrypted/", nil, nil)
	if code == 200 {
		t.Fatal("implicit activation")
	}
	config.People = nil
	if e := authority.Replace(config); e != nil {
		t.Fatal(e)
	}
	code, _ = accessRequest(t, server, token, "GET", "/encrypted/", nil, nil)
	if code != 401 {
		t.Fatal("revoked asset", code)
	}
	if _, e := NewEncryptedAccessHandler(store, nil, bundle); e == nil {
		t.Fatal("fixture fallback")
	}
}
func TestCompiledEncryptedBundleSelectedOnlyWhenPresent(t *testing.T) {
	bundle, e := LoadEncryptedAssets()
	if compiledEncryptedAssets == nil {
		if e == nil || bundle != nil {
			t.Fatal("unbundled accepted")
		}
		return
	}
	if e != nil || len(bundle.files) != 9 {
		t.Fatal(e)
	}
	if !bytes.HasPrefix(bundle.files["/pkg/family_mls_browser_experiment_bg.wasm"].data, []byte{0, 'a', 's', 'm', 1, 0, 0, 0}) {
		t.Fatal("not WASM1")
	}
}
