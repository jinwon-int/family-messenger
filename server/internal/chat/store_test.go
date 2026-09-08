package chat

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func testStore(t *testing.T) *Store {
	t.Helper()
	dir := t.TempDir()
	if e := os.Chmod(dir, 0700); e != nil {
		t.Fatal(e)
	}
	s, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { s.Close() })
	return s
}
func room(t *testing.T, s *Store) {
	t.Helper()
	if e := s.CreateRoom("family", "alice", []string{"bob"}); e != nil {
		t.Fatal(e)
	}
}

func TestDurableIdempotencyAndMembership(t *testing.T) {
	dir := t.TempDir()
	os.Chmod(dir, 0700)
	s, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	room(t, s)
	m, created, e := s.Send("family", "alice", "retry", []byte("synthetic"))
	if e != nil || !created || m.Seq != 1 {
		t.Fatalf("%+v %v %v", m, created, e)
	}
	if e = s.SetMember("family", "alice", "bob", false); e != nil {
		t.Fatal(e)
	}
	if e = s.Close(); e != nil {
		t.Fatal(e)
	}
	s, e = Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	got, created, e := s.Send("family", "alice", "retry", []byte("synthetic"))
	if e != nil || created || got.Seq != m.Seq || got.CreatedMS != m.CreatedMS {
		t.Fatalf("retry: %+v %v %v", got, created, e)
	}
	if _, _, e = s.Send("family", "alice", "retry", []byte("changed")); !errors.Is(e, ErrConflict) {
		t.Fatal(e)
	}
	if _, e = s.History("family", "bob", 0); !errors.Is(e, ErrForbidden) {
		t.Fatal("revocation lost", e)
	}
	if _, _, e = s.Send("family", "bob", "retry", []byte("x")); !errors.Is(e, ErrForbidden) {
		t.Fatal(e)
	}
	ms, e := s.History("family", "alice", 0)
	if e != nil || len(ms) != 1 {
		t.Fatal(ms, e)
	}
}

func TestConcurrentSequenceAndRetry(t *testing.T) {
	s := testStore(t)
	room(t, s)
	var wg sync.WaitGroup
	for i := 0; i < 40; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			id := fmt.Sprint(i / 2)
			if _, _, e := s.Send("family", "alice", id, []byte("same")); e != nil {
				t.Error(e)
			}
		}(i)
	}
	wg.Wait()
	ms, e := s.History("family", "bob", 0)
	if e != nil || len(ms) != 20 {
		t.Fatalf("len=%d %v", len(ms), e)
	}
	for i, m := range ms {
		if m.Seq != int64(i+1) {
			t.Fatal("sequence gap", m)
		}
	}
	if _, created, e := s.Send("family", "bob", "0", []byte("different actor")); e != nil || !created {
		t.Fatal(created, e)
	}
}

func TestRoomACLAndPayloadLimits(t *testing.T) {
	s := testStore(t)
	room(t, s)
	if e := s.CreateRoom("family", "bob", nil); !errors.Is(e, ErrConflict) {
		t.Fatal(e)
	}
	if e := s.CreateRoom("bad/room", "alice", nil); !errors.Is(e, ErrInvalid) {
		t.Fatal(e)
	}
	if e := s.CreateRoom("unknown", "alice", []string{"admin"}); !errors.Is(e, ErrInvalid) {
		t.Fatal(e)
	}
	if e := s.SetMember("family", "bob", "charlie", true); !errors.Is(e, ErrForbidden) {
		t.Fatal(e)
	}
	if e := s.SetMember("family", "alice", "alice", false); !errors.Is(e, ErrInvalid) {
		t.Fatal(e)
	}
	for _, actor := range []string{"charlie", "nobody"} {
		if _, e := s.History("family", actor, 0); !errors.Is(e, ErrForbidden) {
			t.Fatal(e)
		}
	}
	for _, b := range [][]byte{nil, make([]byte, MaxPayload+1)} {
		if _, _, e := s.Send("family", "alice", "id", b); !errors.Is(e, ErrInvalid) {
			t.Fatal(e)
		}
	}
	if _, _, e := s.Send("family", "alice", "../id", []byte("x")); !errors.Is(e, ErrInvalid) {
		t.Fatal(e)
	}
	if _, _, e := s.Send("family", "alice", "maximum", make([]byte, MaxPayload)); e != nil {
		t.Fatal(e)
	}
	if _, e := s.History("family", "alice", 2); !errors.Is(e, ErrInvalid) {
		t.Fatal(e)
	}
	if _, e := s.History("family", "alice", -1); !errors.Is(e, ErrInvalid) {
		t.Fatal(e)
	}
}

