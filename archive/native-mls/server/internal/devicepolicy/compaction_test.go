package devicepolicy

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// Compaction (#421 plan A): a checkpoint revision carries the device set
// unchanged, replay starts there, numbering keeps growing, and the older
// revisions move to an archive outside the chain directory.

// chainOf builds a chain of `head` revisions (genesis, one enrollment, then
// registrar-role toggles) and returns the store, its directory and the live set.
func chainOf(t *testing.T, head uint64) (*DevicePolicyStore, string, []DeviceV4) {
	t.Helper()
	dir := testDir(t)
	s := mustOpen(t, dir)
	if _, e := s.Init(); e != nil {
		t.Fatal(e)
	}
	devices := outOfBand(t, "dev", 2)
	info, e := s.Commit(1, set(devices...))
	if e != nil {
		t.Fatal(e)
	}
	for info.Revision < head {
		toggleRole(devices)
		if info, e = s.Commit(info.Revision, set(devices...)); e != nil {
			t.Fatalf("commit on %d: %v", info.Revision, e)
		}
	}
	return s, dir, devices
}

func toggleRole(devices []DeviceV4) {
	if len(devices[0].Roles) == 0 {
		devices[0].Roles = []string{RoleRegistrar}
	} else {
		devices[0].Roles = nil
	}
}

func chainFiles(t *testing.T, dir string) []string {
	t.Helper()
	entries, e := os.ReadDir(dir)
	if e != nil {
		t.Fatal(e)
	}
	var out []string
	for _, ent := range entries {
		if strings.HasPrefix(ent.Name(), "policy-") {
			out = append(out, ent.Name())
		}
	}
	sort.Strings(out)
	return out
}

func archiveRoot(t *testing.T) string {
	t.Helper()
	return filepath.Join(testDir(t), "policy-archive")
}

func TestCompactKeepsNumberingAndDeviceSet(t *testing.T) {
	s, dir, devices := chainOf(t, 5)
	_, before := mustRead(t, s)
	root := archiveRoot(t)

	res, e := s.Compact(5, root)
	if e != nil {
		t.Fatal(e)
	}
	if !res.Created || res.Checkpoint.Revision != 6 || len(res.Archived) != 5 {
		t.Fatalf("result %+v", res)
	}
	if got := chainFiles(t, dir); len(got) != 1 || got[0] != "policy-000006.json" {
		t.Fatalf("chain directory after compaction: %v", got)
	}
	if res.ArchiveDir != filepath.Join(root, "revisions-000001-000005") {
		t.Fatalf("archive dir %q", res.ArchiveDir)
	}
	if got := chainFiles(t, res.ArchiveDir); len(got) != 5 || got[0] != "policy-000001.json" || got[4] != "policy-000005.json" {
		t.Fatalf("archived files: %v", got)
	}
	st, e := os.Stat(res.ArchiveDir)
	if e != nil || st.Mode().Perm() != 0o700 {
		t.Fatalf("archive dir mode: %v %v", st, e)
	}

	// A fresh store replays from the checkpoint: same head, same device set.
	info, after := mustRead(t, mustOpen(t, dir))
	if info != res.Checkpoint {
		t.Fatalf("read %+v want %+v", info, res.Checkpoint)
	}
	if !approvalEqualPolicy(before, after) {
		t.Fatalf("device set changed across the checkpoint")
	}

	// Numbering keeps growing; a stale CAS on the pre-checkpoint head is a conflict.
	toggleRole(devices)
	if _, e := s.Commit(5, set(devices...)); !errors.Is(e, ErrDevicePolicyConflict) {
		t.Fatalf("stale expected revision 5: %v", e)
	}
	next, e := s.Commit(6, set(devices...))
	if e != nil || next.Revision != 7 {
		t.Fatalf("commit after checkpoint: %+v %v", next, e)
	}
	if info, _ := mustRead(t, mustOpen(t, dir)); info != next {
		t.Fatalf("reopened %+v want %+v", info, next)
	}
}

