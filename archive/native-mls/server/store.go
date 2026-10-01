// native-mls v2 relay (#177 §3.4). Four routes, three tables plus room
// closure, one SQLite file owned by the native track. The operational
// server/ schema 12 is untouched: this module never imports it and uses its
// own database file. CAS reads, count checks and inserts share one
// transaction that starts as BEGIN IMMEDIATE (the DSN carries
// _txlock=immediate, so db.Begin() takes the write lock up front — B2/B3).
package main

import (
	"database/sql"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/jinwon-int/family-messenger/archive/native-mls/server/internal/devicepolicy"

	_ "github.com/mattn/go-sqlite3"
)

const (
	storeFile = "native-mls-v2.db"
	// storeLockFile is a zero-size flock anchor next to the database. The
	// relay holds it exclusively for its whole lifetime; the offline
	// -reset-room path takes the same lock, so it cannot run under a live
	// relay and a second relay cannot open the same data dir (H3 recovery).
	storeLockFile = "native-mls-v2.lock"
)

// errStoreLocked: another process (normally the running relay) holds the
// data-dir lock.
var errStoreLocked = errors.New("data dir is locked by another process (is the relay running?)")

// store is the relay's SQLite handle plus the data-dir lock; Close releases
// both so a restart (or the offline reset tool) can take over the file.
type store struct {
	*sql.DB
	lock *os.File
}

func (s *store) Close() error {
	err := s.DB.Close()
	if s.lock != nil {
		_ = syscall.Flock(int(s.lock.Fd()), syscall.LOCK_UN)
		s.lock.Close()
		s.lock = nil
	}
	return err
}

// lockDataDir takes the exclusive, non-blocking data-dir lock.
func lockDataDir(dataDir string) (*os.File, error) {
	f, err := os.OpenFile(filepath.Join(dataDir, storeLockFile), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, errStoreLocked
		}
		return nil, fmt.Errorf("lock %s: %w", storeLockFile, err)
	}
	return f, nil
}

// sqliteURI mirrors server/internal/chat/sqlite.go sqliteURI() for the
// durability posture (DELETE journal, synchronous FULL, foreign keys,
// secure_delete, 5 s busy_timeout) and adds _txlock=immediate so every
// transaction is BEGIN IMMEDIATE: the write lock is taken at Begin, not at
// the first write, which is what the CAS-read-then-insert discipline needs
// (M6). The native track never imports the live module.
func sqliteURI(path string) string {
	return "file:" + filepath.ToSlash(path) +
		"?_journal_mode=DELETE&_synchronous=FULL&_foreign_keys=on&_busy_timeout=5000&_secure_delete=on&_txlock=immediate"
}

const schema = `
CREATE TABLE IF NOT EXISTS mls_rooms (
	room       TEXT PRIMARY KEY,
	group_id   TEXT NOT NULL,
	epoch      INTEGER NOT NULL DEFAULT 0,
	revision   INTEGER NOT NULL DEFAULT 0,
	last_seq   INTEGER NOT NULL DEFAULT 0,
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
	room        TEXT NOT NULL REFERENCES mls_rooms(room),
	device      TEXT NOT NULL,
	seq         INTEGER NOT NULL,
	removed_at  INTEGER,
	removed_seq INTEGER,
	PRIMARY KEY (room, device)
);
CREATE TABLE IF NOT EXISTS mls_members (
	room      TEXT NOT NULL REFERENCES mls_rooms(room),
	device    TEXT NOT NULL,
	actor     TEXT NOT NULL,
	added_seq INTEGER NOT NULL,
	PRIMARY KEY (room, device)
);
`

func openStore(dataDir string) (*store, error) {
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, err
	}
	lock, err := lockDataDir(dataDir)
	if err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite3", sqliteURI(filepath.Join(dataDir, storeFile)))
	if err != nil {
		lock.Close()
		return nil, err
	}
	st := &store{DB: db, lock: lock}
	// One connection: with _txlock=immediate every Begin takes the write
	// lock, and busy_timeout covers an external reader; the relay mutex on
	// top means the process never races itself.
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		st.Close()
		return nil, err
	}
	if err := migrate(db); err != nil {
		st.Close()
		return nil, err
	}
	return st, nil
}

