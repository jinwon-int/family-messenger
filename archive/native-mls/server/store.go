// native-mls v2 relay (#177 §3.4). Four routes, three tables plus room
// closure, one SQLite file owned by the native track. The operational
// server/ schema 12 is untouched: this module never imports it and uses its
// own database file. CAS reads, count checks and inserts share one
// BEGIN IMMEDIATE transaction (B2/B3).
package main

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// sqliteURI mirrors server/internal/chat/sqlite.go sqliteURI() so the native
// track gets the same durability posture without importing the live module.
func sqliteURI(path string) string {
	return "file:" + filepath.ToSlash(path) +
		"?_journal_mode=DELETE&_synchronous=FULL&_foreign_keys=on&_busy_timeout=5000&_secure_delete=on"
}

const schema = `
CREATE TABLE IF NOT EXISTS mls_rooms (
	room       TEXT PRIMARY KEY,
	group_id   TEXT NOT NULL,
	epoch      INTEGER NOT NULL DEFAULT 0,
	revision   INTEGER NOT NULL DEFAULT 0,
	created_at INTEGER NOT NULL,
	closed_at  INTEGER
);
CREATE TABLE IF NOT EXISTS mls_events (
	room       TEXT NOT NULL REFERENCES mls_rooms(room),
	seq        INTEGER NOT NULL,
	device     TEXT NOT NULL,
	client_id  TEXT NOT NULL,
	kind       TEXT NOT NULL CHECK (kind IN ('commit','welcome','application')),
	epoch      INTEGER NOT NULL,
	targets    TEXT,
	bytes      BLOB NOT NULL,
	sha256     TEXT NOT NULL,
	created_at INTEGER NOT NULL,
	UNIQUE (room, device, client_id),
	PRIMARY KEY (room, seq)
);
CREATE TABLE IF NOT EXISTS mls_keypackages (
	room        TEXT NOT NULL REFERENCES mls_rooms(room),
	device      TEXT NOT NULL,
	ref         TEXT NOT NULL,
	bytes       BLOB NOT NULL,
	consumed_by TEXT,
	expires_at  INTEGER NOT NULL,
	PRIMARY KEY (room, device, ref)
);
CREATE TABLE IF NOT EXISTS mls_cursors (
	room   TEXT NOT NULL REFERENCES mls_rooms(room),
	device TEXT NOT NULL,
	seq    INTEGER NOT NULL,
	PRIMARY KEY (room, device)
);
`

