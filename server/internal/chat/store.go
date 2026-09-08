// Package chat implements a synthetic-data-only, Linux development messenger.
package chat

import (
	"database/sql"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

var (
	ErrForbidden = errors.New("forbidden")
	ErrConflict  = errors.New("conflict")
	ErrInvalid   = errors.New("invalid request")
	ErrLimit     = errors.New("prototype capacity reached")
)

const MaxPayload = 16 * 1024
const MaxMessages = 10000

var actors = map[string]bool{"alice": true, "bob": true, "charlie": true}

type Message struct {
	Seq       int64  `json:"seq"`
	Room      string `json:"room"`
	Actor     string `json:"actor"`
	ClientID  string `json:"client_id"`
	Payload   []byte `json:"payload"` // Base64 on the wire. These bytes are NOT E2EE.
	CreatedMS int64  `json:"created_ms"`
}

type Store struct {
	mu         sync.Mutex // Serializes ACL changes with bounded stream writes as well as DB access.
	db         *sql.DB
	lock       *os.File
	changed    chan struct{}
	uploads    map[mediaKey]*mediaLease
	mediaEpoch map[[2]string]uint64
}

// Open requires an existing, private directory. It never initializes over unknown data.
// Same-UID/root attackers are outside this local prototype's filesystem boundary.
func Open(dir string) (_ *Store, err error) {
	if !filepath.IsAbs(dir) || filepath.Clean(dir) != dir {
		return nil, ErrInvalid
	}
	for p := dir; ; p = filepath.Dir(p) {
		st, e := os.Lstat(p)
		if e != nil {
			return nil, e
		}
		if !st.IsDir() || st.Mode()&os.ModeSymlink != 0 {
			return nil, fmt.Errorf("unsafe state path")
		}
		uid := st.Sys().(*syscall.Stat_t).Uid
		if (uid != 0 && uid != uint32(os.Geteuid())) || (st.Mode().Perm()&0022 != 0 && !(st.Mode()&os.ModeSticky != 0 && uid == 0)) {
			return nil, fmt.Errorf("unsafe state ancestor")
		}
		if p == dir && (st.Mode().Perm() != 0700 || st.Sys().(*syscall.Stat_t).Uid != uint32(os.Geteuid())) {
			return nil, fmt.Errorf("state directory must be owned and mode 0700")
		}
		if p == "/" {
			break
		}
	}
	fd, e := syscall.Open(filepath.Join(dir, "lock"), syscall.O_CREAT|syscall.O_RDWR|syscall.O_NOFOLLOW|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0600)
	if e != nil {
		return nil, e
	}
	lock := os.NewFile(uintptr(fd), "state lock")
	defer func() {
		if err != nil {
			lock.Close()
		}
	}()
	if e = checkFile(lock); e != nil {
		return nil, e
	}
	if e = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); e != nil {
		return nil, fmt.Errorf("state already in use: %w", e)
	}
	entries, e := os.ReadDir(dir)
	if e != nil {
		return nil, e
	}
	hasJournal, hasNonemptyDB, hasSnapshots := false, false, false
	for _, entry := range entries {
		name := entry.Name()
		if name == "snapshots" {
			hasSnapshots = true
			if e := inspectSnapshots(filepath.Join(dir, name)); e != nil {
				return nil, e
			}
			continue
		}
		if name != "lock" && name != "messages.sqlite" && name != "messages.sqlite-journal" {
			return nil, fmt.Errorf("unexpected state file")
		}
		f, e := os.OpenFile(filepath.Join(dir, name), os.O_RDWR|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
		if e != nil {
			return nil, e
		}
		e = checkFile(f)
		if e == nil {
			st, statErr := f.Stat()
			e = statErr
			if statErr == nil && name == "messages.sqlite" {
				hasNonemptyDB = st.Size() > 0
			}
			if name == "messages.sqlite-journal" {
				hasJournal = true
			}
		}
		f.Close()
		if e != nil {
			return nil, e
		}
	}
	// SQLite may remove a journal during initialization. Only pass an existing
	// sidecar to it after recognizing its nonempty database (header check below).
	if (hasJournal || hasSnapshots) && !hasNonemptyDB {
		return nil, fmt.Errorf("orphan journal or snapshots preserved; database missing or empty")
	}
	path := filepath.Join(dir, "messages.sqlite")
	fd, e = syscall.Open(path, syscall.O_CREAT|syscall.O_RDWR|syscall.O_NOFOLLOW|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0600)
	if e != nil {
		return nil, e
	}
	f := os.NewFile(uintptr(fd), "database")
	e = checkFile(f)
	if e == nil {
		// Inspect the stable SQLite header before opening the driver, which can
		// recover journals/change PRAGMAs. Never recover an unrelated database.
		st, statErr := f.Stat()
		if statErr != nil {
			e = statErr
		} else if st.Size() != 0 {
			header := make([]byte, 100)
			_, e = io.ReadFull(f, header)
			if e == nil && (string(header[:16]) != "SQLite format 3\x00" || binary.BigEndian.Uint32(header[68:72]) != 1179471188 || (binary.BigEndian.Uint32(header[60:64]) != 1 && binary.BigEndian.Uint32(header[60:64]) != 2 && binary.BigEndian.Uint32(header[60:64]) != 3)) {
				e = fmt.Errorf("not a supported synthetic messenger database")
			}
		}
	}
	f.Close()
	if e != nil {
		return nil, e
	}
	// URI metacharacters in filesystem paths must not become SQLite options.
	db, e := sql.Open("sqlite3", sqliteURI(path))
	if e != nil {
		return nil, e
	}
	defer func() {
		if err != nil {
			db.Close()
		}
	}()
	db.SetMaxOpenConns(1)
	var version int
	if e = db.QueryRow("PRAGMA user_version").Scan(&version); e != nil {
		return nil, e
	}
	var appID int
	if e = db.QueryRow("PRAGMA application_id").Scan(&appID); e != nil {
		return nil, e
	}
	if ((version == 1 || version == 2 || version == 3) && appID != 1179471188) || (version == 0 && appID != 0) {
		return nil, fmt.Errorf("not a synthetic messenger database")
	}
	if version != 0 && version != 1 && version != 2 && version != 3 {
		return nil, fmt.Errorf("unsupported schema")
	}
	if version == 0 {
		var count int
		if e = db.QueryRow("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").Scan(&count); e != nil {
			return nil, e
		}
		if count != 0 {
			return nil, fmt.Errorf("unrecognized database")
		}
		_, e = db.Exec(`BEGIN IMMEDIATE;
   CREATE TABLE rooms(id TEXT PRIMARY KEY, owner TEXT NOT NULL, next_seq INTEGER NOT NULL DEFAULT 1);
   CREATE TABLE members(room TEXT NOT NULL REFERENCES rooms(id), actor TEXT NOT NULL, PRIMARY KEY(room,actor));
   CREATE TABLE messages(room TEXT NOT NULL REFERENCES rooms(id), seq INTEGER NOT NULL, actor TEXT NOT NULL, client_id TEXT NOT NULL, payload BLOB NOT NULL, created_ms INTEGER NOT NULL, PRIMARY KEY(room,seq), UNIQUE(room,actor,client_id));
   PRAGMA application_id=1179471188;
   PRAGMA user_version=1;
   COMMIT;`)
		if e != nil {
			return nil, e
		}
	}
	if version < 2 {
		if e = migrateMedia(db, dir, version == 0); e != nil {
			return nil, e
		}
	}
	if version < 3 {
		if e = migrateMLS(db, dir, version < 2); e != nil {
			return nil, e
		}
	}
	return &Store{db: db, lock: lock, changed: make(chan struct{}), uploads: make(map[mediaKey]*mediaLease), mediaEpoch: make(map[[2]string]uint64)}, nil
}

func checkFile(f *os.File) error {
	st, e := f.Stat()
	if e != nil {
		return e
	}
	raw := st.Sys().(*syscall.Stat_t)
	if !st.Mode().IsRegular() || raw.Nlink != 1 || raw.Uid != uint32(os.Geteuid()) || st.Mode().Perm() != 0600 {
		return fmt.Errorf("state files must be owned, single-link regular files with mode 0600")
	}
	return nil
}

func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	e := s.db.Close()
	s.lock.Close()
	return e
}
func (s *Store) wake() { close(s.changed); s.changed = make(chan struct{}) }
func validID(v string) bool {
	if len(v) < 1 || len(v) > 64 {
		return false
	}
	return strings.IndexFunc(v, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_')
	}) < 0
}
func (s *Store) member(room, actor string) error {
	var n int
	if err := s.db.QueryRow("SELECT count(*) FROM members WHERE room=? AND actor=?", room, actor).Scan(&n); err != nil {
		return err
	}
	if n != 1 {
		return ErrForbidden
	}
	return nil
}

