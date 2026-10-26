// Room-scoped blob store (#499 stage 1, "file-v2" detached attachments).
//
// Until now an attachment travelled as the raw file bytes inside one MLS
// application message (#364, ≤ 5 MiB), so every layer — relay events, every
// device's sync, the browser worker's ledger, the iOS NSE — carried the whole
// photo (#371, #495, #496). file-v2 moves the bytes out of the MLS path, the
// way Matrix does ("Sending encrypted attachments"): the sender encrypts the
// file client-side under a fresh per-file key (AES-256-GCM), uploads only the
// ciphertext here, and sends a small MLS application message (client_id
// `file-v2-<uuid>`, stage 2) carrying the blob id, key, nonce and sha256.
//
//	POST /v2/rooms/{room}/blobs?device=D        body = raw ciphertext bytes
//	GET  /v2/rooms/{room}/blobs/{id}?device=D   → the same bytes
//
// The relay never sees a key: a blob alone is opaque ciphertext, and it learns
// only what it already learns from events (size, time, poster). id is the
// lowercase hex sha256 of the received bytes (content address), so a replayed
// upload is idempotent (200) and clients verify what they download against
// the hash they carried in the MLS message.
//
// Hardening parity with the event routes: CF Access caller auth, the device
// named by ?device= bound to the JWT subject before any body is read, the
// identifier rule, the same membership gate as an application event
// (authorizeEvent: policy-active, and a tracked member once the room is
// seeded), re-checked inside the single-writer transaction. Blobs exist only
// for rooms that already exist (404) and are refused on closed rooms (410).
// Blob bytes count against the same RoomBytesCap / DeviceBytesCap as event
// bytes, are never logged, and live on disk under <data-dir>/blobs/<room>/<id>
// with metadata in mls_blobs.
//
// Retention: a blob row goes once it is older than AppEventTTLSeconds AND
// every known reader of the room has acked past the room's last seq at upload
// time (after_seq) — the referencing file-v2 message can only come after the
// upload — or unconditionally at twice the TTL (a reader that never acks must
// not pin blobs forever). Rows are deleted inside the write transactions
// (prune, close); files are removed by sweepBlobsLocked, which deletes every
// file without a row (so a rolled-back transaction never leaves a row pointing
// at a deleted file) plus stale upload temp files. It runs after a close, on
// a timer from main, and at startup.
package main

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"time"
)

const (
	// maxBlobBytes: 50 MiB of file (owner decision on #499) plus 64 KiB for the
	// client's AEAD framing. Its own limit — maxBodyBytes stays the JSON bound.
	maxBlobBytes = 50<<20 + 64<<10
	blobDirName  = "blobs"
	blobTmpName  = ".tmp" // a dot cannot appear in a room identifier
	// blobTransferTimeout replaces the server-wide Read/WriteTimeout for the
	// two blob routes only: 50 MiB over a phone link can take minutes.
	blobTransferTimeout = 10 * time.Minute
	// blobTmpMaxAge: the sweeper removes upload temp files older than this
	// (an upload in flight is bounded by blobTransferTimeout).
	blobTmpMaxAge = time.Hour
	// BlobSweepInterval is how often main runs the orphan/expiry sweep.
	blobSweepInterval = 10 * time.Minute
)

var blobIDPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

var errNoBlob = errors.New("no such blob")

// blobResponse is the POST answer (201 new, 200 already stored).
type blobResponse struct {
	ID   string `json:"id"`
	Size int64  `json:"size"`
}

// prepareBlobDir creates <data-dir>/blobs/.tmp (0700) and empties tmp: at
// startup no upload can be in flight, so anything there is a crash leftover.
func prepareBlobDir(dataDir string) error {
	root := filepath.Join(dataDir, blobDirName)
	tmp := filepath.Join(root, blobTmpName)
	if err := os.MkdirAll(tmp, 0o700); err != nil {
		return err
	}
	for _, dir := range []string{root, tmp} {
		if err := os.Chmod(dir, 0o700); err != nil {
			return err
		}
	}
	entries, err := os.ReadDir(tmp)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if err := os.RemoveAll(filepath.Join(tmp, e.Name())); err != nil {
			return err
		}
	}
	return nil
}