func TestHistoryPaginationAndRoomIsolation(t *testing.T) {
	s := testStore(t)
	room(t, s)
	if e := s.CreateRoom("other", "alice", nil); e != nil {
		t.Fatal(e)
	}
	for i := 0; i < 105; i++ {
		if _, _, e := s.Send("family", "alice", fmt.Sprint(i), []byte("x")); e != nil {
			t.Fatal(e)
		}
	}
	ms, e := s.History("family", "bob", 0)
	if e != nil || len(ms) != 100 {
		t.Fatal(len(ms), e)
	}
	ms, e = s.History("family", "bob", ms[99].Seq)
	if e != nil || len(ms) != 5 || ms[0].Seq != 101 {
		t.Fatal(ms, e)
	}
	m, _, e := s.Send("other", "alice", "0", []byte("y"))
	if e != nil || m.Seq != 1 {
		t.Fatal(m, e)
	}
	if _, e = s.History("other", "bob", 0); !errors.Is(e, ErrForbidden) {
		t.Fatal(e)
	}
}

func TestStateSafetyAndLock(t *testing.T) {
	s := testStore(t)
	var filename string
	if e := s.db.QueryRow("SELECT file FROM pragma_database_list WHERE name='main'").Scan(&filename); e != nil {
		t.Fatal(e)
	}
	if other, e := Open(filepath.Dir(filename)); e == nil {
		other.Close()
		t.Fatal("double open")
	}
	st, e := os.Stat(filename)
	if e != nil || st.Mode().Perm() != 0600 {
		t.Fatal(st, e)
	}
}

func TestRejectUnsafeState(t *testing.T) {
	for _, kind := range []string{"directory-mode", "database-mode", "database-symlink", "journal-symlink", "lock-symlink", "hardlink", "unexpected", "ancestor-symlink"} {
		t.Run(kind, func(t *testing.T) {
			base := t.TempDir()
			os.Chmod(base, 0700)
			dir := filepath.Join(base, "state")
			os.Mkdir(dir, 0700)
			outside := filepath.Join(base, "outside")
			os.WriteFile(outside, []byte("preserve me"), 0600)
			switch kind {
			case "directory-mode":
				os.Chmod(dir, 0755)
			case "database-mode":
				os.WriteFile(filepath.Join(dir, "messages.sqlite"), nil, 0644)
			case "database-symlink":
				os.Symlink(outside, filepath.Join(dir, "messages.sqlite"))
			case "journal-symlink":
				os.Symlink(outside, filepath.Join(dir, "messages.sqlite-journal"))
			case "lock-symlink":
				os.Symlink(outside, filepath.Join(dir, "lock"))
			case "hardlink":
				os.Link(outside, filepath.Join(dir, "messages.sqlite"))
			case "unexpected":
				os.WriteFile(filepath.Join(dir, "unrelated"), nil, 0600)
			case "ancestor-symlink":
				link := filepath.Join(base, "link")
				os.Symlink(dir, link)
				dir = link
			}
			if s, e := Open(dir); e == nil {
				s.Close()
				t.Fatal("unsafe path accepted")
			}
			b, e := os.ReadFile(outside)
			if e != nil || string(b) != "preserve me" {
				t.Fatal("outside data changed")
			}
		})
	}
}

func TestSQLitePathEscaping(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state?mode=memory&other #")
	os.Mkdir(dir, 0700)
	s, e := Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	room(t, s)
	s.Close()
	s, e = Open(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	if _, e = s.History("family", "alice", 0); e != nil {
		t.Fatal(e)
	}
}

func TestCapacityPreservesHistoryAndRetries(t *testing.T) {
	s := testStore(t)
	room(t, s)
	original, _, e := s.Send("family", "alice", "original", []byte("x"))
	if e != nil {
		t.Fatal(e)
	}
	_, e = s.db.Exec(`WITH RECURSIVE n(x) AS (SELECT 2 UNION ALL SELECT x+1 FROM n WHERE x<10000)
 INSERT INTO messages SELECT 'family',x,'alice',CAST(x AS TEXT),X'78',0 FROM n; UPDATE rooms SET next_seq=10001 WHERE id='family';`)
	if e != nil {
		t.Fatal(e)
	}
	if _, _, e = s.Send("family", "alice", "overflow", []byte("x")); !errors.Is(e, ErrLimit) {
		t.Fatal(e)
	}
	if got, created, e := s.Send("family", "alice", "original", []byte("x")); e != nil || created || got.Seq != original.Seq {
		t.Fatal(got, created, e)
	}
	if ms, e := s.History("family", "bob", 9999); e != nil || len(ms) != 1 || ms[0].Seq != 10000 {
		t.Fatal(ms, e)
	}
	for i := 0; i < 31; i++ {
		if e = s.CreateRoom(fmt.Sprint(i), "alice", nil); e != nil {
			t.Fatal(e)
		}
	}
	if e = s.CreateRoom("overflow", "alice", nil); !errors.Is(e, ErrLimit) {
		t.Fatal(e)
	}
}

func TestUnknownDatabaseIsUnchanged(t *testing.T) {
	dir := t.TempDir()
	os.Chmod(dir, 0700)
	path := filepath.Join(dir, "messages.sqlite")
	body := make([]byte, 4096)
	copy(body, []byte("SQLite format 3\x00"))
	if e := os.WriteFile(path, body, 0600); e != nil {
		t.Fatal(e)
	}
	if s, e := Open(dir); e == nil {
		s.Close()
		t.Fatal("foreign database accepted")
	}
	got, e := os.ReadFile(path)
	if e != nil || string(got) != string(body) {
		t.Fatal("foreign database modified", e)
	}
}
