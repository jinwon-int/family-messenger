package chat

import (
	"bytes"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func mediaMeta(id string, body []byte) Attachment {
	h := sha256.Sum256(body)
	return Attachment{Room: "family", Actor: "alice", ClientID: id, Filename: "합성 파일.txt", MediaType: "text/plain", Size: int64(len(body)), SHA256: hex.EncodeToString(h[:])}
}
func putMedia(t *testing.T, s *Store, m Attachment, body []byte) (Attachment, bool, error) {
	t.Helper()
	l, e := s.beginMedia(m)
	if e != nil {
		return Attachment{}, false, e
	}
	defer s.releaseMedia(l)
	return s.finishMedia(l, body)
}
func upload(t *testing.T, h *httptest.Server, m Attachment, body io.Reader) *http.Response {
	t.Helper()
	r, e := http.NewRequest("POST", h.URL+"/v1/rooms/"+m.Room+"/attachments", body)
	if e != nil {
		t.Fatal(e)
	}
	r.ContentLength = m.Size
	r.Header.Set("Authorization", "Bearer synthetic-"+m.Actor)
	r.Header.Set("Content-Type", m.MediaType)
	r.Header.Set("X-Upload-ID", m.ClientID)
	r.Header.Set("X-File-Name", url.PathEscape(m.Filename))
	r.Header.Set("X-Content-SHA256", m.SHA256)
	resp, e := (&http.Client{Timeout: 5 * time.Second}).Do(r)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}
func TestMediaRetryIntegrityAndIsolation(t *testing.T) {
	s, h := fixture(t)
	body := []byte("synthetic attachment")
	meta := mediaMeta("retry", body)
	r := upload(t, h, meta, bytes.NewReader(body))
	if r.StatusCode != 201 {
		t.Fatal(r.StatusCode)
	}
	var m Attachment
	if e := json.NewDecoder(r.Body).Decode(&m); e != nil {
		t.Fatal(e)
	}
	r.Body.Close()
	r = upload(t, h, meta, bytes.NewReader(body))
	if r.StatusCode != 200 {
		t.Fatal(r.StatusCode)
	}
	var retry Attachment
	json.NewDecoder(r.Body).Decode(&retry)
	r.Body.Close()
	if retry != m {
		t.Fatal(m, retry)
	}
	conflict := meta
	conflict.Filename = "other.txt"
	status(t, upload(t, h, conflict, bytes.NewReader(body)), 409)
	wrong := append([]byte(nil), body...)
	wrong[0] = 'X'
	status(t, upload(t, h, meta, bytes.NewReader(wrong)), 422)
	path := "/v1/rooms/family/attachments/" + m.ID
	r = req(t, h, "GET", path, "bob", nil, nil)
	data, e := io.ReadAll(r.Body)
	r.Body.Close()
	if e != nil || !bytes.Equal(body, data) {
		t.Fatal(e)
	}
	if r.Header.Get("Content-Type") != "application/octet-stream" || !strings.HasPrefix(r.Header.Get("Content-Disposition"), "attachment;") || r.Header.Get("X-Content-SHA256") != m.SHA256 || r.Header.Get("Content-Security-Policy") == "" {
		t.Fatal(r.Header)
	}
	status(t, req(t, h, "GET", path, "charlie", nil, nil), 403)
	status(t, req(t, h, "GET", path, "", nil, nil), 401)
	status(t, req(t, h, "GET", path, "alice", nil, map[string]string{"Range": "bytes=0-1"}), 416)
	if e = s.CreateRoom("private", "bob", nil); e != nil {
		t.Fatal(e)
	}
	status(t, req(t, h, "GET", "/v1/rooms/private/attachments/"+m.ID, "bob", nil, nil), 404)
	status(t, req(t, h, "GET", "/v1/rooms/family/attachments", "charlie", nil, nil), 403)
	s.mu.Lock()
	ms, e := s.listMedia("family", "alice")
	s.mu.Unlock()
	if e != nil || len(ms) != 1 {
		t.Fatal(ms, e)
	}
}
func TestMediaUploadNoChatLockAndRevokeReadd(t *testing.T) {
	s, h := fixture(t)
	body := bytes.Repeat([]byte("x"), 64*1024)
	m := mediaMeta("held", body)
	reader, writer := io.Pipe()
	done := make(chan int, 1)
	request, _ := http.NewRequest("POST", h.URL+"/v1/rooms/family/attachments", reader)
	request.ContentLength = m.Size
	request.Header.Set("Authorization", "Bearer synthetic-alice")
	request.Header.Set("Content-Type", m.MediaType)
	request.Header.Set("X-Upload-ID", m.ClientID)
	request.Header.Set("X-File-Name", url.PathEscape(m.Filename))
	request.Header.Set("X-Content-SHA256", m.SHA256)
	go func() {
		response, e := (&http.Client{Timeout: 4 * time.Second}).Do(request)
		if e != nil {
			done <- 0
			return
		}
		done <- response.StatusCode
		response.Body.Close()
	}()
	if _, e := writer.Write(body[:1]); e != nil {
		t.Fatal(e)
	}
	until := time.Now().Add(time.Second)
	for {
		s.mu.Lock()
		active := len(s.uploads)
		s.mu.Unlock()
		if active == 1 {
			break
		}
		if time.Now().After(until) {
			t.Fatal("upload was not admitted")
		}
		time.Sleep(time.Millisecond)
	}
	// Upload is waiting for its body; normal chat and revocation remain available.
	start := time.Now()
	if _, _, e := s.Send("family", "bob", "during", []byte("chat")); e != nil {
		t.Fatal(e)
	}
	if time.Since(start) > time.Second {
		t.Fatal("upload holds chat lock")
	}
	if e := s.SetMember("family", "alice", "alice", false); !errors.Is(e, ErrInvalid) {
		t.Fatal(e)
	}
	// For the upload owner (alice), use a room owned by bob so it can be revoked.
	writer.Close()
	select {
	case code := <-done:
		if code != 400 && code != 0 {
			t.Fatal(code)
		}
	case <-time.After(4 * time.Second):
		t.Fatal("interrupted upload hung")
	}
	if e := s.CreateRoom("bob-room", "bob", []string{"alice"}); e != nil {
		t.Fatal(e)
	}
	m.Room = "bob-room"
	l, e := s.beginMedia(m)
	if e != nil {
		t.Fatal(e)
	}
	defer s.releaseMedia(l)
	s.SetMember("bob-room", "bob", "alice", false)
	s.SetMember("bob-room", "bob", "alice", true)
	if _, _, e = s.finishMedia(l, body); !errors.Is(e, ErrForbidden) {
		t.Fatal("old lease revived", e)
	}
	s.mu.Lock()
	ms, e := s.listMedia("family", "alice")
	s.mu.Unlock()
	if e != nil || len(ms) != 0 {
		t.Fatal(ms, e)
	}
}
func TestMediaReservationsAndLimits(t *testing.T) {
	s := testStore(t)
	room(t, s)
	m := mediaMeta("active", []byte("x"))
	l, e := s.beginMedia(m)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.beginMedia(m); !errors.Is(e, ErrBusy) {
		t.Fatal(e)
	}
	s.releaseMedia(l)
	// Reserve the entire byte budget without receiving any body.
	var leases []*mediaLease
	for i := 0; i < 16; i++ {
		r := m
		r.ClientID = fmt.Sprint(i)
		r.Size = MaxAttachment
		l, e := s.beginMedia(r)
		if e != nil {
			t.Fatal(e)
		}
		leases = append(leases, l)
	}
	if _, e = s.beginMedia(m); !errors.Is(e, ErrLimit) {
		t.Fatal(e)
	}
	for _, l := range leases {
		s.releaseMedia(l)
	}
	if _, _, e = putMedia(t, s, m, []byte("x")); e != nil {
		t.Fatal(e)
	}
	for _, change := range []func(*Attachment){func(m *Attachment) { m.Size = MaxAttachment + 1 }, func(m *Attachment) { m.Size = -1 }, func(m *Attachment) { m.Filename = "../outside" }, func(m *Attachment) { m.Filename = "a\r\nheader" }, func(m *Attachment) { m.Filename = "\u202eevil" }, func(m *Attachment) { m.SHA256 = "bogus" }, func(m *Attachment) { m.MediaType = "text/plain; charset=utf-8" }} {
		bad := m
		change(&bad)
		if _, e = s.beginMedia(bad); !errors.Is(e, ErrInvalid) {
			t.Fatal(bad, e)
		}
	}
	for i := 1; i < MaxAttachments; i++ {
		m.ClientID = fmt.Sprint(i)
		if _, _, e = putMedia(t, s, m, []byte("x")); e != nil {
			t.Fatal(e)
		}
	}
	m.ClientID = "full"
	if _, e = s.beginMedia(m); !errors.Is(e, ErrLimit) {
		t.Fatal(e)
	}
	m.ClientID = "active"
	if _, created, e := putMedia(t, s, m, []byte("x")); e != nil || created {
		t.Fatal(created, e)
	}
}
func TestMediaDownloadCorruptionFailsBeforeBody(t *testing.T) {
	s, h := fixture(t)
	m, _, e := putMedia(t, s, mediaMeta("bad", []byte("abc")), []byte("abc"))
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.db.Exec("UPDATE attachments SET payload=? WHERE id=?", []byte("xyz"), m.ID); e != nil {
		t.Fatal(e)
	}
	status(t, req(t, h, "GET", "/v1/rooms/family/attachments/"+m.ID, "bob", nil, nil), 422)
}
func makeV1(t *testing.T, dir string) {
	t.Helper()
	path := filepath.Join(dir, "messages.sqlite")
	f, e := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
	if e != nil {
		t.Fatal(e)
	}
	f.Close()
	db, e := sql.Open("sqlite3", sqliteURI(path))
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	_, e = db.Exec(`CREATE TABLE rooms(id TEXT PRIMARY KEY,owner TEXT NOT NULL,next_seq INTEGER NOT NULL DEFAULT 1);
 CREATE TABLE members(room TEXT NOT NULL REFERENCES rooms(id),actor TEXT NOT NULL,PRIMARY KEY(room,actor));
 CREATE TABLE messages(room TEXT NOT NULL REFERENCES rooms(id),seq INTEGER NOT NULL,actor TEXT NOT NULL,client_id TEXT NOT NULL,payload BLOB NOT NULL,created_ms INTEGER NOT NULL,PRIMARY KEY(room,seq),UNIQUE(room,actor,client_id));
 INSERT INTO rooms VALUES('family','alice',2);INSERT INTO members VALUES('family','alice');INSERT INTO members VALUES('family','bob');
 INSERT INTO messages VALUES('family',1,'alice','before',X'78',123);
 PRAGMA application_id=1179471188;PRAGMA user_version=1;`)
	if e != nil {
		t.Fatal(e)
	}
}
func TestMediaMigrationSnapshotAndReopen(t *testing.T) {
	dir := t.TempDir()
	os.Chmod(dir, 0700)
	makeV1(t, dir)
	s, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	ms, e := s.History("family", "bob", 0)
	if e != nil || len(ms) != 1 || ms[0].ClientID != "before" {
		t.Fatal(ms, e)
	}
	m, _, e := putMedia(t, s, mediaMeta("after", []byte("file")), []byte("file"))
	if e != nil {
		t.Fatal(e)
	}
	s.Close()
	entries, e := os.ReadDir(filepath.Join(dir, "snapshots"))
	if e != nil || len(entries) != 1 {
		t.Fatal(entries, e)
	}
	snapshot := filepath.Join(dir, "snapshots", entries[0].Name())
	db, e := sql.Open("sqlite3", sqliteURI(snapshot))
	if e != nil {
		t.Fatal(e)
	}
	var version int
	var integrity, client string
	db.QueryRow("PRAGMA user_version").Scan(&version)
	db.QueryRow("PRAGMA integrity_check").Scan(&integrity)
	db.QueryRow("SELECT client_id FROM messages").Scan(&client)
	db.Close()
	if version != 1 || integrity != "ok" || client != "before" {
		t.Fatal(version, integrity, client)
	}
	s, e = Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	got, body, _, e := s.loadMedia("family", "bob", m.ID)
	if e != nil || got != m || string(body) != "file" {
		t.Fatal(got, e)
	}
	entries, _ = os.ReadDir(filepath.Join(dir, "snapshots"))
	if len(entries) != 1 {
		t.Fatal("snapshot repeated")
	}
}
func TestMediaUnsafeSnapshotPreservation(t *testing.T) {
	for _, kind := range []string{"symlink-dir", "mode-dir", "foreign-file", "symlink-file", "hardlink-file"} {
		t.Run(kind, func(t *testing.T) {
			base := t.TempDir()
			os.Chmod(base, 0700)
			dir := filepath.Join(base, "state")
			os.Mkdir(dir, 0700)
			makeV1(t, dir)
			outside := filepath.Join(base, "outside")
			os.WriteFile(outside, []byte("preserved"), 0600)
			snapshots := filepath.Join(dir, "snapshots")
			if kind == "symlink-dir" {
				os.Symlink(base, snapshots)
			} else {
				os.Mkdir(snapshots, 0700)
				file := filepath.Join(snapshots, "v1-before-media-"+strings.Repeat("a", 32)+".sqlite")
				switch kind {
				case "mode-dir":
					os.Chmod(snapshots, 0755)
				case "foreign-file":
					os.WriteFile(filepath.Join(snapshots, "foreign"), nil, 0600)
				case "symlink-file":
					os.Symlink(outside, file)
				case "hardlink-file":
					os.Link(outside, file)
				}
			}
			if s, e := Open(dir); e == nil {
				s.Close()
				t.Fatal("unsafe snapshot accepted")
			}
			b, e := os.ReadFile(outside)
			if e != nil || string(b) != "preserved" {
				t.Fatal("outside changed")
			}
		})
	}
}

type gatedMediaWriter struct {
	header           http.Header
	body             bytes.Buffer
	entered, release chan struct{}
	first            bool
}

func (w *gatedMediaWriter) Header() http.Header              { return w.header }
func (w *gatedMediaWriter) WriteHeader(int)                  {}
func (w *gatedMediaWriter) Flush()                           {}
func (w *gatedMediaWriter) SetWriteDeadline(time.Time) error { return nil }
func (w *gatedMediaWriter) Write(b []byte) (int, error) {
	if !w.first {
		w.first = true
		close(w.entered)
		<-w.release
	}
	return w.body.Write(b)
}
func TestMediaDownloadRevocationStopsNextChunk(t *testing.T) {
	s := testStore(t)
	room(t, s)
	body := bytes.Repeat([]byte("x"), 128*1024)
	m, _, e := putMedia(t, s, mediaMeta("chunked", body), body)
	if e != nil {
		t.Fatal(e)
	}
	a := NewHandler(s).(*API)
	w := &gatedMediaWriter{header: make(http.Header), entered: make(chan struct{}), release: make(chan struct{})}
	done := make(chan struct{})
	go func() { a.downloadMedia(w, httptest.NewRequest("GET", "/", nil), "family", "bob", m.ID); close(done) }()
	select {
	case <-w.entered:
	case <-time.After(time.Second):
		t.Fatal("no initial write")
	}
	revoked := make(chan error, 1)
	go func() { revoked <- s.SetMember("family", "alice", "bob", false) }()
	// Allow the revoker to queue behind the one bounded write; Go's mutex hands
	// off to a waiting revocation before the downloader's next permission check.
	time.Sleep(15 * time.Millisecond)
	close(w.release)
	select {
	case e := <-revoked:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(time.Second):
		t.Fatal("revocation blocked")
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("download did not stop")
	}
	if w.body.Len() != 32*1024 {
		t.Fatal("bytes written after revocation", w.body.Len())
	}
}