func TestCompactRestoresRevisionSpace(t *testing.T) {
	s, dir, devices := chainOf(t, MaxDevicePolicyRevisions)
	toggleRole(devices)
	if _, e := s.Commit(MaxDevicePolicyRevisions, set(devices...)); !errors.Is(e, ErrDevicePolicyState) {
		t.Fatalf("full chain accepted a commit: %v", e)
	}
	res, e := s.Compact(MaxDevicePolicyRevisions, archiveRoot(t))
	if e != nil {
		t.Fatalf("compacting an exhausted chain: %v", e)
	}
	base := res.Checkpoint.Revision
	if base != MaxDevicePolicyRevisions+1 || len(res.Archived) != MaxDevicePolicyRevisions {
		t.Fatalf("result base %d archived %d", base, len(res.Archived))
	}
	info, e := s.Commit(base, set(devices...))
	if e != nil || info.Revision != base+1 {
		t.Fatalf("commit after compaction: %+v %v", info, e)
	}
	if got := chainFiles(t, dir); len(got) != 2 {
		t.Fatalf("chain files: %v", got)
	}
}

// An interrupted move leaves a contiguous prefix ending at the checkpoint's
// predecessor: still a valid chain, and compacting the same head again only
// finishes the move. A gap in the prefix fails closed.
func TestCompactInterruptedMove(t *testing.T) {
	s, dir, _ := chainOf(t, 5)
	root := archiveRoot(t)
	res, e := s.Compact(5, root)
	if e != nil {
		t.Fatal(e)
	}
	moveBack := func(names ...string) {
		for _, n := range names {
			if e := os.Rename(filepath.Join(res.ArchiveDir, n), filepath.Join(dir, n)); e != nil {
				t.Fatal(e)
			}
		}
	}
	moveBack("policy-000003.json", "policy-000004.json", "policy-000005.json")
	info, _ := mustRead(t, mustOpen(t, dir))
	if info != res.Checkpoint {
		t.Fatalf("prefix 3..5 + checkpoint: %+v", info)
	}
	again, e := s.Compact(6, root)
	if e != nil || again.Created || len(again.Archived) != 3 || again.ArchiveDir != filepath.Join(root, "revisions-000003-000005") {
		t.Fatalf("finishing the move: %+v %v", again, e)
	}
	if got := chainFiles(t, dir); len(got) != 1 {
		t.Fatalf("chain files: %v", got)
	}
	// Nothing left to move: a no-op, not an error.
	if res, e := s.Compact(6, root); e != nil || res.Created || len(res.Archived) != 0 {
		t.Fatalf("idle compact: %+v %v", res, e)
	}

	// A gap below the checkpoint (3 and 5 back, 4 missing) fails closed.
	res2 := again
	for _, n := range []string{"policy-000003.json", "policy-000005.json"} {
		if e := os.Rename(filepath.Join(res2.ArchiveDir, n), filepath.Join(dir, n)); e != nil {
			t.Fatal(e)
		}
	}
	if _, _, e := mustOpen(t, dir).Read(); !errors.Is(e, ErrDevicePolicyState) {
		t.Fatalf("gap in the prefix accepted: %v", e)
	}
}

// The checkpoint must link to its predecessor's bytes and keep its device set.
func TestCheckpointMustLinkAndKeepTheSet(t *testing.T) {
	s, dir, _ := chainOf(t, 3)
	res, e := s.Compact(3, archiveRoot(t))
	if e != nil {
		t.Fatal(e)
	}
	// Bring revision 3 back, then alter it: the checkpoint no longer links to it.
	src := filepath.Join(res.ArchiveDir, "policy-000003.json")
	b, e := os.ReadFile(src)
	if e != nil {
		t.Fatal(e)
	}
	altered := filepath.Join(dir, "policy-000003.json")
	if e := os.WriteFile(altered, append(b[:len(b)-1], ' ', '\n'), 0o600); e != nil {
		t.Fatal(e)
	}
	if _, _, e := mustOpen(t, dir).Read(); !errors.Is(e, ErrDevicePolicyState) {
		t.Fatalf("checkpoint linked to altered predecessor: %v", e)
	}
	if e := os.Remove(altered); e != nil {
		t.Fatal(e)
	}

	// A checkpoint whose device set differs from the predecessor still present fails closed.
	s2, dir2, devices := chainOf(t, 3)
	_ = s2
	cp := devices
	toggleRole(cp)
	d, e := devicePrivateDir(dir2)
	if e != nil {
		t.Fatal(e)
	}
	defer d.Close()
	chain, e := devicePolicyChain(d)
	if e != nil {
		t.Fatal(e)
	}
	var info DevicePolicyInfo
	if e := writeDevicePolicyRevision(d, 4, chain.info.SHA256, set(cp...), true, &info); e != nil {
		t.Fatal(e)
	}
	if _, _, e := mustOpen(t, dir2).Read(); !errors.Is(e, ErrDevicePolicyState) {
		t.Fatalf("checkpoint changed the device set: %v", e)
	}
}