// migrate adds columns to tables created before they existed (CREATE TABLE
// IF NOT EXISTS leaves an old table untouched): the H3a removal-grace
// columns on mls_cursors and the durable per-room seq counter on mls_rooms.
// last_seq is backfilled from the surviving events; it must never go
// backwards, which MAX(seq) over a pruned table cannot promise.
func migrate(db *sql.DB) error {
	for _, c := range []struct{ table, column, decl string }{
		{"mls_cursors", "removed_at", "INTEGER"},
		{"mls_cursors", "removed_seq", "INTEGER"},
		{"mls_rooms", "last_seq", "INTEGER NOT NULL DEFAULT 0"},
	} {
		added, err := ensureColumn(db, c.table, c.column, c.decl)
		if err != nil {
			return err
		}
		if added && c.column == "last_seq" {
			if _, err := db.Exec(`UPDATE mls_rooms SET last_seq =
				(SELECT COALESCE(MAX(seq), 0) FROM mls_events e WHERE e.room = mls_rooms.room)`); err != nil {
				return fmt.Errorf("backfill mls_rooms.last_seq: %w", err)
			}
		}
	}
	return nil
}

// ensureColumn adds column to table unless PRAGMA table_info already lists
// it; reports whether it was added.
func ensureColumn(db *sql.DB, table, column, decl string) (bool, error) {
	rows, err := db.Query(`PRAGMA table_info(` + table + `)`)
	if err != nil {
		return false, err
	}
	have := false
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var dflt sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &dflt, &pk); err != nil {
			rows.Close()
			return false, err
		}
		if name == column {
			have = true
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return false, err
	}
	if have {
		return false, nil
	}
	if _, err := db.Exec(`ALTER TABLE ` + table + ` ADD COLUMN ` + column + ` ` + decl); err != nil {
		return false, fmt.Errorf("migrate %s.%s: %w", table, column, err)
	}
	return true, nil
}

var errClosed = errors.New("room closed")

