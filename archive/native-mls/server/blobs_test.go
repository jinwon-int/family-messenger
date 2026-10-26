// Room-scoped blob store tests (#499 stage 1, blobs.go). Every route test
// drives the real routes() mux over httptest with a throwaway SQLite file and
// data dir. Pinned: upload 201 with id = sha256 of the bytes, byte-identical
// download with no-store/nosniff headers and Range support, idempotent replay
// 200, the membership gate on both routes (403 not_a_member) and the JWT
// subject binding (403 device_subject_mismatch), 404 for an unknown room or
// blob, 410 and file removal on close, 413 over the body limit and over the
// room cap (blob and event bytes share it), 400 validation, TTL/cursor
// retention, the orphan/temp sweep and -reset-room.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func blobSum(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// doRaw is doJSON with explicit headers and the response headers returned.
func doRaw(t *testing.T, srv *httptest.Server, method, path string, body []byte, headers map[string]string) (int, []byte, http.Header) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, srv.URL+path, rd)
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, raw, resp.Header
}

func decodeBlob(t *testing.T, raw []byte) blobResponse {
	t.Helper()
	var b blobResponse
	if err := json.Unmarshal(raw, &b); err != nil {
		t.Fatalf("response is not a blobResponse: %v (%s)", err, raw)
	}
	return b
}

// seededBlobRoom: enforcement on, a1 (alice) and b1 (bob) members of room r,
// c1 (carol) active but outside.
func seededBlobRoom(t *testing.T, pol policy) (*relay, *httptest.Server) {
	t.Helper()
	r, srv, st, _, first := newEnforcedRelay(t, pol)
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "b1", "bob")
	enrollDevice(t, st, first, "c1", "carol")
	boot := postCommitBody(t, "a1", "boot", 0, nil, membersOf([2]string{"a1", "alice"}, [2]string{"b1", "bob"}), []byte("bootstrap"))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", boot); code != http.StatusCreated {
		t.Fatalf("bootstrap: status=%d body=%s", code, raw)
	}
	return r, srv
}

func TestBlobPolicyAndLimits(t *testing.T) {
	if maxBlobBytes != 50<<20+64<<10 {
		t.Fatalf("maxBlobBytes = %d, want 50 MiB + 64 KiB (#499 owner decision)", maxBlobBytes)
	}
	if defaultPolicy().AppEventTTLSeconds != 30*24*60*60 {
		t.Fatalf("blob retention follows AppEventTTLSeconds = 30 days (#499)")
	}
}

func TestBlobUploadDownloadAndReplay(t *testing.T) {
	r, srv := seededBlobRoom(t, testPolicy())
	payload := bytes.Repeat([]byte("ciphertext-"), 1000)
	id := blobSum(payload)

	code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/blobs?device=a1", payload)
	if code != http.StatusCreated {
		t.Fatalf("upload: status=%d body=%s", code, raw)
	}
	if got := decodeBlob(t, raw); got.ID != id || got.Size != int64(len(payload)) {
		t.Fatalf("upload response = %+v, want id=%s size=%d", got, id, len(payload))
	}
	path := filepath.Join(r.db.dir, blobDirName, "r", id)
	if info, err := os.Stat(path); err != nil || info.Size() != int64(len(payload)) || info.Mode().Perm() != 0o600 {
		t.Fatalf("blob file: info=%v err=%v (want %d bytes, 0600)", info, err, len(payload))
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_blobs WHERE room = 'r' AND id = ? AND device = 'a1'`, id); n != 1 {
		t.Fatalf("metadata rows = %d", n)
	}
	// The other member reads it back byte-identical, with safe headers.
	code, got, hdr := doRaw(t, srv, "GET", "/v2/rooms/r/blobs/"+id+"?device=b1", nil, nil)
	if code != http.StatusOK || !bytes.Equal(got, payload) {
		t.Fatalf("download: status=%d len=%d", code, len(got))
	}
	for k, want := range map[string]string{"Content-Type": "application/octet-stream", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"} {
		if hdr.Get(k) != want {
			t.Fatalf("header %s = %q, want %q", k, hdr.Get(k), want)
		}
	}
	// Range: a phone can resume a large download.
	code, part, _ := doRaw(t, srv, "GET", "/v2/rooms/r/blobs/"+id+"?device=b1", nil, map[string]string{"Range": "bytes=11-21"})
	if code != http.StatusPartialContent || !bytes.Equal(part, payload[11:22]) {
		t.Fatalf("range: status=%d got=%q", code, part)
	}
	// Byte-identical replay (lost response): 200, one row, one file.
	code, raw = doJSON(t, srv, "POST", "/v2/rooms/r/blobs?device=b1", payload)
	if code != http.StatusOK || decodeBlob(t, raw).ID != id {
		t.Fatalf("replay: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_blobs`); n != 1 {
		t.Fatalf("replay added rows: %d", n)
	}
	if left, _ := os.ReadDir(filepath.Join(r.db.dir, blobDirName, blobTmpName)); len(left) != 0 {
		t.Fatalf("temp files left behind: %d", len(left))
	}
	// Unknown id in a known room: 404.
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/blobs/"+blobSum([]byte("nope"))+"?device=a1", nil); code != http.StatusNotFound || errField(t, raw) != "no_such_blob" {
		t.Fatalf("unknown id: status=%d body=%s", code, raw)
	}
}

