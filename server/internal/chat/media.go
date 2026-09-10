package chat

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"mime"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"
)

const MaxAttachment = 8 * 1024 * 1024
const MaxMediaBytes = 128 * 1024 * 1024
const MaxAttachments = 128

var ErrIntegrity = errors.New("attachment checksum mismatch")
var ErrNotFound = errors.New("not found")
var ErrBusy = errors.New("upload already active")

type Attachment struct {
	ID        string `json:"id"`
	Room      string `json:"room"`
	Actor     string `json:"actor"`
	ClientID  string `json:"client_id"`
	Filename  string `json:"filename"`
	MediaType string `json:"media_type"`
	Size      int64  `json:"size"`
	SHA256    string `json:"sha256"`
	CreatedMS int64  `json:"created_ms"`
}

type mediaKey struct{ room, actor, client string }
type mediaLease struct {
	meta     Attachment
	epoch    uint64
	reserved int64
	existing bool
}

func mediaID() (string, error) {
	var b [16]byte
	if _, e := rand.Read(b[:]); e != nil {
		return "", e
	}
	return hex.EncodeToString(b[:]), nil
}
func validDigest(value string) bool {
	b, e := hex.DecodeString(value)
	return e == nil && len(b) == 32 && strings.ToLower(value) == value
}
func validAttachmentID(value string) bool {
	b, e := hex.DecodeString(value)
	return e == nil && len(b) == 16 && strings.ToLower(value) == value
}
func validateAttachment(m Attachment) error {
	if !validID(m.ClientID) || m.Size < 1 || m.Size > MaxAttachment || !validDigest(m.SHA256) || !utf8.ValidString(m.Filename) || len(m.Filename) < 1 || len(m.Filename) > 180 || m.Filename == "." || m.Filename == ".." {
		return ErrInvalid
	}
	if strings.IndexFunc(m.Filename, func(r rune) bool { return r == '/' || r == '\\' || unicode.IsControl(r) || unicode.Is(unicode.Cf, r) }) >= 0 {
		return ErrInvalid
	}
	typ, params, e := mime.ParseMediaType(m.MediaType)
	if e != nil || len(params) != 0 || !strings.Contains(typ, "/") || typ != m.MediaType || len(typ) > 100 {
		return ErrInvalid
	}
	return nil
}

const mediaColumns = "id,room,actor,client_id,filename,media_type,size,sha256,created_ms"

type scanner interface{ Scan(...any) error }

func scanAttachment(row scanner) (Attachment, error) {
	var m Attachment
	e := row.Scan(&m.ID, &m.Room, &m.Actor, &m.ClientID, &m.Filename, &m.MediaType, &m.Size, &m.SHA256, &m.CreatedMS)
	return m, e
}
func sameUpload(a, b Attachment) bool {
	return a.Room == b.Room && a.Actor == b.Actor && a.ClientID == b.ClientID && a.Filename == b.Filename && a.MediaType == b.MediaType && a.Size == b.Size && a.SHA256 == b.SHA256
}