// Without a checkpoint the chain must still begin at genesis.
func TestChainWithoutCheckpointStartsAtGenesis(t *testing.T) {
	_, dir, _ := chainOf(t, 3)
	if e := os.Remove(filepath.Join(dir, "policy-000001.json")); e != nil {
		t.Fatal(e)
	}
	if _, _, e := mustOpen(t, dir).Read(); !errors.Is(e, ErrDevicePolicyState) {
		t.Fatalf("headless chain accepted: %v", e)
	}
}

func TestCompactArchiveMustBeOutsideTheChain(t *testing.T) {
	s, dir, _ := chainOf(t, 2)
	for _, bad := range []string{dir, filepath.Join(dir, "archive"), "relative/archive", dir + "/../x/./y"} {
		if _, e := s.Compact(2, bad); !errors.Is(e, ErrDevicePolicyConfig) {
			t.Fatalf("archive %q accepted: %v", bad, e)
		}
	}
	if _, e := s.Compact(1, archiveRoot(t)); !errors.Is(e, ErrDevicePolicyConflict) {
		t.Fatalf("stale expected revision accepted: %v", e)
	}
	if got := chainFiles(t, dir); len(got) != 2 {
		t.Fatalf("refused compactions changed the chain: %v", got)
	}
}

// Ordinary records stay byte-identical: "checkpoint" is omitted when false.
func TestOrdinaryRecordsOmitCheckpoint(t *testing.T) {
	_, dir, _ := chainOf(t, 2)
	b, e := os.ReadFile(filepath.Join(dir, "policy-000002.json"))
	if e != nil {
		t.Fatal(e)
	}
	if strings.Contains(string(b), "checkpoint") {
		t.Fatalf("ordinary record carries checkpoint: %s", b)
	}
}

// #421 acceptance: a 64-revision synthetic chain compacts to the same active set
// and fingerprints; the documented rollback (NATIVE-RELAY-OPERATIONS §d2: move
// the archive back, set the checkpoint aside — only while nothing was committed
// after it) restores the exact pre-compaction chain; after compacting again an
// enrollment commits normally.
func TestCompactAcceptanceRollbackAndEnroll(t *testing.T) {
	s, dir, devices := chainOf(t, 64)
	pre, prePolicy := mustRead(t, s)
	active := func(p PolicyWire4) map[string]string {
		m := map[string]string{}
		for _, d := range p.Devices {
			if d.Status == StatusActive {
				m[d.ID] = d.Fingerprint
			}
		}
		return m
	}
	root := archiveRoot(t)
	res, e := s.Compact(64, root)
	if e != nil {
		t.Fatal(e)
	}
	_, post := mustRead(t, mustOpen(t, dir))
	if a, b := active(prePolicy), active(post); len(a) != 2 || len(a) != len(b) || a[devices[0].ID] != b[devices[0].ID] || a[devices[1].ID] != b[devices[1].ID] {
		t.Fatalf("active set changed: %v -> %v", a, b)
	}

	// Rollback: archive back, checkpoint aside (outside the chain directory).
	for _, name := range res.Archived {
		if e := os.Rename(filepath.Join(res.ArchiveDir, name), filepath.Join(dir, name)); e != nil {
			t.Fatal(e)
		}
	}
	aside := filepath.Join(testDir(t), "policy-000065.json.rolled-back")
	if e := os.Rename(filepath.Join(dir, "policy-000065.json"), aside); e != nil {
		t.Fatal(e)
	}
	back, backPolicy := mustRead(t, mustOpen(t, dir))
	if back != pre || !approvalEqualPolicy(prePolicy, backPolicy) {
		t.Fatalf("rollback: %+v want %+v", back, pre)
	}

	// Compact again (a new archive subdirectory), then enroll a new actor's first device.
	if e := os.RemoveAll(res.ArchiveDir); e != nil {
		t.Fatal(e)
	}
	if res, e = s.Compact(64, root); e != nil || res.Checkpoint.Revision != 65 {
		t.Fatalf("second compaction: %+v %v", res, e)
	}
	next := append(append([]DeviceV4{}, devices...), outOfBand(t, "new", 1)...)
	info, e := s.Commit(65, set(next...))
	if e != nil || info.Revision != 66 {
		t.Fatalf("enroll after compaction: %+v %v", info, e)
	}
	_, final := mustRead(t, mustOpen(t, dir))
	if got := active(final); len(got) != 3 {
		t.Fatalf("active after enroll: %v", got)
	}
}