// eventInput is the validated store-side form of one POST /events body.
// revision is a pointer so an absent CAS field and epoch=0 stay distinct.
// members is the client-replicated post-commit leaf list (§3.3); the relay
// enforces its membership policy against it because it cannot parse MLS
// commit payloads.
type eventInput struct {
	groupID  string
	device   string
	clientID string
	kind     string
	epoch    int64
	revision *int64
	targets  []string
	members  []memberWire
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
	lastSeq  int64
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
	err := q.QueryRow(`SELECT group_id, epoch, revision, last_seq, closed_at FROM mls_rooms WHERE room = ?`, room).
		Scan(&row.groupID, &row.epoch, &row.revision, &row.lastSeq, &closed)
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
// operator deletes the file. Expired key packages are swept in the same
// write. With membership enforcement on, only a tracked member may close
// (errNotMember); an unknown room is errNoRoom.
func closeRoom(db *sql.DB, room, device string, enforce bool, now int64) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := readRoom(tx, room); errors.Is(err, sql.ErrNoRows) {
		return errNoRoom
	} else if err != nil {
		return err
	}
	if enforce {
		tracked, err := readMembers(tx, room)
		if err != nil {
			return err
		}
		member := false
		for _, m := range tracked {
			if m.Device == device {
				member = true
			}
		}
		if !member {
			return errNotMember
		}
	}
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
// CAS/count+insert transaction, then closeRoom does the SQLite work. The
// membership gate is on exactly when the device-policy store is wired.
func (s *relay) closeRoomDB(room, device string, now int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return closeRoom(s.db.DB, room, device, s.devices != nil, now)
}

// storeEvent appends one event under CAS discipline. Body validation happened
// in the handler; everything below (room read, CAS, idempotency, seq
// allocation, pruning, byte cap, insert) is one BEGIN IMMEDIATE transaction.
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
	// M3b: authorization runs before the K4 replay and the CAS reads on
	// purpose — a revoked or non-member sender gets 403 without learning the
	// current epoch/revision from a 409, while an allowed sender's byte-equal
	// retry below still replays as the 200 duplicate.
	active, tracked, err := s.authorizeEvent(tx, room, ev)
	if err != nil {
		return storedEvent{}, err
	}
	// K4 before CAS: a byte-equal replay of a stored event is the 200 duplicate
	// even if a commit has since moved the epoch (lost response + concurrent
	// commit); different bytes under a taken client_id are reuse regardless.
	// A replayed commit answers the epoch it produced, as the 201 did (L1).
	var prevSeq int64
	var prevEpoch int64
	var prevKind string
	var prevBytes []byte
	err = tx.QueryRow(`SELECT seq, epoch, kind, bytes FROM mls_events WHERE room = ? AND device = ? AND client_id = ?`,
		room, ev.device, ev.clientID).Scan(&prevSeq, &prevEpoch, &prevKind, &prevBytes)
	if err == nil {
		if string(prevBytes) == string(ev.bytes) {
			if prevKind == "commit" {
				prevEpoch++
			}
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
	// seq comes from the room's durable counter, not MAX(seq) over the
	// events: pruning (also on GET now) may empty the table and the order
	// must never restart.
	seq := row.lastSeq + 1
	newEpoch, newRevision := row.epoch, row.revision+1
	if ev.kind == "commit" {
		newEpoch = row.epoch + 1
	}
	// Every device that posts, and every Welcome target, becomes a known
	// reader of the room: its durable cursor gates application-event pruning
	// until it reads (poster from 0, a Welcome target from just before its
	// Welcome — it cannot decrypt anything earlier). Registered before the
	// prune below so a first-time poster is already a gate.
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
	// H2: reclaim retention-expired bytes BEFORE measuring the room against
	// its cap, so a room full of stale application events does not refuse
	// the commit that would let it move on. The new row's epoch is strictly
	// above the commit/welcome retention window, so pruning at newEpoch
	// before the insert is equivalent to pruning after it.
	if err := s.prune(tx, room, newEpoch, now, active); err != nil {
		return storedEvent{}, err
	}
	// B5: cap the room by event bytes, not by count.
	var used sql.NullInt64
	if err := tx.QueryRow(`SELECT SUM(LENGTH(bytes)) FROM mls_events WHERE room = ?`, room).Scan(&used); err != nil {
		return storedEvent{}, err
	}
	if s.policy.RoomBytesCap > 0 && used.Int64+int64(len(ev.bytes)) > s.policy.RoomBytesCap {
		return storedEvent{}, roomBytesCap{used.Int64, s.policy.RoomBytesCap}
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
	// M3b: apply the membership diff in the same transaction as the commit
	// insert, so a crash cannot leave membership and the log disagree.
	founding := active != nil && ev.kind == "commit" && len(tracked) == 0
	if active != nil && ev.kind == "commit" {
		if err := applyMembership(tx, room, tracked, ev, seq, now); err != nil {
			return storedEvent{}, err
		}
	}
	if _, err := tx.Exec(`UPDATE mls_rooms SET epoch = ?, revision = ?, last_seq = ? WHERE room = ?`, newEpoch, newRevision, seq, room); err != nil {
		return storedEvent{}, err
	}
	if err := tx.Commit(); err != nil {
		return storedEvent{}, err
	}
	if founding {
		// H3: room names are first-come among authenticated devices. The
		// founding commit is the squatting-relevant moment, so it is logged
		// with sender, actor and the seeded roster; -reset-room is the
		// operator's recovery path (DEVICES-V4.md).
		log.Printf("room %s founded: sender=%s actor=%s seq=%d members=%s",
			room, ev.device, active[ev.device].Actor, seq, describeMembers(ev.members))
	}
	return storedEvent{seq: seq, epoch: newEpoch, revision: newRevision}, nil
}

// describeMembers renders a replicated member list as device(actor),... for
// the founding-commit log line.
func describeMembers(members []memberWire) string {
	parts := make([]string, 0, len(members))
	for _, m := range members {
		parts = append(parts, m.Device+"("+m.Actor+")")
	}
	return strings.Join(parts, ",")
}

// enforceDevicePolicy replays the native device-policy chain (M3b) and
// returns the active-device set. A nil set with nil error means the relay
// runs without -device-state: enforcement is off and POSTs behave exactly as
// before. A chain error is fail-closed: no write proceeds.
func (s *relay) enforceDevicePolicy() (map[string]devicepolicy.DeviceV4, error) {
	if s.devices == nil {
		return nil, nil
	}
	_, wire, err := s.devices.Read()
	if err != nil {
		return nil, policyUnavailable{Err: err}
	}
	active := make(map[string]devicepolicy.DeviceV4, len(wire.Devices))
	for _, d := range wire.Devices {
		if d.Status == devicepolicy.StatusActive {
			active[d.ID] = d
		}
	}
	return active, nil
}

// authorizeEvent is the §3.3 membership gate, run inside the store
// transaction. Every poster must be policy-active; a commit's sender must be
// a tracked member, and its replicated member list may only seed the first
// membership (every seeded device active, the sender among them — H3b) or
// add active devices of actors already on the room roster and drop tracked
// devices. Returns the active set and the pre-commit tracked membership (nil
// tracked = bootstrap commit).
func (s *relay) authorizeEvent(tx *sql.Tx, room string, ev eventInput) (map[string]devicepolicy.DeviceV4, []memberRow, error) {
	active, err := s.enforceDevicePolicy()
	if err != nil {
		return nil, nil, err
	}
	if active == nil {
		return nil, nil, nil
	}
	if _, ok := active[ev.device]; !ok {
		return nil, nil, deviceNotAllowed{Device: ev.device}
	}
	if ev.kind != "commit" {
		return active, nil, nil
	}
	tracked, err := readMembers(tx, room)
	if err != nil {
		return nil, nil, err
	}
	if len(tracked) == 0 {
		// Bootstrap: the room's first commit carries the founding member
		// list; every founding device must be policy-active and the sender
		// must found itself in (the handler already rejects the structural
		// case; this is the store-level line).
		senderListed := false
		for _, m := range ev.members {
			if _, ok := active[m.Device]; !ok {
				return nil, nil, commitMemberNotActive{Device: m.Device}
			}
			if m.Device == ev.device {
				senderListed = true
			}
		}
		if !senderListed {
			return nil, nil, commitSenderNotMember{Device: ev.device}
		}
		return active, nil, nil
	}
	senderTracked := false
	roster := map[string]bool{}
	byDevice := map[string]bool{}
	for _, m := range tracked {
		roster[m.Actor] = true
		byDevice[m.Device] = true
		if m.Device == ev.device {
			senderTracked = true
		}
	}
	if !senderTracked {
		return nil, nil, commitSenderNotMember{Device: ev.device}
	}
	for _, m := range ev.members {
		if byDevice[m.Device] {
			continue
		}
		if _, ok := active[m.Device]; !ok {
			return nil, nil, commitMemberNotActive{Device: m.Device}
		}
		if !roster[m.Actor] {
			return nil, nil, commitActorNotInRoster{Actor: m.Actor}
		}
	}
	return active, tracked, nil
}

// memberRow is one tracked room membership entry.
type memberRow struct {
	Device string
	Actor  string
}

func readMembers(tx *sql.Tx, room string) ([]memberRow, error) {
	rows, err := tx.Query(`SELECT device, actor FROM mls_members WHERE room = ? ORDER BY rowid`, room)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []memberRow{}
	for rows.Next() {
		var m memberRow
		if err := rows.Scan(&m.Device, &m.Actor); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// applyMembership applies the commit's replicated member list on top of the
// tracked membership, inside the caller's transaction. An empty tracked set
// is the bootstrap seed; afterwards the diff adds new devices (reviving a
// previously removed cursor as a plain reader) and removes tracked devices
// the list no longer contains. A removed device's reader cursor is not
// deleted: it is marked removed_at/removed_seq and keeps gating
// application-event pruning until the device reads its own removal or the
// grace elapses (H3a), so a member that is removed while offline can still
// fetch what led up to it.
func applyMembership(tx *sql.Tx, room string, tracked []memberRow, ev eventInput, seq int64, now int64) error {
	if len(tracked) == 0 {
		for _, m := range ev.members {
			if _, err := tx.Exec(`INSERT OR IGNORE INTO mls_members (room, device, actor, added_seq) VALUES (?, ?, ?, ?)`,
				room, m.Device, m.Actor, seq); err != nil {
				return err
			}
		}
		return nil
	}
	trackedSet := make(map[string]bool, len(tracked))
	for _, m := range tracked {
		trackedSet[m.Device] = true
	}
	for _, m := range ev.members {
		if trackedSet[m.Device] {
			continue
		}
		if _, err := tx.Exec(`INSERT OR IGNORE INTO mls_members (room, device, actor, added_seq) VALUES (?, ?, ?, ?)`,
			room, m.Device, m.Actor, seq); err != nil {
			return err
		}
		if _, err := tx.Exec(`UPDATE mls_cursors SET removed_at = NULL, removed_seq = NULL WHERE room = ? AND device = ?`,
			room, m.Device); err != nil {
			return err
		}
	}
	postedList := make(map[string]bool, len(ev.members))
	for _, m := range ev.members {
		postedList[m.Device] = true
	}
	for _, m := range tracked {
		if postedList[m.Device] {
			continue
		}
		if _, err := tx.Exec(`DELETE FROM mls_members WHERE room = ? AND device = ?`, room, m.Device); err != nil {
			return err
		}
		if _, err := tx.Exec(`UPDATE mls_cursors SET removed_at = ?, removed_seq = ? WHERE room = ? AND device = ? AND removed_at IS NULL`,
			now, seq, room, m.Device); err != nil {
			return err
		}
	}
	return nil
}

// eventsPage is readEvents' result: one page of rows, the room's CAS state,
// the highest seq scanned (next_after) and the device's durable cursor after
// the request (the ack'd value, 0 for a device that never acked).
type eventsPage struct {
	rows      []storedRow
	room      roomRow
	nextAfter int64
	cursor    int64
}

// readEvents returns one page (limit rows scanned in seq order after `after`)
// of the per-room total order, filtering welcome events targeted at other
// devices (B4: filter, never 403). nextAfter is the highest seq scanned.
//
// M2: reading never moves the device's durable cursor — `after` is a pure
// read offset, so a response lost on the wire can be re-read. The cursor
// (mls_cursors, the application-event pruning gate) moves only on an explicit
// acknowledgement (ack != nil): the device asserts it has durably processed
// everything up to ack, the cursor becomes max(current, ack), and when that
// advanced the room is pruned in the same transaction (H2). ack must not
// exceed the room's last_seq (badAck) and is accepted only from a known
// reader: a device with a cursor (poster, Welcome target, removed member
// within its grace) or a tracked member of the room; with membership
// tracking on, any other device of a seeded room is errNotMember — it must
// not become a pruning gate by merely reading.
func (s *relay) readEvents(room, device string, after int64, limit int, ack *int64) (eventsPage, error) {
	now := time.Now().Unix()
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return eventsPage{}, err
	}
	defer tx.Rollback()
	row, err := readRoom(tx, room)
	if errors.Is(err, sql.ErrNoRows) {
		return eventsPage{}, errNoRoom
	}
	if err != nil {
		return eventsPage{}, err
	}
	if row.closed {
		return eventsPage{}, errClosed
	}
	rows, err := tx.Query(`SELECT seq, device, client_id, kind, epoch, targets, bytes, sha256, created_at
		FROM mls_events WHERE room = ? AND seq > ? ORDER BY seq LIMIT ?`, room, after, limit)
	if err != nil {
		return eventsPage{}, err
	}
	page := eventsPage{rows: []storedRow{}, room: row, nextAfter: after}
	for rows.Next() {
		var r storedRow
		var targets sql.NullString
		if err := rows.Scan(&r.Seq, &r.Device, &r.ClientID, &r.Kind, &r.Epoch, &targets, &r.Bytes, &r.Sha256, &r.CreatedAt); err != nil {
			rows.Close()
			return eventsPage{}, err
		}
		if r.Seq > page.nextAfter {
			page.nextAfter = r.Seq
		}
		if r.Kind == "welcome" && !targetedAt(targets.String, device) {
			continue
		}
		page.rows = append(page.rows, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return eventsPage{}, err
	}
	if ack == nil {
		cur, err := readCursor(tx, room, device)
		if err != nil {
			return eventsPage{}, err
		}
		page.cursor = cur
		return page, tx.Commit()
	}
	cur, advanced, err := ackCursor(tx, s.devices != nil, room, device, *ack, row.lastSeq)
	if err != nil {
		return eventsPage{}, err
	}
	page.cursor = cur
	if advanced {
		// A chain that cannot be read must not close GET (deny is write-side);
		// the prune simply waits for the next write.
		active, err := s.enforceDevicePolicy()
		if err != nil {
			log.Printf("get events room=%s: prune skipped: %v", room, err)
		} else if err := s.prune(tx, room, row.epoch, now, active); err != nil {
			return eventsPage{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return eventsPage{}, err
	}
	return page, nil
}

// badAck: ?ack= names a seq the room has not produced yet (400).
type badAck struct{ Ack, LastSeq int64 }

func (e badAck) Error() string {
	return fmt.Sprintf("ack %d exceeds the room's last_seq %d", e.Ack, e.LastSeq)
}

// readCursor returns the device's durable cursor, 0 when it has none.
func readCursor(tx *sql.Tx, room, device string) (int64, error) {
	var cur int64
	err := tx.QueryRow(`SELECT seq FROM mls_cursors WHERE room = ? AND device = ?`, room, device).Scan(&cur)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	return cur, err
}

// ackCursor applies an acknowledgement: the reader's durable cursor becomes
// max(current, ack) and the result plus whether it moved are returned. A
// device without a cursor row may only create one when it is a legitimate
// reader: with membership tracking on and a seeded room, a tracked member
// (errNotMember otherwise — a removed member whose grace already dropped its
// row is a non-member too). ack above the room's last_seq is badAck; the
// membership verdict comes first so the 400 does not act as an oracle for
// outsiders.
func ackCursor(tx *sql.Tx, membership bool, room, device string, ack, lastSeq int64) (int64, bool, error) {
	var prev int64
	err := tx.QueryRow(`SELECT seq FROM mls_cursors WHERE room = ? AND device = ?`, room, device).Scan(&prev)
	exists := err == nil
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, false, err
	}
	if !exists && membership {
		tracked, err := readMembers(tx, room)
		if err != nil {
			return 0, false, err
		}
		if len(tracked) > 0 {
			member := false
			for _, m := range tracked {
				if m.Device == device {
					member = true
				}
			}
			if !member {
				return 0, false, errNotMember
			}
		}
	}
	if ack > lastSeq {
		return 0, false, badAck{Ack: ack, LastSeq: lastSeq}
	}
	if exists {
		if ack <= prev {
			return prev, false, nil
		}
		_, err := tx.Exec(`UPDATE mls_cursors SET seq = ? WHERE room = ? AND device = ?`, ack, room, device)
		return ack, err == nil, err
	}
	_, err = tx.Exec(`INSERT INTO mls_cursors (room, device, seq) VALUES (?, ?, ?)`, room, device, ack)
	return ack, err == nil, err
}

// keyPackagesResult is postKeyPackages' outcome in store terms.
type keyPackagesResult = keyPackagesResponse

// postKeyPackages stores key packages with a shared TTL and a per-device live
// cap, sweeping expired rows in the same transaction. A (room, device, ref)
// that already holds byte-identical bytes is accepted idempotently and not
// counted against the cap; different bytes under a stored ref are a conflict
// (M5), so a lost response can be retried but a ref can never be repointed.
func (s *relay) postKeyPackages(room, device string, pkgs []keyPackageInput) (keyPackagesResult, error) {
	now := time.Now().Unix()
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return keyPackagesResult{}, err
	}
	defer tx.Rollback()
	// M3b: policy-active gate before any room state is touched, so a denied
	// device cannot even materialize a room row. A nil active set (no
	// -device-state) means enforcement is off: every device may post.
	if active, err := s.enforceDevicePolicy(); err != nil {
		return keyPackagesResult{}, err
	} else if active != nil {
		if _, ok := active[device]; !ok {
			return keyPackagesResult{}, deviceNotAllowed{Device: device}
		}
	}
	if _, err := ensureRoom(tx, room, "", now); err != nil {
		return keyPackagesResult{}, err
	}
	row, err := readRoom(tx, room)
	if err != nil {
		return keyPackagesResult{}, err
	}
	if row.closed {
		return keyPackagesResult{}, errClosed
	}
	if _, err := tx.Exec(`DELETE FROM mls_keypackages WHERE expires_at <= ?`, now); err != nil {
		return keyPackagesResult{}, err
	}
	var fresh []keyPackageInput
	res := keyPackagesResult{}
	for _, pkg := range pkgs {
		var existing []byte
		err := tx.QueryRow(`SELECT bytes FROM mls_keypackages WHERE room = ? AND device = ? AND ref = ?`,
			room, device, pkg.Ref).Scan(&existing)
		switch {
		case err == nil:
			if string(existing) != string(pkg.Bytes) {
				return keyPackagesResult{}, keyPackageRefConflict{Ref: pkg.Ref}
			}
			res.Duplicates++
		case errors.Is(err, sql.ErrNoRows):
			fresh = append(fresh, pkg)
		default:
			return keyPackagesResult{}, err
		}
	}
	var live int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM mls_keypackages WHERE room = ? AND device = ? AND consumed_by IS NULL AND expires_at > ?`,
		room, device, now).Scan(&live); err != nil {
		return keyPackagesResult{}, err
	}
	if live+len(fresh) > s.policy.KeyPackagesMaxPerDevice {
		return keyPackagesResult{}, keyPackageLimit{live, s.policy.KeyPackagesMaxPerDevice}
	}
	for _, pkg := range fresh {
		if _, err := tx.Exec(`INSERT INTO mls_keypackages (room, device, ref, bytes, expires_at) VALUES (?, ?, ?, ?, ?)`,
			room, device, pkg.Ref, pkg.Bytes, now+s.policy.KeyPackageTTLSeconds); err != nil {
			return keyPackagesResult{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return keyPackagesResult{}, err
	}
	res.Stored = len(fresh)
	return res, nil
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
// yet — including one offline across a relay restart — blocks deletion. With
// enforcement on (active != nil), cursors of devices that have left the
// device policy are dropped first: a revoked device never reads again and
// must not hold the room's pruning hostage. Cursors of members removed by
// commit are dropped once the device has read its removal (seq >=
// removed_seq) or the removal grace elapsed (H3a).
func (s *relay) prune(tx *sql.Tx, room string, epoch int64, now int64, active map[string]devicepolicy.DeviceV4) error {
	if _, err := tx.Exec(`DELETE FROM mls_keypackages WHERE room = ? AND expires_at <= ?`, room, now); err != nil {
		return err
	}
	if active != nil {
		if err := dropStaleCursors(tx, room, active); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(`DELETE FROM mls_cursors WHERE room = ? AND removed_at IS NOT NULL
		AND (seq >= removed_seq OR removed_at <= ?)`, room, now-s.policy.RemovedCursorGraceSeconds); err != nil {
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
// only an explicit ?ack= advances it (M2).
func registerCursor(tx *sql.Tx, room, device string, seq int64) error {
	_, err := tx.Exec(`INSERT OR IGNORE INTO mls_cursors (room, device, seq) VALUES (?, ?, ?)`, room, device, seq)
	return err
}

// dropStaleCursors removes reader cursors of devices no longer active in the
// device policy (revoked or vanished). M1 follow-up: a removed or tombstoned
// device must not pin application events forever.
func dropStaleCursors(tx *sql.Tx, room string, active map[string]devicepolicy.DeviceV4) error {
	rows, err := tx.Query(`SELECT DISTINCT device FROM mls_cursors WHERE room = ?`, room)
	if err != nil {
		return err
	}
	var stale []string
	for rows.Next() {
		var d string
		if err := rows.Scan(&d); err != nil {
			rows.Close()
			return err
		}
		if _, ok := active[d]; !ok {
			stale = append(stale, d)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, d := range stale {
		if _, err := tx.Exec(`DELETE FROM mls_cursors WHERE room = ? AND device = ?`, room, d); err != nil {
			return err
		}
	}
	return nil
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
var errNotMember = fmt.Errorf("device is not a tracked member of the room")
var errNoKeyPackage = fmt.Errorf("no live key package")
var errWelcomeTargets = fmt.Errorf("welcome requires targets")