// beginMedia reserves quota without holding a database transaction over network I/O.
func (s *Store) beginMedia(m Attachment) (*mediaLease, error) {
	if e := validateAttachment(m); e != nil {
		return nil, e
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if e := s.legacyMember(m.Room, m.Actor); e != nil {
		return nil, e
	}
	key := mediaKey{m.Room, m.Actor, m.ClientID}
	if _, ok := s.uploads[key]; ok {
		return nil, ErrBusy
	}
	old, e := scanAttachment(s.db.QueryRow("SELECT "+mediaColumns+" FROM attachments WHERE room=? AND actor=? AND client_id=?", m.Room, m.Actor, m.ClientID))
	existing := e == nil
	if e != nil && e != sql.ErrNoRows {
		return nil, e
	}
	if existing && !sameUpload(old, m) {
		return nil, ErrConflict
	}
	reserved := int64(0)
	if !existing {
		var size int64
		var count int
		if e = s.db.QueryRow("SELECT COALESCE(SUM(size),0),COUNT(*) FROM attachments").Scan(&size, &count); e != nil {
			return nil, e
		}
		for _, lease := range s.uploads {
			if !lease.existing {
				size += lease.reserved
				count++
			}
		}
		if count >= MaxAttachments || m.Size > MaxMediaBytes-size {
			return nil, ErrLimit
		}
		reserved = m.Size
	}
	lease := &mediaLease{meta: m, epoch: s.mediaEpoch[[2]string{m.Room, m.Actor}], reserved: reserved, existing: existing}
	s.uploads[key] = lease
	return lease, nil
}
func (s *Store) releaseMedia(l *mediaLease) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := mediaKey{l.meta.Room, l.meta.Actor, l.meta.ClientID}
	if s.uploads[key] == l {
		delete(s.uploads, key)
	}
}
func (s *Store) mediaAuthorized(room, actor string, epoch uint64) error {
	if s.mediaEpoch[[2]string{room, actor}] != epoch {
		return ErrForbidden
	}
	return s.legacyMember(room, actor)
}
func (s *Store) checkMedia(l *mediaLease) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.mediaAuthorized(l.meta.Room, l.meta.Actor, l.epoch)
}
func (s *Store) finishMedia(l *mediaLease, body []byte) (Attachment, bool, error) {
	digest := sha256.Sum256(body)
	if int64(len(body)) != l.meta.Size || hex.EncodeToString(digest[:]) != l.meta.SHA256 {
		return Attachment{}, false, ErrIntegrity
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.uploads[mediaKey{l.meta.Room, l.meta.Actor, l.meta.ClientID}] != l {
		return Attachment{}, false, ErrInvalid
	}
	if e := s.mediaAuthorized(l.meta.Room, l.meta.Actor, l.epoch); e != nil {
		return Attachment{}, false, e
	}
	if l.existing {
		m, e := scanAttachment(s.db.QueryRow("SELECT "+mediaColumns+" FROM attachments WHERE room=? AND actor=? AND client_id=?", l.meta.Room, l.meta.Actor, l.meta.ClientID))
		if e != nil || !sameUpload(m, l.meta) || !validAttachmentID(m.ID) {
			return Attachment{}, false, ErrIntegrity
		}
		var stored []byte
		if e = s.db.QueryRow("SELECT payload FROM attachments WHERE room=? AND id=? AND length(payload)=?", m.Room, m.ID, m.Size).Scan(&stored); e != nil {
			return Attachment{}, false, ErrIntegrity
		}
		persistedDigest := sha256.Sum256(stored)
		if hex.EncodeToString(persistedDigest[:]) != m.SHA256 {
			return Attachment{}, false, ErrIntegrity
		}
		return m, false, nil
	}
	m := l.meta
	var e error
	m.ID, e = mediaID()
	if e != nil {
		return Attachment{}, false, e
	}
	m.CreatedMS = time.Now().UnixMilli()
	_, e = s.db.Exec("INSERT INTO attachments("+mediaColumns+",payload) VALUES(?,?,?,?,?,?,?,?,?,?)", m.ID, m.Room, m.Actor, m.ClientID, m.Filename, m.MediaType, m.Size, m.SHA256, m.CreatedMS, body)
	if e != nil {
		return Attachment{}, false, e
	}
	l.existing = true
	l.reserved = 0
	return m, true, nil
}

// loadMedia snapshots a complete immutable BLOB. Network writes use fresh ACL checks.
func (s *Store) loadMedia(room, actor, id string) (Attachment, []byte, uint64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if e := s.legacyMember(room, actor); e != nil {
		return Attachment{}, nil, 0, e
	}
	if !validAttachmentID(id) {
		return Attachment{}, nil, 0, ErrNotFound
	}
	m, e := scanAttachment(s.db.QueryRow("SELECT "+mediaColumns+" FROM attachments WHERE room=? AND id=?", room, id))
	if e == sql.ErrNoRows {
		return m, nil, 0, ErrNotFound
	}
	if e != nil {
		return m, nil, 0, e
	}
	// Check metadata before allocating from storage; unknown/corrupt data is not served.
	if e = validateAttachment(m); e != nil {
		return m, nil, 0, ErrIntegrity
	}
	var body []byte
	if e = s.db.QueryRow("SELECT payload FROM attachments WHERE room=? AND id=? AND length(payload)=?", room, id, m.Size).Scan(&body); e != nil {
		return m, nil, 0, ErrIntegrity
	}
	return m, body, s.mediaEpoch[[2]string{room, actor}], nil
}
func (s *Store) listMedia(room, actor string) ([]Attachment, error) {
	if e := s.legacyMember(room, actor); e != nil {
		return nil, e
	}
	rows, e := s.db.Query("SELECT "+mediaColumns+" FROM attachments WHERE room=? ORDER BY created_ms,id LIMIT 128", room)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := make([]Attachment, 0)
	for rows.Next() {
		m, e := scanAttachment(rows)
		if e != nil {
			return nil, e
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func privateDir(path string) error {
	st, e := os.Lstat(path)
	if e != nil {
		return e
	}
	if !st.IsDir() || st.Mode()&os.ModeSymlink != 0 || st.Mode().Perm() != 0700 || st.Sys().(*syscall.Stat_t).Uid != uint32(os.Geteuid()) {
		return fmt.Errorf("unsafe snapshot directory")
	}
	return nil
}
func inspectSnapshots(path string) error {
	if e := privateDir(path); e != nil {
		return e
	}
	entries, e := os.ReadDir(path)
	if e != nil {
		return e
	}
	for _, entry := range entries {
		name := entry.Name()
		prefix := "v1-before-media-"
		if strings.HasPrefix(name, "v2-before-mls-") {
			prefix = "v2-before-mls-"
		}
		if strings.HasPrefix(name, "v3-before-preparation-") {
			prefix = "v3-before-preparation-"
		}
		if strings.HasPrefix(name, "v4-before-successor-reservation-") {
			prefix = "v4-before-successor-reservation-"
		}
		if strings.HasPrefix(name, "v5-before-successor-custody-") {
			prefix = "v5-before-successor-custody-"
		}
		id := strings.TrimSuffix(strings.TrimPrefix(name, prefix), ".sqlite")
		if name != prefix+id+".sqlite" || !validAttachmentID(id) {
			return fmt.Errorf("unknown snapshot file preserved")
		}
		f, e := os.OpenFile(filepath.Join(path, name), os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
		if e != nil {
			return e
		}
		e = checkFile(f)
		f.Close()
		if e != nil {
			return e
		}
	}
	return nil
}

// A v1 source is backed up before the additive v2 transaction. Never overwrite
// a previous attempt; a partial snapshot from a failed attempt stays preserved.
func migrateMedia(db *sql.DB, dir string, fresh bool) error {
	if !fresh {
		if e := snapshotSchema(db, dir, "v1-before-media-"); e != nil {
			return e
		}
	}
	_, e := db.Exec(`BEGIN IMMEDIATE;
 CREATE TABLE attachments(id TEXT PRIMARY KEY,room TEXT NOT NULL REFERENCES rooms(id),actor TEXT NOT NULL,client_id TEXT NOT NULL,filename TEXT NOT NULL,media_type TEXT NOT NULL,size INTEGER NOT NULL CHECK(size BETWEEN 1 AND 8388608),sha256 TEXT NOT NULL,created_ms INTEGER NOT NULL,payload BLOB NOT NULL CHECK(length(payload)=size),UNIQUE(room,actor,client_id));
 PRAGMA user_version=2;
 COMMIT;`)
	return e
}

func snapshotSchema(db *sql.DB, dir, prefix string) error {

	snapshots := filepath.Join(dir, "snapshots")
	if e := os.Mkdir(snapshots, 0700); e != nil && !os.IsExist(e) {
		return e
	}
	if e := inspectSnapshots(snapshots); e != nil {
		return e
	}
	entries, e := os.ReadDir(snapshots)
	if e != nil {
		return e
	}
	attempts := 0
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), prefix) {
			attempts++
		}
	}
	if len(entries) >= 8 || attempts >= 4 {
		return fmt.Errorf("snapshot attempts exhausted; preserve and inspect recovery files")
	}
	id, e := mediaID()
	if e != nil {
		return e
	}
	path := filepath.Join(snapshots, prefix+id+".sqlite")
	f, e := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if e != nil {
		return e
	}
	defer f.Close()
	if e = checkFile(f); e != nil {
		return e
	}
	if _, e = db.Exec("VACUUM INTO ?", path); e != nil {
		return e
	}
	if e = f.Sync(); e != nil {
		return e
	}
	for _, p := range []string{snapshots, dir} {
		d, e := os.Open(p)
		if e != nil {
			return e
		}
		e = d.Sync()
		d.Close()
		if e != nil {
			return e
		}
	}
	return nil
}