func (s *Store) CreateRoom(room, owner string, members []string) error {
	if !validID(room) || !actors[owner] || len(members) > 3 {
		return ErrInvalid
	}
	for _, a := range members {
		if !actors[a] {
			return ErrInvalid
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var n int
	if e := s.db.QueryRow("SELECT count(*) FROM rooms WHERE id=?", room).Scan(&n); e != nil {
		return e
	}
	if n != 0 {
		return ErrConflict
	}
	if e := s.db.QueryRow("SELECT count(*) FROM rooms").Scan(&n); e != nil {
		return e
	}
	if n >= 32 {
		return ErrLimit
	}
	tx, e := s.db.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if _, e = tx.Exec("INSERT INTO rooms(id,owner) VALUES(?,?)", room, owner); e != nil {
		return e
	}
	for _, a := range append([]string{owner}, members...) {
		if _, e = tx.Exec("INSERT OR IGNORE INTO members VALUES(?,?)", room, a); e != nil {
			return e
		}
	}
	if e = tx.Commit(); e == nil {
		s.wake()
	}
	return e
}

func (s *Store) SetMember(room, owner, actor string, present bool) error {
	if !actors[actor] {
		return ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var actual string
	e := s.db.QueryRow("SELECT owner FROM rooms WHERE id=?", room).Scan(&actual)
	if e == sql.ErrNoRows {
		return ErrForbidden
	}
	if e != nil {
		return e
	}
	if actual != owner {
		return ErrForbidden
	}
	if actor == owner && !present {
		return ErrInvalid
	}
	if present {
		_, e = s.db.Exec("INSERT OR IGNORE INTO members VALUES(?,?)", room, actor)
	} else {
		_, e = s.db.Exec("DELETE FROM members WHERE room=? AND actor=?", room, actor)
	}
	if e == nil {
		if !present {
			s.mediaEpoch[[2]string{room, actor}]++
		}
		s.wake()
	}
	return e
}

func (s *Store) Send(room, actor, clientID string, payload []byte) (Message, bool, error) {
	var m Message
	if !validID(clientID) || len(payload) == 0 || len(payload) > MaxPayload {
		return m, false, ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if e := s.member(room, actor); e != nil {
		return m, false, e
	}
	e := s.db.QueryRow("SELECT seq,payload,created_ms FROM messages WHERE room=? AND actor=? AND client_id=?", room, actor, clientID).Scan(&m.Seq, &m.Payload, &m.CreatedMS)
	m.Room, m.Actor, m.ClientID = room, actor, clientID
	if e == nil {
		if string(payload) != string(m.Payload) {
			return Message{}, false, ErrConflict
		}
		return m, false, nil
	}
	if e != sql.ErrNoRows {
		return Message{}, false, e
	}
	var n int
	if e = s.db.QueryRow("SELECT count(*) FROM messages").Scan(&n); e != nil {
		return Message{}, false, e
	}
	if n >= MaxMessages {
		return Message{}, false, ErrLimit
	}
	tx, e := s.db.Begin()
	if e != nil {
		return Message{}, false, e
	}
	defer tx.Rollback()
	if e = tx.QueryRow("SELECT next_seq FROM rooms WHERE id=?", room).Scan(&m.Seq); e != nil {
		return Message{}, false, e
	}
	m.Payload = append([]byte(nil), payload...)
	m.CreatedMS = time.Now().UnixMilli()
	if _, e = tx.Exec("INSERT INTO messages VALUES(?,?,?,?,?,?)", room, m.Seq, actor, clientID, payload, m.CreatedMS); e != nil {
		return Message{}, false, e
	}
	if _, e = tx.Exec("UPDATE rooms SET next_seq=next_seq+1 WHERE id=?", room); e != nil {
		return Message{}, false, e
	}
	if e = tx.Commit(); e != nil {
		return Message{}, false, e
	}
	s.wake()
	return m, true, nil
}

// history is called under mu; a future cursor is rejected instead of silently skipping messages.
func (s *Store) history(room, actor string, after int64) ([]Message, error) {
	if e := s.member(room, actor); e != nil {
		return nil, e
	}
	var next int64
	if e := s.db.QueryRow("SELECT next_seq FROM rooms WHERE id=?", room).Scan(&next); e != nil {
		return nil, e
	}
	if after < 0 || after >= next {
		return nil, ErrInvalid
	}
	rows, e := s.db.Query("SELECT seq,actor,client_id,payload,created_ms FROM messages WHERE room=? AND seq>? ORDER BY seq LIMIT 100", room, after)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := make([]Message, 0)
	for rows.Next() {
		m := Message{Room: room}
		if e = rows.Scan(&m.Seq, &m.Actor, &m.ClientID, &m.Payload, &m.CreatedMS); e != nil {
			return nil, e
		}
		out = append(out, m)
	}
	return out, rows.Err()
}
func (s *Store) History(room, actor string, after int64) ([]Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.history(room, actor, after)
}

// rooms is called with mu held through the HTTP response, just like history.
func (s *Store) rooms(actor string) ([]Room, error) {
	rows, e := s.db.Query("SELECT r.id,r.owner FROM rooms r JOIN members m ON m.room=r.id WHERE m.actor=? AND NOT EXISTS (SELECT 1 FROM mls_rooms x WHERE x.room=r.id) ORDER BY r.id", actor)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := make([]Room, 0)
	for rows.Next() {
		var r Room
		if e = rows.Scan(&r.ID, &r.Owner); e != nil {
			return nil, e
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

type Room struct {
	ID    string `json:"id"`
	Owner string `json:"owner"`
}