func openStore(dataDir string) (*sql.DB, error) {
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite3", sqliteURI(filepath.Join(dataDir, "native-mls-v2.db")))
	if err != nil {
		return nil, err
	}
	// One writer connection: BEGIN IMMEDIATE plus busy_timeout then never
	// races itself.
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

var errClosed = errors.New("room closed")

// eventInput is the validated store-side form of one POST /events body.
// revision is a pointer so an absent CAS field and epoch=0 stay distinct.
type eventInput struct {
	groupID  string
	device   string
	clientID string
	kind     string
	epoch    int64
	revision *int64
	targets  []string
	bytes    []byte
}

// storedEvent is storeEvent's result; duplicate marks a byte-equal replay of
// an existing (room, device, client_id) row (K4 -> HTTP 200 instead of 201).
type storedEvent struct {
	seq       int64
	epoch     int64
	revision  int64
	duplicate bool
}

type roomRow struct {
	groupID  string
	epoch    int64
	revision int64
	closed   bool
}

// ensureRoom lazily creates the room row inside the caller's transaction.
func ensureRoom(tx *sql.Tx, room, groupID string, now int64) (roomRow, error) {
	if groupID == "" {
		groupID = room
	}
	_, err := tx.Exec(`INSERT INTO mls_rooms (room, group_id, epoch, revision, created_at)
		VALUES (?, ?, 0, 0, ?) ON CONFLICT (room) DO NOTHING`, room, groupID, now)
	if err != nil {
		return roomRow{}, err
	}
	return readRoom(tx, room)
}

func readRoom(q interface{ QueryRow(string, ...any) *sql.Row }, room string) (roomRow, error) {
	row := roomRow{}
	var closed sql.NullInt64
	err := q.QueryRow(`SELECT group_id, epoch, revision, closed_at FROM mls_rooms WHERE room = ?`, room).
		Scan(&row.groupID, &row.epoch, &row.revision, &closed)
	if errors.Is(err, sql.ErrNoRows) {
		return roomRow{}, err
	}
	if err != nil {
		return roomRow{}, err
	}
	row.closed = closed.Valid
	return row, nil
}

// closeRoom tombstones a room (B1): all four routes then answer 410 until an
// operator deletes the file. Expired key packages are swept in the same write.
func closeRoom(db *sql.DB, room string, now int64) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`UPDATE mls_rooms SET closed_at = ? WHERE room = ? AND closed_at IS NULL`, now, room); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM mls_keypackages WHERE expires_at <= ?`, now); err != nil {
		return err
	}
	return tx.Commit()
}

// closeRoomDB serializes the §3.4 deletion path (B1) with every other
// writer: the relay mutex is held so a closure cannot interleave with a
// CAS/count+insert transaction, then closeRoom does the SQLite work.
func (s *relay) closeRoomDB(room string, now int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return closeRoom(s.db, room, now)
}

// storeEvent appends one event under CAS discipline. Body validation happened
// in the handler; everything below (room read, CAS, idempotency, seq
// allocation, byte cap, insert, pruning) is one BEGIN IMMEDIATE transaction.
func (s *relay) storeEvent(room string, ev eventInput) (storedEvent, error) {
	now := time.Now().Unix()
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return storedEvent{}, err
	}
	defer tx.Rollback()

	row, err := ensureRoom(tx, room, ev.groupID, now)
	if err != nil {
		return storedEvent{}, err
	}
	if row.closed {
		return storedEvent{}, errClosed
	}
	// K4 before CAS: a byte-equal replay of a stored event is the 200 duplicate
	// even if a commit has since moved the epoch (lost response + concurrent
	// commit); different bytes under a taken client_id are reuse regardless.
	var prevSeq int64
	var prevEpoch int64
	var prevBytes []byte
	err = tx.QueryRow(`SELECT seq, epoch, bytes FROM mls_events WHERE room = ? AND device = ? AND client_id = ?`,
		room, ev.device, ev.clientID).Scan(&prevSeq, &prevEpoch, &prevBytes)
	if err == nil {
		if string(prevBytes) == string(ev.bytes) {
			return storedEvent{seq: prevSeq, epoch: prevEpoch, revision: row.revision, duplicate: true}, nil
		}
		return storedEvent{}, clientIDReuse{Device: ev.device, ClientID: ev.clientID}
	} else if !errors.Is(err, sql.ErrNoRows) {
		return storedEvent{}, err
	}
	if ev.revision != nil && *ev.revision != row.revision {
		return storedEvent{}, casMismatch{row.epoch, row.revision}
	}
	if ev.epoch != row.epoch {
		return storedEvent{}, casMismatch{row.epoch, row.revision}
	}
	if ev.kind == "welcome" && len(ev.targets) == 0 {
		return storedEvent{}, errWelcomeTargets
	}
	// B5: cap the room by event bytes, not by count.
	var used sql.NullInt64
	if err := tx.QueryRow(`SELECT SUM(LENGTH(bytes)) FROM mls_events WHERE room = ?`, room).Scan(&used); err != nil {
		return storedEvent{}, err
	}
	if s.policy.RoomBytesCap > 0 && used.Int64+int64(len(ev.bytes)) > s.policy.RoomBytesCap {
		return storedEvent{}, roomBytesCap{used.Int64, s.policy.RoomBytesCap}
	}
	var seq int64
	if err := tx.QueryRow(`SELECT COALESCE(MAX(seq), 0) + 1 FROM mls_events WHERE room = ?`, room).Scan(&seq); err != nil {
		return storedEvent{}, err
	}
	var targets sql.NullString
	if len(ev.targets) > 0 {
		targets = sql.NullString{String: encodeTargets(ev.targets), Valid: true}
	}
	if _, err := tx.Exec(`INSERT INTO mls_events (room, seq, device, client_id, kind, epoch, targets, bytes, sha256, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		room, seq, ev.device, ev.clientID, ev.kind, ev.epoch, targets, ev.bytes, sha256Hex(ev.bytes), now); err != nil {
		return storedEvent{}, err
	}
	// Every device that posts, and every Welcome target, becomes a known
	// reader of the room: its durable cursor gates application-event pruning
	// until it reads (poster from 0, a Welcome target from just before its
	// Welcome — it cannot decrypt anything earlier).
	if err := registerCursor(tx, room, ev.device, 0); err != nil {
		return storedEvent{}, err
	}
	if ev.kind == "welcome" {
		for _, target := range ev.targets {
			if err := registerCursor(tx, room, target, seq-1); err != nil {
				return storedEvent{}, err
			}
		}
	}
	newEpoch, newRevision := row.epoch, row.revision+1
	if ev.kind == "commit" {
		newEpoch = row.epoch + 1
	}
	if _, err := tx.Exec(`UPDATE mls_rooms SET epoch = ?, revision = ? WHERE room = ?`, newEpoch, newRevision, room); err != nil {
		return storedEvent{}, err
	}
	if err := s.prune(tx, room, newEpoch, now); err != nil {
		return storedEvent{}, err
	}
	if err := tx.Commit(); err != nil {
		return storedEvent{}, err
	}
	return storedEvent{seq: seq, epoch: newEpoch, revision: newRevision}, nil
}