func TestBlobMembershipRoomAndValidation(t *testing.T) {
	r, srv := seededBlobRoom(t, testPolicy())
	payload := []byte("sealed photo")
	id := blobSum(payload)
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/blobs?device=a1", payload); code != http.StatusCreated {
		t.Fatalf("upload: status=%d body=%s", code, raw)
	}
	// Active outsider: 403 on both routes, nothing stored.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/blobs?device=c1", []byte("other")); code != http.StatusForbidden || errField(t, raw) != "not_a_member" {
		t.Fatalf("outsider upload: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/blobs/"+id+"?device=c1", nil); code != http.StatusForbidden || errField(t, raw) != "not_a_member" {
		t.Fatalf("outsider download: status=%d body=%s", code, raw)
	}
	// Unknown (never enrolled) device: device_not_allowed.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/blobs?device=ghost", []byte("x")); code != http.StatusForbidden || errField(t, raw) != "device_not_allowed" {
		t.Fatalf("ghost upload: status=%d body=%s", code, raw)
	}
	// Blobs only for rooms that exist; no room row is created.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/nowhere/blobs?device=a1", []byte("x")); code != http.StatusNotFound || errField(t, raw) != "no_such_room" {
		t.Fatalf("unknown room upload: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/nowhere/blobs/"+id+"?device=a1", nil); code != http.StatusNotFound || errField(t, raw) != "no_such_room" {
		t.Fatalf("unknown room download: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_rooms WHERE room = 'nowhere'`); n != 0 {
		t.Fatalf("blob route created a room row")
	}
	bad := []struct {
		name, method, path string
		body               []byte
		code               string
	}{
		{"no device", "POST", "/v2/rooms/r/blobs", []byte("x"), "device_required"},
		{"bad device", "POST", "/v2/rooms/r/blobs?device=a.1", []byte("x"), "bad_identifier"},
		{"bad room", "POST", "/v2/rooms/r.x/blobs?device=a1", []byte("x"), "bad_identifier"},
		{"empty body", "POST", "/v2/rooms/r/blobs?device=a1", []byte{}, "empty_body"},
		{"get no device", "GET", "/v2/rooms/r/blobs/" + id, nil, "device_required"},
		{"short id", "GET", "/v2/rooms/r/blobs/abc?device=a1", nil, "bad_blob_id"},
		{"upper id", "GET", "/v2/rooms/r/blobs/" + strings.ToUpper(id) + "?device=a1", nil, "bad_blob_id"},
		{"traversal id", "GET", "/v2/rooms/r/blobs/..%2F..%2Fnative-mls-v2.db?device=a1", nil, "bad_blob_id"},
	}
	for _, b := range bad {
		if code, raw := doJSON(t, srv, b.method, b.path, b.body); code != http.StatusBadRequest || errField(t, raw) != b.code {
			t.Fatalf("%s: status=%d body=%s, want 400 %s", b.name, code, raw, b.code)
		}
	}
	// Closing the room: rows and files go, both routes answer 410.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/close?device=a1", nil); code != http.StatusOK {
		t.Fatalf("close: status=%d body=%s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_blobs WHERE room = 'r'`); n != 0 {
		t.Fatalf("closed room kept %d blob rows", n)
	}
	if _, err := os.Stat(filepath.Join(r.db.dir, blobDirName, "r", id)); !os.IsNotExist(err) {
		t.Fatalf("closed room kept its blob file: %v", err)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/blobs?device=a1", payload); code != http.StatusGone || errField(t, raw) != "room_closed" {
		t.Fatalf("upload to closed room: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "GET", "/v2/rooms/r/blobs/"+id+"?device=a1", nil); code != http.StatusGone || errField(t, raw) != "room_closed" {
		t.Fatalf("download from closed room: status=%d body=%s", code, raw)
	}
}

func TestBlobTooLarge(t *testing.T) {
	r, srv := seededBlobRoom(t, defaultPolicy())
	big := make([]byte, maxBlobBytes+1)
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/blobs?device=a1", big); code != http.StatusRequestEntityTooLarge || errField(t, raw) != "blob_too_large" {
		t.Fatalf("over the limit: status=%d body=%.200s", code, raw)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_blobs`); n != 0 {
		t.Fatalf("refused upload stored a row")
	}
	if left, _ := os.ReadDir(filepath.Join(r.db.dir, blobDirName, blobTmpName)); len(left) != 0 {
		t.Fatalf("refused upload left %d temp files", len(left))
	}
	// Exactly at the limit is accepted.
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/blobs?device=a1", big[:maxBlobBytes]); code != http.StatusCreated {
		t.Fatalf("at the limit: status=%d body=%.200s", code, raw)
	}
}

// Blob bytes and event bytes share RoomBytesCap / DeviceBytesCap.
func TestBlobCapsShareEventAccounting(t *testing.T) {
	pol := testPolicy()
	pol.RoomBytesCap = 1000
	r, srv := seededBlobRoom(t, pol)
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/blobs?device=a1", make([]byte, 1001)); code != http.StatusRequestEntityTooLarge || errField(t, raw) != "room_bytes_cap" {
		t.Fatalf("blob over the room cap: status=%d body=%s", code, raw)
	}
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/blobs?device=a1", bytes.Repeat([]byte{7}, 900)); code != http.StatusCreated {
		t.Fatalf("blob under the cap: status=%d body=%s", code, raw)
	}
	// 900 blob bytes + the bootstrap commit's bytes: a 200-byte application
	// event no longer fits.
	ev := postEventBody(t, "a1", "m1", "application", 1, nil, nil, make([]byte, 200))
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/events", ev); code != http.StatusRequestEntityTooLarge || errField(t, raw) != "room_bytes_cap" {
		t.Fatalf("event after a large blob: status=%d body=%s", code, raw)
	}

	pol2 := testPolicy()
	pol2.DeviceBytesCap = 500
	r2, srv2 := seededBlobRoom(t, pol2)
	if code, raw := doJSON(t, srv2, "POST", "/v2/rooms/r/blobs?device=b1", make([]byte, 501)); code != http.StatusRequestEntityTooLarge || errField(t, raw) != "device_bytes_cap" {
		t.Fatalf("blob over the device cap: status=%d body=%s", code, raw)
	}
	_ = r
	_ = r2
}

func TestBlobRetentionAndSweep(t *testing.T) {
	r, srv := seededBlobRoom(t, testPolicy())
	old, fresh := []byte("old photo"), []byte("fresh photo")
	for _, b := range [][]byte{old, fresh} {
		if code, raw := doJSON(t, srv, "POST", "/v2/rooms/r/blobs?device=a1", b); code != http.StatusCreated {
			t.Fatalf("upload: status=%d body=%s", code, raw)
		}
	}
	ttl := r.policy.AppEventTTLSeconds
	now := time.Now().Unix()
	prune := func() {
		t.Helper()
		tx, err := r.db.Begin()
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback()
		if err := r.prune(tx, "r", 1, now, nil); err != nil {
			t.Fatal(err)
		}
		if err := tx.Commit(); err != nil {
			t.Fatal(err)
		}
	}
	// Past the TTL but a reader has not acked past the upload point: kept.
	if _, err := r.db.Exec(`UPDATE mls_blobs SET created_at = ?, after_seq = 5 WHERE id = ?`, now-ttl-60, blobSum(old)); err != nil {
		t.Fatal(err)
	}
	if _, err := r.db.Exec(`UPDATE mls_cursors SET seq = 5 WHERE room = 'r'`); err != nil {
		t.Fatal(err)
	}
	prune()
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_blobs`); n != 2 {
		t.Fatalf("blob pruned before every reader passed it: %d rows", n)
	}
	// Every reader past the upload point: the expired row goes, the fresh stays.
	if _, err := r.db.Exec(`UPDATE mls_cursors SET seq = 6 WHERE room = 'r'`); err != nil {
		t.Fatal(err)
	}
	prune()
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_blobs WHERE id = ?`, blobSum(old)); n != 0 {
		t.Fatalf("expired blob kept")
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_blobs WHERE id = ?`, blobSum(fresh)); n != 1 {
		t.Fatalf("fresh blob pruned")
	}
	// The sweep removes the orphaned file, a stale temp file and a stray file;
	// the fresh blob and a young temp file stay.
	root := filepath.Join(r.db.dir, blobDirName)
	stray := filepath.Join(root, "r", blobSum([]byte("never recorded")))
	staleTmp, youngTmp := filepath.Join(root, blobTmpName, "up-stale"), filepath.Join(root, blobTmpName, "up-young")
	for _, p := range []string{stray, staleTmp, youngTmp} {
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	past := time.Now().Add(-2 * blobTmpMaxAge)
	if err := os.Chtimes(staleTmp, past, past); err != nil {
		t.Fatal(err)
	}
	n, err := r.sweepBlobs(time.Now())
	if err != nil || n != 3 {
		t.Fatalf("sweep removed %d (err %v), want 3 (old blob, stray, stale temp)", n, err)
	}
	for _, p := range []string{filepath.Join(root, "r", blobSum(old)), stray, staleTmp} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("%s survived the sweep", filepath.Base(p))
		}
	}
	for _, p := range []string{filepath.Join(root, "r", blobSum(fresh)), youngTmp} {
		if _, err := os.Stat(p); err != nil {
			t.Fatalf("%s removed by the sweep: %v", filepath.Base(p), err)
		}
	}
	// 2×TTL backstop: a reader that never acks does not pin a blob forever.
	if _, err := r.db.Exec(`UPDATE mls_blobs SET created_at = ? WHERE id = ?`, now-2*ttl-60, blobSum(fresh)); err != nil {
		t.Fatal(err)
	}
	if _, err := r.db.Exec(`UPDATE mls_cursors SET seq = 0 WHERE room = 'r'`); err != nil {
		t.Fatal(err)
	}
	if n, err := r.sweepBlobs(time.Now()); err != nil || n != 1 {
		t.Fatalf("backstop sweep removed %d (err %v), want 1", n, err)
	}
	if c := tableCount(t, r, `SELECT COUNT(*) FROM mls_blobs`); c != 0 {
		t.Fatalf("backstop left %d rows", c)
	}
}

