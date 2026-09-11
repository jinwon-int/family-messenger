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
	return assetProfileFixture(t, encryptedManifest)
}
func assetProfileFixture(t *testing.T, manifest []byte) (fstest.MapFS, []byte) {
	t.Helper()
	var spec encryptedManifestSpec
	if json.Unmarshal(manifest, &spec) != nil {
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
	testAssetIntegrityAndClosedManifest(t, encryptedManifest, encryptedPaths, 1)
}
func TestVaultAssetIntegrityAndClosedManifest(t *testing.T) {
	testAssetIntegrityAndClosedManifest(t, vaultManifest, vaultPaths, 2)
}
func testAssetIntegrityAndClosedManifest(t *testing.T, pin []byte, paths map[string]string, version int) {
	assetFixture := func(t *testing.T) (fstest.MapFS, []byte) { return assetProfileFixture(t, pin) }
	loadEncryptedAssets := func(source fs.FS, manifest []byte) (*EncryptedAssets, error) {
		return loadAssetProfile(source, manifest, paths, version)
	}
	files, manifest := assetFixture(t)
	bundle, e := loadEncryptedAssets(files, manifest)
	if e != nil || len(bundle.files) != len(paths) {
		t.Fatal(e)
	}
	for _, change := range []string{"missing", "unknown", "corrupt", "oversize", "symlink", "directory", "wrong-version", "wrong-worker", "duplicate-key", "alias", "trailing", "wrong-mime", "duplicate-file", "wrong-path"} {
		t.Run(change, func(t *testing.T) {
			files, raw := assetFixture(t)
			var spec encryptedManifestSpec
			json.Unmarshal(raw, &spec)
			switch change {
			case "missing":
				delete(files, "native-worker.js")
			case "unknown":
				files["unexpected"] = &fstest.MapFile{Data: []byte("retained")}
			case "corrupt":
				files["native-worker.js"].Data = []byte("changed")
			case "oversize":
				files["native-worker.js"].Data = bytes.Repeat([]byte{1}, 2*1024*1024+1)
			case "symlink":
				files["native-worker.js"].Mode = fs.ModeSymlink | 0600
			case "directory":
				files["native-worker.js"].Mode = fs.ModeDir | 0700
			case "wrong-version":
				spec.Version = 99
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
				raw = bytes.Replace(raw, []byte(`"version":`), []byte(`"version": 7, "version":`), 1)
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
	testAssetAdmissionRoutingAndLegacyPreservation(t, encryptedManifest, encryptedPaths, 1)
}
func TestVaultAssetAdmissionRoutingAndLegacyPreservation(t *testing.T) {
	testAssetAdmissionRoutingAndLegacyPreservation(t, vaultManifest, vaultPaths, 2)
}
func testAssetAdmissionRoutingAndLegacyPreservation(t *testing.T, pin []byte, paths map[string]string, version int) {
	assetFixture := func(t *testing.T) (fstest.MapFS, []byte) { return assetProfileFixture(t, pin) }
	loadEncryptedAssets := func(source fs.FS, manifest []byte) (*EncryptedAssets, error) {
		return loadAssetProfile(source, manifest, paths, version)
	}
	entryPath := paths["chat.html"]
	if entryPath == "" {
		entryPath = paths["aggregate-chat.html"]
	}
	if entryPath == "" {
		entryPath = paths["successor-handoff.html"]
	}
	if entryPath == "" {
		entryPath = paths["candidate-preparation.html"]
	}
	if version == 9 {
		entryPath = paths["peer-preparation.html"]
	}
	if version == 10 {
		entryPath = paths["custody-ceremony.html"]
	}
	store, authority, config, key, legacy := accessFixture(t)
	files, manifest := assetFixture(t)
	bundle, e := loadEncryptedAssets(files, manifest)
	if e != nil {
		t.Fatal(e)
	}
	h, e := NewEncryptedAccessHandler(store, authority, bundle, nil)
	if e != nil {
		t.Fatal(e)
	}
	server := httptest.NewServer(h)
	defer server.Close()
	token := assertion(t, config, key, "owner", time.Now().Add(time.Minute))
	for _, entry := range paths {
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
	for _, path := range []string{"/encrypted", "/%65ncrypted/", "/encrypted/?v=1", "/encrypted/?", "/pkg/unknown.wasm", "/encrypted/../chat.html", "/vault", "/%76ault/", "/vault/?", "/vault/?v=1", "/vault/../vault-chat.js", "/history", "/%68istory/", "/history/?", "/history/?v=1", "/history/../history-ui.js", "/history-forge-worker.js", "/aggregate", "/%61ggregate/", "/aggregate/?", "/aggregate/?v=1", "/aggregate/../aggregate-chat.js", "/aggregate-store-instrumented.js", "/aggregate-history", "/%61ggregate-history/", "/aggregate-history/?", "/aggregate-history/?v=1", "/aggregate-history/../aggregate-history-ui.js", "/aggregate-history-forge-worker.js"} {
		code, _ := accessRequest(t, server, token, "GET", path, nil, nil)
		if code == 200 {
			t.Fatal("alias served", path)
		}
	}
	for _, headers := range []map[string]string{{"Origin": "https://other.invalid"}, {"Sec-Fetch-Site": "cross-site"}, {"X-Family-Actor": "bob"}, {"Authorization": "Bearer synthetic-alice", "Cf-Access-Jwt-Assertion": "invalid"}} {
		code, _ := accessRequest(t, server, token, "GET", entryPath, nil, headers)
		if code == 200 {
			t.Fatal("bad admission accepted")
		}
	}
	_, before := accessRequest(t, legacy, "", "GET", "/", nil, nil)
	code, after := accessRequest(t, server, "", "GET", "/", nil, nil)
	if code != 200 || !bytes.Equal(before, after) {
		t.Fatal("legacy changed")
	}
	code, _ = accessRequest(t, legacy, token, "GET", entryPath, nil, nil)
	if code == 200 {
		t.Fatal("implicit activation")
	}
	config.People = nil
	if e := authority.Replace(config); e != nil {
		t.Fatal(e)
	}
	code, _ = accessRequest(t, server, token, "GET", entryPath, nil, nil)
	if code != 401 {
		t.Fatal("revoked asset", code)
	}
	if _, e := NewEncryptedAccessHandler(store, nil, bundle, nil); e == nil {
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

func TestCompiledVaultBundleSelectedOnlyWhenPresent(t *testing.T) {
	bundle, err := LoadVaultAssets()
	if compiledVaultAssets == nil {
		if err == nil || bundle != nil {
			t.Fatal("unbundled vault accepted")
		}
		return
	}
	if err != nil || len(bundle.files) != 15 || bundle.version != 2 {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(bundle.files["/pkg/family_mls_browser_experiment_bg.wasm"].data, []byte{0, 'a', 's', 'm', 1, 0, 0, 0}) {
		t.Fatal("not WASM1")
	}
}
func TestVaultAssetProfileCannotSubstituteLegacy(t *testing.T) {
	files, raw := assetProfileFixture(t, vaultManifest)
	if _, err := loadEncryptedAssets(files, raw); err == nil {
		t.Fatal("vault accepted as legacy")
	}
	files, raw = assetFixture(t)
	if _, err := loadAssetProfile(files, raw, vaultPaths, 2); err == nil {
		t.Fatal("legacy accepted as vault")
	}
	for _, name := range []string{"vault-chat.html", "vault-native-worker.js", "native-vault-store.js", "age-notices.txt", "sodium-notices.txt"} {
		files, raw := assetProfileFixture(t, vaultManifest)
		files[name].Data[0] ^= 1
		if _, err := loadAssetProfile(files, raw, vaultPaths, 2); err == nil {
			t.Fatal("tamper", name)
		}
	}
}

func TestHistoryAssetIntegrityAndClosedManifest(t *testing.T) {
	testAssetIntegrityAndClosedManifest(t, historyManifest, historyPaths, 5)
}
func TestRetiredHistoryV3CannotActivateAsCurrentHistory(t *testing.T) {
	sum := sha256.Sum256(retiredHistoryManifest)
	if hex.EncodeToString(sum[:]) != "2a33b7f9656df2719817ee2398432dd3070fe5715bcecae1510b32b9fcee06c9" {
		t.Fatal("retired manifest changed")
	}
	files, raw := assetProfileFixture(t, retiredHistoryManifest)
	if _, err := loadAssetProfile(files, raw, historyPaths, 5); err == nil {
		t.Fatal("retired version accepted")
	}
	legacy, err := loadAssetProfile(files, raw, historyPaths, 3)
	if err != nil {
		t.Fatal(err)
	}
	store, authority, _, _, _ := accessFixture(t)
	if _, err := NewEncryptedAccessHandler(store, authority, legacy, nil); err == nil {
		t.Fatal("retired profile activated")
	}
}
func TestCurrentHistorySourceSubstitutionDenied(t *testing.T) {
	files, raw := assetProfileFixture(t, historyManifest)
	var spec encryptedManifestSpec
	if json.Unmarshal(raw, &spec) != nil {
		t.Fatal("fixture")
	}
	for i := range spec.Files {
		if spec.Files[i].File == "history-client.js" {
			spec.Files[i].Source = "experiments/device-keystore/aggregate-history-client.js"
		}
	}
	altered, err := json.MarshalIndent(spec, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = loadAssetProfile(files, append(altered, '\n'), historyPaths, 5); err == nil {
		t.Fatal("source substituted")
	}
}
func TestHistoryAssetAdmissionRoutingAndLegacyPreservation(t *testing.T) {
	testAssetAdmissionRoutingAndLegacyPreservation(t, historyManifest, historyPaths, 5)
}
func TestCompiledHistoryBundleSelectedOnlyWhenPresent(t *testing.T) {
	bundle, err := LoadHistoryAssets()
	if compiledHistoryAssets == nil {
		if err == nil || bundle != nil {
			t.Fatal("unbundled history accepted")
		}
		return
	}
	if err != nil || len(bundle.files) != 21 || bundle.version != 5 {
		t.Fatal(err)
	}
	if _, ok := bundle.files["/history-forge-worker.js"]; ok {
		t.Fatal("test code included")
	}
	if !bytes.HasPrefix(bundle.files["/pkg/family_mls_browser_experiment_bg.wasm"].data, []byte{0, 'a', 's', 'm', 1, 0, 0, 0}) {
		t.Fatal("not WASM1")
	}
}
func TestHistoryProfileRejectsSubstitutionAndRecoveryAssetTamper(t *testing.T) {
	files, raw := assetProfileFixture(t, historyManifest)
	for _, profile := range []struct {
		paths   map[string]string
		version int
	}{{encryptedPaths, 1}, {vaultPaths, 2}} {
		if _, err := loadAssetProfile(files, raw, profile.paths, profile.version); err == nil {
			t.Fatal("history substituted older profile")
		}
	}
	for _, pin := range [][]byte{encryptedManifest, vaultManifest} {
		files, raw := assetProfileFixture(t, pin)
		if _, err := loadAssetProfile(files, raw, historyPaths, 5); err == nil {
			t.Fatal("older profile substituted history")
		}
	}
	for _, name := range []string{"history.html", "history.css", "history-ui.js", "history-client.js", "history-worker.js", "history-export-worker.js", "age-notices.txt", "sodium-notices.txt"} {
		files, raw := assetProfileFixture(t, historyManifest)
		files[name].Data[0] ^= 1
		if _, err := loadAssetProfile(files, raw, historyPaths, 5); err == nil {
			t.Fatal("tamper", name)
		}
	}
}

func TestAggregateAssetIntegrityAndClosedManifest(t *testing.T) {
	testAssetIntegrityAndClosedManifest(t, aggregateManifest, aggregatePaths, 4)
}
func TestAggregateAssetAdmissionRoutingAndLegacyPreservation(t *testing.T) {
	testAssetAdmissionRoutingAndLegacyPreservation(t, aggregateManifest, aggregatePaths, 4)
}
func TestCompiledAggregateBundleSelectedOnlyWhenPresent(t *testing.T) {
	bundle, err := LoadAggregateAssets()
	if compiledAggregateAssets == nil {
		if err == nil || bundle != nil {
			t.Fatal("unbundled aggregate accepted")
		}
		return
	}
	if err != nil || len(bundle.files) != 14 || bundle.version != 4 {
		t.Fatal(err)
	}
	for _, path := range []string{"/encrypted/", "/vault/", "/history/", "/aggregate-store-instrumented.js", "/native-aggregate-vault.js"} {
		if _, ok := bundle.files[path]; ok {
			t.Fatal("mixed profile", path)
		}
	}
	if !bytes.HasPrefix(bundle.files["/pkg/family_mls_browser_experiment_bg.wasm"].data, []byte{0, 'a', 's', 'm', 1, 0, 0, 0}) {
		t.Fatal("not WASM1")
	}
}
func TestAggregateSourcesAndProfileSubstitutionDenied(t *testing.T) {
	for _, prior := range []struct {
		raw     []byte
		paths   map[string]string
		version int
	}{
		{encryptedManifest, encryptedPaths, 1}, {vaultManifest, vaultPaths, 2}, {historyManifest, historyPaths, 5},
	} {
		f, r := assetProfileFixture(t, prior.raw)
		if _, e := loadAssetProfile(f, r, aggregatePaths, 4); e == nil {
			t.Fatal("old substituted aggregate")
		}
		f, r = assetProfileFixture(t, aggregateManifest)
		if _, e := loadAssetProfile(f, r, prior.paths, prior.version); e == nil {
			t.Fatal("aggregate substituted old")
		}
	}
	for _, name := range []string{"aggregate-chat.js", "aggregate-native-worker.js", "prepared-fork-worker.js", "aggregate-store.js", "pkg.wasm", "age-notices.txt", "sodium-notices.txt"} {
		files, raw := assetProfileFixture(t, aggregateManifest)
		files[name].Data[0] ^= 1
		if _, e := loadAssetProfile(files, raw, aggregatePaths, 4); e == nil {
			t.Fatal("tamper", name)
		}
	}
	files, raw := assetProfileFixture(t, aggregateManifest)
	var spec encryptedManifestSpec
	json.Unmarshal(raw, &spec)
	for i := range spec.Files {
		if spec.Files[i].File == "aggregate-store.js" {
			spec.Files[i].Source = "experiments/device-keystore/bundle/native-aggregate-vault.js"
		}
	}
	raw, _ = json.MarshalIndent(spec, "", "  ")
	raw = append(raw, '\n')
	if _, e := loadAssetProfile(files, raw, aggregatePaths, 4); e == nil {
		t.Fatal("generic precursor accepted")
	}
}

func TestAggregateHistoryAssetIntegrityAndClosedManifest(t *testing.T) {
	testAssetIntegrityAndClosedManifest(t, aggregateHistoryManifest, aggregateHistoryPaths, 6)
}
func TestAggregateHistoryAssetAdmissionRoutingAndLegacyPreservation(t *testing.T) {
	testAssetAdmissionRoutingAndLegacyPreservation(t, aggregateHistoryManifest, aggregateHistoryPaths, 6)
}
func TestCompiledAggregateHistorySelection(t *testing.T) {
	b, e := LoadAggregateHistoryAssets()
	if compiledAggregateHistoryAssets == nil {
		if e == nil || b != nil {
			t.Fatal("implicit activation")
		}
		return
	}
	if e != nil || b.version != 6 || len(b.files) != 20 {
		t.Fatal(e)
	}
	for _, p := range []string{"/history/", "/vault/", "/encrypted/", "/aggregate-history-forge-worker.js", "/main.js", "/native-aggregate-vault.js"} {
		if _, ok := b.files[p]; ok {
			t.Fatal("foreign asset", p)
		}
	}
}
func TestAggregateHistoryProfileAndSourceSubstitution(t *testing.T) {
	for _, pin := range [][]byte{encryptedManifest, vaultManifest, retiredHistoryManifest, historyManifest, aggregateManifest} {
		f, r := assetProfileFixture(t, pin)
		if _, e := loadAssetProfile(f, r, aggregateHistoryPaths, 6); e == nil {
			t.Fatal("old profile accepted")
		}
	}
	for _, field := range []string{"source", "recovery-tamper", "total-limit"} {
		f, r := assetProfileFixture(t, aggregateHistoryManifest)
		var spec encryptedManifestSpec
		json.Unmarshal(r, &spec)
		if field == "source" {
			spec.Files[len(spec.Files)-1].Source = "tests/fixtures/native-history/aggregate-forge-worker.js"
		}
		if field == "recovery-tamper" {
			f["aggregate-history-worker.js"].Data[0] ^= 1
		}
		if field == "total-limit" {
			for i := range spec.Files {
				d := bytes.Repeat([]byte{1}, 256*1024)
				h := sha256.Sum256(d)
				spec.Files[i].Bytes = len(d)
				spec.Files[i].SHA256 = hex.EncodeToString(h[:])
				f[spec.Files[i].File].Data = d
			}
		}
		r, _ = json.MarshalIndent(spec, "", "  ")
		r = append(r, '\n')
		if _, e := loadAssetProfile(f, r, aggregateHistoryPaths, 6); e == nil {
			t.Fatal(field)
		}
	}
}