// readEvents returns the per-room total order after seq, filtering welcome
// events targeted at other devices (B4: filter, never 403). The requesting
// device's cursor is recorded durably (mls_cursors) for application-event pruning.
func (s *relay) readEvents(room, device string, after int64) ([]storedRow, roomRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	row, err := readRoom(s.db, room)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, roomRow{}, errNoRoom
	}
	if err != nil {
		return nil, roomRow{}, err
	}
	if row.closed {
		return nil, roomRow{}, errClosed
	}
	rows, err := s.db.Query(`SELECT seq, device, client_id, kind, epoch, targets, bytes, sha256, created_at
		FROM mls_events WHERE room = ? AND seq > ? ORDER BY seq`, room, after)
	if err != nil {
		return nil, roomRow{}, err
	}
	defer rows.Close()
	out := []storedRow{}
	maxSeq := after
	for rows.Next() {
		var r storedRow
		var targets sql.NullString
		if err := rows.Scan(&r.Seq, &r.Device, &r.ClientID, &r.Kind, &r.Epoch, &targets, &r.Bytes, &r.Sha256, &r.CreatedAt); err != nil {
			return nil, roomRow{}, err
		}
		if r.Kind == "welcome" && !targetedAt(targets.String, device) {
			continue
		}
		if r.Seq > maxSeq {
			maxSeq = r.Seq
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, roomRow{}, err
	}
	rows.Close()
	// Durable cursor bookkeeping for pruning: only ever moves forward.
	if _, err := s.db.Exec(`INSERT INTO mls_cursors (room, device, seq) VALUES (?, ?, ?)
		ON CONFLICT (room, device) DO UPDATE SET seq = MAX(seq, excluded.seq)`, room, device, maxSeq); err != nil {
		return nil, roomRow{}, err
	}
	return out, row, nil
}