func (s *relay) blobRoot() string { return filepath.Join(s.db.dir, blobDirName) }

// blobPath is <data-dir>/blobs/<room>/<id>. Both parts are re-validated here
// (room by the identifier rule, id as 64 lowercase hex) so no caller can turn
// either into a path traversal or reach the .tmp directory.
func (s *relay) blobPath(room, id string) (string, error) {
	if !validIdentifier(room) || !blobIDPattern.MatchString(id) {
		return "", errors.New("invalid blob path")
	}
	return filepath.Join(s.blobRoot(), room, id), nil
}

// roomStoredBytes and deviceStoredBytes are the B5 / G-M4 cap measures: event
// bytes plus blob bytes, so a blob cannot sidestep the bounds events obey.
func roomStoredBytes(tx *sql.Tx, room string) (int64, error) {
	var events, blobs sql.NullInt64
	if err := tx.QueryRow(`SELECT SUM(LENGTH(bytes)) FROM mls_events WHERE room = ?`, room).Scan(&events); err != nil {
		return 0, err
	}
	if err := tx.QueryRow(`SELECT SUM(size) FROM mls_blobs WHERE room = ?`, room).Scan(&blobs); err != nil {
		return 0, err
	}
	return events.Int64 + blobs.Int64, nil
}

func deviceStoredBytes(tx *sql.Tx, device string) (int64, error) {
	var events, blobs sql.NullInt64
	if err := tx.QueryRow(`SELECT SUM(LENGTH(bytes)) FROM mls_events WHERE device = ?`, device).Scan(&events); err != nil {
		return 0, err
	}
	if err := tx.QueryRow(`SELECT SUM(size) FROM mls_blobs WHERE device = ?`, device).Scan(&blobs); err != nil {
		return 0, err
	}
	return events.Int64 + blobs.Int64, nil
}

// blobAccess is the shared gate of both routes, inside a transaction: the
// application-event membership rule, then the room must exist and be open.
func (s *relay) blobAccess(tx *sql.Tx, room, device string) (roomRow, error) {
	if _, _, err := s.authorizeEvent(tx, room, eventInput{device: device, kind: "application"}); err != nil {
		return roomRow{}, err
	}
	row, err := readRoom(tx, room)
	if errors.Is(err, sql.ErrNoRows) {
		return roomRow{}, errNoRoom
	}
	if err != nil {
		return roomRow{}, err
	}
	if row.closed {
		return roomRow{}, errClosed
	}
	return row, nil
}

// checkBlobAccess runs the gate read-only before an upload body is read, so
// a refused caller does not get to stream 50 MiB first. storeBlob re-checks.
func (s *relay) checkBlobAccess(room, device string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, err = s.blobAccess(tx, room, device)
	return err
}

// receiveBlob streams the body into a temp file under blobs/.tmp while hashing
// it. The caller removes the temp file unless storeBlob renamed it.
func (s *relay) receiveBlob(w http.ResponseWriter, req *http.Request) (tmp, id string, size int64, err error) {
	f, err := os.CreateTemp(filepath.Join(s.blobRoot(), blobTmpName), "up-*")
	if err != nil {
		return "", "", 0, err
	}
	tmp = f.Name()
	h := sha256.New()
	size, err = io.Copy(io.MultiWriter(f, h), http.MaxBytesReader(w, req.Body, maxBlobBytes))
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(tmp)
		return "", "", 0, err
	}
	return tmp, hex.EncodeToString(h.Sum(nil)), size, nil
}