func TestBlobSubjectBinding(t *testing.T) {
	r, srv, st, first, iss := newAuthedRelay(t, testPolicy())
	enrollDevice(t, st, first, "a1", "alice")
	enrollDevice(t, st, first, "b1", "bob")
	alice := iss.mint("subject-alice", nil)
	id := blobSum([]byte("x"))
	for _, m := range []struct{ method, path string }{
		{"POST", "/v2/rooms/r/blobs?device=b1"},
		{"GET", "/v2/rooms/r/blobs/" + id + "?device=b1"},
		{"POST", "/v2/rooms/r/blobs?device=ghost"},
	} {
		var body []byte
		if m.method == "POST" {
			body = []byte("x")
		}
		if code, raw := doAuth(t, srv, m.method, m.path, body, alice); code != http.StatusForbidden || errField(t, raw) != "device_subject_mismatch" {
			t.Fatalf("%s %s with alice: status=%d body=%s", m.method, m.path, code, raw)
		}
	}
	// No token at all: 401.
	if code, _ := doJSON(t, srv, "POST", "/v2/rooms/r/blobs?device=a1", []byte("x")); code != http.StatusUnauthorized {
		t.Fatalf("anonymous upload: status=%d", code)
	}
	if n := tableCount(t, r, `SELECT COUNT(*) FROM mls_blobs`); n != 0 {
		t.Fatalf("refused uploads stored rows")
	}
}