// postKeyPackages stores key packages with a shared TTL and a per-device live
// cap, sweeping expired rows in the same transaction.
func (s *relay) postKeyPackages(room, device string, pkgs []keyPackageInput) (int, error) {
	now := time.Now().Unix()
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	if _, err := ensureRoom(tx, room, "", now); err != nil {
		return 0, err
	}
	row, err := readRoom(tx, room)
	if err != nil {
		return 0, err
	}
	if row.closed {
		return 0, errClosed
	}
	if _, err := tx.Exec(`DELETE FROM mls_keypackages WHERE expires_at <= ?`, now); err != nil {
		return 0, err
	}
	var live int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM mls_keypackages WHERE room = ? AND device = ? AND consumed_by IS NULL AND expires_at > ?`,
		room, device, now).Scan(&live); err != nil {
		return 0, err
	}
	if live+len(pkgs) > s.policy.KeyPackagesMaxPerDevice {
		return 0, keyPackageLimit{live, s.policy.KeyPackagesMaxPerDevice}
	}
	for _, pkg := range pkgs {
		if _, err := tx.Exec(`INSERT INTO mls_keypackages (room, device, ref, bytes, expires_at) VALUES (?, ?, ?, ?, ?)`,
			room, device, pkg.Ref, pkg.Bytes, now+s.policy.KeyPackageTTLSeconds); err != nil {
			return 0, err
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return len(pkgs), nil
}

// consumeKeyPackage atomically marks one live package as consumed by the
// requesting device; concurrent consumers each get a distinct package.
func (s *relay) consumeKeyPackage(room, device, consumer string) (storedKeyPackage, error) {
	now := time.Now().Unix()
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return storedKeyPackage{}, err
	}
	defer tx.Rollback()
	row, err := readRoom(tx, room)
	if errors.Is(err, sql.ErrNoRows) {
		return storedKeyPackage{}, errNoRoom
	}
	if err != nil {
		return storedKeyPackage{}, err
	}
	if row.closed {
		return storedKeyPackage{}, errClosed
	}
	pkg := storedKeyPackage{}
	err = tx.QueryRow(`SELECT ref, bytes, expires_at FROM mls_keypackages
		WHERE room = ? AND device = ? AND consumed_by IS NULL AND expires_at > ?
		ORDER BY rowid LIMIT 1`, room, device, now).Scan(&pkg.Ref, &pkg.Bytes, &pkg.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return storedKeyPackage{}, errNoKeyPackage
	}
	if err != nil {
		return storedKeyPackage{}, err
	}
	if _, err := tx.Exec(`UPDATE mls_keypackages SET consumed_by = ? WHERE room = ? AND device = ? AND ref = ?`,
		consumer, room, device, pkg.Ref); err != nil {
		return storedKeyPackage{}, err
	}
	if err := tx.Commit(); err != nil {
		return storedKeyPackage{}, err
	}
	return pkg, nil
}

// prune enforces the §3.4 retention rules inside the caller's write
// transaction: application events once every recorded cursor passed them and
// the TTL elapsed, commit/welcome events outside the last N epochs, and
// expired key packages. The gate is the minimum durable cursor over every
// known reader (posters and Welcome targets), so a device that has not read
// yet — including one offline across a relay restart — blocks deletion.
func (s *relay) prune(tx *sql.Tx, room string, epoch int64, now int64) error {
	if _, err := tx.Exec(`DELETE FROM mls_keypackages WHERE room = ? AND expires_at <= ?`, room, now); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM mls_events WHERE room = ? AND kind IN ('commit','welcome') AND epoch <= ?`,
		room, epoch-s.policy.CommitWelcomeKeepEpochs); err != nil {
		return err
	}
	rows, err := tx.Query(`SELECT seq FROM mls_events WHERE room = ? AND kind = 'application' AND created_at < ?`,
		room, now-s.policy.AppEventTTLSeconds)
	if err != nil {
		return err
	}
	var stale []int64
	for rows.Next() {
		var seq int64
		if err := rows.Scan(&seq); err != nil {
			rows.Close()
			return err
		}
		stale = append(stale, seq)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	if len(stale) == 0 {
		return nil
	}
	var minCursor sql.NullInt64
	if err := tx.QueryRow(`SELECT MIN(seq) FROM mls_cursors WHERE room = ?`, room).Scan(&minCursor); err != nil {
		return err
	}
	if !minCursor.Valid {
		return nil // no known reader: keep everything
	}
	for _, seq := range stale {
		if minCursor.Int64 >= seq {
			if _, err := tx.Exec(`DELETE FROM mls_events WHERE room = ? AND seq = ?`, room, seq); err != nil {
				return err
			}
		}
	}
	return nil
}

// registerCursor makes device a known reader of room without moving an
// existing cursor (INSERT OR IGNORE): a first post or Welcome sets the floor,
// only reads advance it.
func registerCursor(tx *sql.Tx, room, device string, seq int64) error {
	_, err := tx.Exec(`INSERT OR IGNORE INTO mls_cursors (room, device, seq) VALUES (?, ?, ?)`, room, device, seq)
	return err
}

func targetedAt(encoded, device string) bool {
	for _, t := range strings.Split(encoded, ",") {
		if t == device {
			return true
		}
	}
	return false
}

func encodeTargets(targets []string) string { return strings.Join(targets, ",") }

var errNoRoom = fmt.Errorf("no such room")
var errNoKeyPackage = fmt.Errorf("no live key package")
var errWelcomeTargets = fmt.Errorf("welcome requires targets")