// storeBlob records an uploaded temp file as (room, id) in one BEGIN
// IMMEDIATE transaction: gate, prune, caps, then insert + rename. created is
// false for an already stored id (the temp file is then left to the caller).
func (s *relay) storeBlob(room, device, id string, size int64, tmp string) (created bool, err error) {
	now := time.Now().Unix()
	final, err := s.blobPath(room, id)
	if err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	row, err := s.blobAccess(tx, room, device)
	if err != nil {
		return false, err
	}
	var stored int64
	err = tx.QueryRow(`SELECT size FROM mls_blobs WHERE room = ? AND id = ?`, room, id).Scan(&stored)
	if err == nil {
		// Content-addressed: same id = same bytes. Restore the file if it is
		// somehow missing (the row is the authority), otherwise a no-op.
		if _, statErr := os.Stat(final); errors.Is(statErr, fs.ErrNotExist) {
			if err := placeBlob(tmp, final); err != nil {
				return false, err
			}
		}
		return false, tx.Commit()
	} else if !errors.Is(err, sql.ErrNoRows) {
		return false, err
	}
	active, err := s.enforceDevicePolicy()
	if err != nil {
		return false, err
	}
	// H2 parity: reclaim retention-expired rows before measuring the caps.
	if err := s.prune(tx, room, row.epoch, now, active); err != nil {
		return false, err
	}
	used, err := roomStoredBytes(tx, room)
	if err != nil {
		return false, err
	}
	if s.policy.RoomBytesCap > 0 && used+size > s.policy.RoomBytesCap {
		return false, roomBytesCap{used, s.policy.RoomBytesCap}
	}
	usedDevice, err := deviceStoredBytes(tx, device)
	if err != nil {
		return false, err
	}
	if s.policy.DeviceBytesCap > 0 && usedDevice+size > s.policy.DeviceBytesCap {
		return false, deviceBytesCap{usedDevice, s.policy.DeviceBytesCap}
	}
	if _, err := tx.Exec(`INSERT INTO mls_blobs (room, id, device, size, after_seq, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		room, id, device, size, row.lastSeq, now); err != nil {
		return false, err
	}
	if err := placeBlob(tmp, final); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		os.Remove(final)
		return false, err
	}
	return true, nil
}

// placeBlob renames the synced temp file into blobs/<room>/<id> and syncs the
// directory so the rename survives a crash.
func placeBlob(tmp, final string) error {
	dir := filepath.Dir(final)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if err := os.Rename(tmp, final); err != nil {
		return err
	}
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		d.Close()
	}
	return nil
}

// openBlob runs the gate and opens the file under the relay mutex, so the
// sweeper cannot unlink it between the row check and the open; the open file
// stays readable after the mutex is released.
func (s *relay) openBlob(room, device, id string) (*os.File, int64, error) {
	path, err := s.blobPath(room, id)
	if err != nil {
		return nil, 0, errNoBlob
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return nil, 0, err
	}
	defer tx.Rollback()
	if _, err := s.blobAccess(tx, room, device); err != nil {
		return nil, 0, err
	}
	var size int64
	if err := tx.QueryRow(`SELECT size FROM mls_blobs WHERE room = ? AND id = ?`, room, id).Scan(&size); errors.Is(err, sql.ErrNoRows) {
		return nil, 0, errNoBlob
	} else if err != nil {
		return nil, 0, err
	}
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		log.Printf("blob room=%s id=%s: row without file", room, id)
		return nil, 0, errNoBlob
	}
	if err != nil {
		return nil, 0, err
	}
	if err := tx.Commit(); err != nil {
		f.Close()
		return nil, 0, err
	}
	return f, size, nil
}

// pruneBlobs deletes expired blob rows of one room (called from prune, inside
// its transaction). Files follow in sweepBlobsLocked.
func (s *relay) pruneBlobs(tx *sql.Tx, room string, now int64, minCursor sql.NullInt64) error {
	ttl := s.policy.AppEventTTLSeconds
	if ttl <= 0 {
		return nil
	}
	if minCursor.Valid {
		_, err := tx.Exec(`DELETE FROM mls_blobs WHERE room = ? AND created_at < ? AND (after_seq < ? OR created_at < ?)`,
			room, now-ttl, minCursor.Int64, now-2*ttl)
		return err
	}
	_, err := tx.Exec(`DELETE FROM mls_blobs WHERE room = ? AND created_at < ?`, room, now-2*ttl)
	return err
}

// sweepBlobs takes the relay mutex and runs sweepBlobsLocked.
func (s *relay) sweepBlobs(now time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.sweepBlobsLocked(now)
}

// sweepBlobsLocked (s.mu held) applies the 2×TTL backstop to every room —
// rooms with no traffic never run prune — then removes every blob file that
// has no row, empty room directories, and upload temp files older than
// blobTmpMaxAge. Returns the number of files removed.
func (s *relay) sweepBlobsLocked(now time.Time) (int, error) {
	if ttl := s.policy.AppEventTTLSeconds; ttl > 0 {
		if _, err := s.db.Exec(`DELETE FROM mls_blobs WHERE created_at < ?`, now.Unix()-2*ttl); err != nil {
			return 0, err
		}
	}
	root := s.blobRoot()
	rooms, err := os.ReadDir(root)
	if errors.Is(err, fs.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	removed := 0
	for _, r := range rooms {
		dir := filepath.Join(root, r.Name())
		if r.Name() == blobTmpName {
			files, err := os.ReadDir(dir)
			if err != nil {
				return removed, err
			}
			for _, f := range files {
				info, err := f.Info()
				if err == nil && now.Sub(info.ModTime()) > blobTmpMaxAge {
					if os.Remove(filepath.Join(dir, f.Name())) == nil {
						removed++
					}
				}
			}
			continue
		}
		if !r.IsDir() {
			continue
		}
		files, err := os.ReadDir(dir)
		if err != nil {
			return removed, err
		}
		left := len(files)
		for _, f := range files {
			var n int
			err := s.db.QueryRow(`SELECT COUNT(*) FROM mls_blobs WHERE room = ? AND id = ?`, r.Name(), f.Name()).Scan(&n)
			if err != nil {
				return removed, err
			}
			if n == 0 {
				if os.Remove(filepath.Join(dir, f.Name())) == nil {
					removed++
					left--
				}
			}
		}
		if left == 0 {
			_ = os.Remove(dir)
		}
	}
	return removed, nil
}

// runBlobSweeper sweeps every blobSweepInterval (started by main).
func (s *relay) runBlobSweeper() {
	for {
		if n, err := s.sweepBlobs(time.Now()); err != nil {
			log.Printf("blob sweep: %v", err)
		} else if n > 0 {
			log.Printf("blob sweep: removed %d file(s)", n)
		}
		time.Sleep(blobSweepInterval)
	}
}

// extendTransferDeadlines lifts the server-wide Read/WriteTimeout for one
// blob transfer (best effort: httptest and HTTP/2 may not support it).
func extendTransferDeadlines(w http.ResponseWriter) {
	rc := http.NewResponseController(w)
	deadline := time.Now().Add(blobTransferTimeout)
	_ = rc.SetReadDeadline(deadline)
	_ = rc.SetWriteDeadline(deadline)
}

// blobDevice reads and validates ?device= (400 on a missing or bad value).
func (s *relay) blobDevice(w http.ResponseWriter, req *http.Request) (string, bool) {
	device := req.URL.Query().Get("device")
	if device == "" {
		s.fail(w, http.StatusBadRequest, apiError{Error: "device_required"})
		return "", false
	}
	if !validIdentifier(device) {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "device"})
		return "", false
	}
	return device, true
}

// failBlob maps the gate/store errors of both routes to their statuses (the
// same codes the event routes use).
func (s *relay) failBlob(w http.ResponseWriter, op, room string, err error) {
	switch {
	case errors.Is(err, errNoRoom):
		s.fail(w, http.StatusNotFound, apiError{Error: "no_such_room"})
	case errors.Is(err, errNoBlob):
		s.fail(w, http.StatusNotFound, apiError{Error: "no_such_blob"})
	case errors.Is(err, errClosed):
		s.fail(w, http.StatusGone, apiError{Error: "room_closed"})
	case errors.Is(err, errNotMember):
		s.fail(w, http.StatusForbidden, apiError{Error: "not_a_member"})
	case errors.As(err, new(deviceNotAllowed)):
		var na deviceNotAllowed
		errors.As(err, &na)
		s.fail(w, http.StatusForbidden, apiError{Error: "device_not_allowed", Detail: na.Error()})
	case errors.As(err, new(policyUnavailable)):
		log.Printf("%s room=%s: %v", op, room, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "device_policy_unavailable", Detail: "device policy chain unreadable; writes fail closed"})
	case errors.As(err, new(roomBytesCap)):
		var cap roomBytesCap
		errors.As(err, &cap)
		s.fail(w, http.StatusRequestEntityTooLarge, apiError{Error: "room_bytes_cap", Used: cap.Used, Cap: cap.Cap})
	case errors.As(err, new(deviceBytesCap)):
		var cap deviceBytesCap
		errors.As(err, &cap)
		s.fail(w, http.StatusRequestEntityTooLarge, apiError{Error: "device_bytes_cap", Used: cap.Used, Cap: cap.Cap})
	default:
		log.Printf("%s room=%s: %v", op, room, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
	}
}

// handlePostBlob: POST /v2/rooms/{room}/blobs?device=D, body = ciphertext.
func (s *relay) handlePostBlob(w http.ResponseWriter, req *http.Request) {
	room, ok := s.roomParam(w, req)
	if !ok {
		return
	}
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	device, ok := s.blobDevice(w, req)
	if !ok {
		return
	}
	if !s.bindDevice(w, c, device) {
		return
	}
	if err := s.checkBlobAccess(room, device); err != nil {
		s.failBlob(w, "post blob", room, err)
		return
	}
	extendTransferDeadlines(w)
	tmp, id, size, err := s.receiveBlob(w, req)
	if err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			s.fail(w, http.StatusRequestEntityTooLarge, apiError{Error: "blob_too_large", Max: maxBlobBytes})
			return
		}
		log.Printf("post blob room=%s: receive: %v", room, err)
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_request"})
		return
	}
	defer os.Remove(tmp) // no-op once renamed into place
	if size == 0 {
		s.fail(w, http.StatusBadRequest, apiError{Error: "empty_body"})
		return
	}
	created, err := s.storeBlob(room, device, id, size, tmp)
	if err != nil {
		s.failBlob(w, "post blob", room, err)
		return
	}
	status := http.StatusCreated
	if !created {
		status = http.StatusOK
	}
	writeJSON(w, status, blobResponse{ID: id, Size: size})
}

// handleGetBlob: GET /v2/rooms/{room}/blobs/{id}?device=D.
func (s *relay) handleGetBlob(w http.ResponseWriter, req *http.Request) {
	room, ok := s.roomParam(w, req)
	if !ok {
		return
	}
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	device, ok := s.blobDevice(w, req)
	if !ok {
		return
	}
	id := req.PathValue("id")
	if !blobIDPattern.MatchString(id) {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_blob_id"})
		return
	}
	if !s.bindDevice(w, c, device) {
		return
	}
	f, size, err := s.openBlob(room, device, id)
	if err != nil {
		s.failBlob(w, "get blob", room, err)
		return
	}
	defer f.Close()
	if info, err := f.Stat(); err != nil || info.Size() != size {
		log.Printf("get blob room=%s id=%s: file size does not match its row", room, id)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
		return
	}
	extendTransferDeadlines(w)
	h := w.Header()
	h.Set("Content-Type", "application/octet-stream")
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	// ServeContent sets Content-Length and answers Range requests (resumable
	// downloads on a phone link); a zero modtime sends no Last-Modified.
	http.ServeContent(w, req, "", time.Time{}, f)
}