func TestBlobResetRoomRemovesRowsAndFiles(t *testing.T) {
	dir := t.TempDir()
	r, srv, _ := newTestRelayAt(t, testPolicy(), dir)
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/gone/events", postEventBody(t, "a1", "c1", "application", 0, nil, nil, []byte("m"))); code != http.StatusCreated {
		t.Fatalf("seed: status=%d body=%s", code, raw)
	}
	payload := []byte("blob in a reset room")
	if code, raw := doJSON(t, srv, "POST", "/v2/rooms/gone/blobs?device=a1", payload); code != http.StatusCreated {
		t.Fatalf("upload (enforcement off): status=%d body=%s", code, raw)
	}
	srv.Close()
	if err := r.db.Close(); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if code := runResetRoom(&out, dir, "gone", false); code != 2 || !strings.Contains(out.String(), "blobs=1") {
		t.Fatalf("dry run: exit=%d out=%q", code, out.String())
	}
	if code := runResetRoom(&out, dir, "gone", true); code != 0 {
		t.Fatalf("reset: exit=%d out=%q", code, out.String())
	}
	if _, err := os.Stat(filepath.Join(dir, blobDirName, "gone")); !os.IsNotExist(err) {
		t.Fatalf("reset kept the room's blob directory: %v", err)
	}
}
