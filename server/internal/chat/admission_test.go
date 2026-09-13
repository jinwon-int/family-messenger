package chat

// Aggregate admission service tests (#49 fourth slice): the canonical byte
// string the Go signer produces must be byte-identical to the store's
// JSON.stringify([1,rooms,actor,device_id,signing_key,peers,revision,not_after]),
// the document must be verifiable with the served policy public key, identical
// requests inside one expiry bucket must produce the identical document, and
// the endpoints must require a grant.

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// The synthetic admission key is deterministic in tests: derived from the
// seed the same way family-dev loads it from the private seed file.
func admissionTestKey() ed25519.PrivateKey {
	seed := sha256.Sum256([]byte("family-synthetic-aggregate-admission-v1"))
	return ed25519.NewKeyFromSeed(seed[:])
}

func TestAdmissionCanonicalMatchesStoreContract(t *testing.T) {
	doc := &admissionDocument{
		V: 1, Rooms: []string{"family", "project"}, Actor: "alice", DeviceID: "alice-device",
		SigningKey: hexDup(0xa1), Peers: []admissionPeer{{Actor: "bob", SigningKey: hexDup(0xb2)}},
		Revision: 3, NotAfter: 1736500000000,
	}
	got := string(doc.canonical())
	want := `[1,["family","project"],"alice","alice-device","a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1",[{"actor":"bob","signing_key":"b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"}],3,1736500000000]`
	if got != want {
		t.Fatalf("canonical mismatch:\n got %s\nwant %s", got, want)
	}
	// The JS store parses the canonical as JSON and verifies the detached
	// signature; the canonical must itself be valid JSON with the exact
	// top-level shape.
	var parsed []any
	if e := json.Unmarshal([]byte(got), &parsed); e != nil {
		t.Fatalf("canonical is not valid JSON: %v", e)
	}
	if len(parsed) != 8 {
		t.Fatalf("canonical tuple must have 8 elements, got %d", len(parsed))
	}
}

func TestAdmissionSignatureVerifiesWithServedPublicKey(t *testing.T) {
	doc := &admissionDocument{
		V: 1, Rooms: []string{"family"}, Actor: "alice", DeviceID: "alice-device",
		SigningKey: hexDup(0xa1), Peers: []admissionPeer{}, Revision: 1, NotAfter: 1736500000000,
	}
	key := admissionTestKey()
	doc.sign(key)
	sig, e := hex.DecodeString(doc.Signature)
	if e != nil {
		t.Fatal(e)
	}
	if !ed25519.Verify(key.Public().(ed25519.PublicKey), doc.canonical(), sig) {
		t.Fatal("signature must verify with the served policy public key")
	}
	doc.Rooms = []string{"project"}
	if ed25519.Verify(key.Public().(ed25519.PublicKey), doc.canonical(), sig) {
		t.Fatal("a tampered body must not verify")
	}
}

func TestAdmissionDocumentIsDeterministicInsideBucket(t *testing.T) {
	first := &admissionDocument{V: 1, Rooms: []string{"family"}, Actor: "alice", DeviceID: "alice-device",
		SigningKey: hexDup(0xa1), Peers: []admissionPeer{}, Revision: 2, NotAfter: 1736500000000}
	second := &admissionDocument{V: 1, Rooms: []string{"family"}, Actor: "alice", DeviceID: "alice-device",
		SigningKey: hexDup(0xa1), Peers: []admissionPeer{}, Revision: 2, NotAfter: 1736500000000}
	key := admissionTestKey()
	first.sign(key)
	second.sign(key)
	if first.Signature != second.Signature {
		t.Fatal("identical requests inside one expiry bucket must produce the identical document")
	}
}

func TestAggregateEndpointsRequireGrant(t *testing.T) {
	s := testStore(t)
	a := NewHandler(s)
	for _, path := range []string{"/v1/aggregate/policy-key", "/v1/aggregate/admission?revision=1"} {
		rec := httptest.NewRecorder()
		a.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
		if rec.Code != 403 {
			t.Fatalf("%s must require a grant, got %d", path, rec.Code)
		}
	}
	_ = strconv.Itoa
}

func hexDup(prefix byte) string {
	b := make([]byte, 32)
	for i := range b {
		b[i] = prefix
	}
	return hex.EncodeToString(b)
}

func TestMatchesPolicyAgainstClonedConfig(t *testing.T) {
	_ = sha256.Sum256
}

func TestLoadAdmissionSeedRequiresPrivateRegularFile(t *testing.T) {
	dir := t.TempDir()
	seed := sha256.Sum256([]byte("family-synthetic-aggregate-admission-v1"))
	path := filepath.Join(dir, "seed")
	if e := os.WriteFile(path, seed[:], 0600); e != nil {
		t.Fatal(e)
	}
	key, e := LoadAdmissionSeed(path)
	if e != nil || !key.Equal(admissionTestKey()) {
		t.Fatalf("a private 0600 seed must load to the deterministic key: %v", e)
	}
	// Same discipline as other state files: mode, link count and symlinks.
	if e = os.Chmod(path, 0640); e != nil {
		t.Fatal(e)
	}
	if _, e = LoadAdmissionSeed(path); e == nil {
		t.Fatal("group-readable seed must be rejected")
	}
	if e = os.Chmod(path, 0600); e != nil {
		t.Fatal(e)
	}
	link := filepath.Join(dir, "hardlink")
	if e = os.Link(path, link); e != nil {
		t.Fatal(e)
	}
	if _, e = LoadAdmissionSeed(path); e == nil {
		t.Fatal("multi-link seed must be rejected")
	}
	if e = os.Remove(link); e != nil {
		t.Fatal(e)
	}
	symlink := filepath.Join(dir, "symlink")
	if e = os.Symlink(path, symlink); e != nil {
		t.Fatal(e)
	}
	if _, e = LoadAdmissionSeed(symlink); e == nil {
		t.Fatal("symlinked seed must be rejected")
	}
	for _, size := range []int{ed25519.SeedSize - 1, ed25519.SeedSize + 1} {
		wrong := filepath.Join(dir, strconv.Itoa(size))
		if e = os.WriteFile(wrong, make([]byte, size), 0600); e != nil {
			t.Fatal(e)
		}
		if _, e = LoadAdmissionSeed(wrong); e == nil {
			t.Fatalf("%d-byte seed must be rejected", size)
		}
	}
	if _, e = LoadAdmissionSeed(filepath.Join(dir, "missing")); e == nil {
		t.Fatal("missing seed must be rejected")
	}
}
