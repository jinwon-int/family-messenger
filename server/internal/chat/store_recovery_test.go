package chat

import (
	"database/sql"
	"encoding/binary"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// The raw database header can differ from the page restored by a hot journal.
// Check both schema 9 (the previous guard) and schema 10 after real recovery.
func TestRecoveredDatabaseIdentity(t *testing.T) {
	for _, version := range []int{9, 10} {
		t.Run(strconv.Itoa(version), func(t *testing.T) {
			dir := t.TempDir()
			if err := os.Chmod(dir, 0700); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(dir, "messages.sqlite")
			cmd := exec.Command(os.Args[0], "-test.run=^TestRecoveryJournalFixture$")
			cmd.Env = append(os.Environ(), "FAMILY_RECOVERY_FIXTURE="+path, "FAMILY_RECOVERY_VERSION="+strconv.Itoa(version))
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("fixture: %v %s", err, out)
			}
			before, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if binary.BigEndian.Uint32(before[68:72]) != 1179471188 {
				t.Fatal("fixture header not recognized")
			}
			journal, err := os.Stat(path + "-journal")
			if err != nil || journal.Size() == 0 {
				t.Fatal("missing hot journal", err)
			}
			s, err := Open(dir)
			if err == nil {
				s.Close()
				t.Fatal("accepted recovered foreign application identity")
			}
			if !strings.Contains(err.Error(), "not a synthetic messenger database") {
				t.Fatalf("wrong rejection: %v", err)
			}
			after, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if binary.BigEndian.Uint32(after[68:72]) != 1234567 || binary.BigEndian.Uint32(after[60:64]) != uint32(version) {
				t.Fatal("fixture did not exercise SQLite rollback recovery")
			}
		})
	}
}

func TestRecoveryJournalFixture(t *testing.T) {
	path := os.Getenv("FAMILY_RECOVERY_FIXTURE")
	if path == "" {
		return
	}
	version, err := strconv.Atoi(os.Getenv("FAMILY_RECOVERY_VERSION"))
	if err != nil || (version != 9 && version != 10) {
		t.Fatal("invalid fixture version")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if err = f.Close(); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	execSQL := func(q string, args ...any) {
		t.Helper()
		if _, e := db.Exec(q, args...); e != nil {
			t.Fatal(e)
		}
	}
	execSQL(fmt.Sprintf(`PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;
PRAGMA cache_size=1; PRAGMA application_id=1234567; PRAGMA user_version=%d;
CREATE TABLE pads(id INTEGER PRIMARY KEY, data BLOB);`, version))
	for i := 0; i < 24; i++ {
		execSQL("INSERT INTO pads(data) VALUES(zeroblob(32768))")
	}
	execSQL("BEGIN IMMEDIATE; PRAGMA application_id=1179471188;")
	for i := 1; i <= 24; i++ {
		execSQL("UPDATE pads SET data=? WHERE id=?", strings.Repeat("y", 32768), i)
	}
	// Model the crash window after the new page-one marker reaches disk and
	// before SQLite invalidates its actual rollback journal. Abrupt exit keeps
	// the journal hot; the parent must reject the identity restored from it.
	f, err = os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	marker := make([]byte, 4)
	binary.BigEndian.PutUint32(marker, 1179471188)
	if _, err = f.WriteAt(marker, 68); err != nil {
		t.Fatal(err)
	}
	if err = f.Sync(); err != nil {
		t.Fatal(err)
	}
	if err = f.Close(); err != nil {
		t.Fatal(err)
	}
	os.Exit(0)
}
