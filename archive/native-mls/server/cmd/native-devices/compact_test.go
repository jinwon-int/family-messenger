package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

type compactView struct {
	Revision   uint64   `json:"revision"`
	SHA256     string   `json:"sha256"`
	Created    bool     `json:"checkpoint_created"`
	Archived   []string `json:"archived"`
	ArchiveDir string   `json:"archive_dir"`
}

// TestCLICompact (#421 plan A): -compact writes a checkpoint at the next
// revision, moves the older revisions to policy-archive next to -device-state,
// keeps the device set, and is idempotent once the move is done.
func TestCLICompact(t *testing.T) {
	dir := cliDir(t)
	state := filepath.Join(dir, "policy")
	k := newCLIKey(t)
	runOK(t, "-device-state", state, "-init")
	cand := cliCandidate(t, cliDir(t), "a1.json", enrollCandidate{DeviceID: "dev-a1", Actor: "alice", Subject: "person-alice", SigningKey: k.hexKey})
	before := runOK(t, "-device-state", state, "-enroll-first", "-input", cand, "-expected-revision", "1")

	compact := func(args ...string) compactView {
		t.Helper()
		var out bytes.Buffer
		if e := run(append([]string{"-device-state", state, "-compact"}, args...), &out); e != nil {
			t.Fatalf("compact %v: %v", args, e)
		}
		var v compactView
		if e := json.Unmarshal(out.Bytes(), &v); e != nil {
			t.Fatalf("output %q: %v", out.String(), e)
		}
		return v
	}
	v := compact("-expected-revision", "2")
	want := filepath.Join(dir, "policy-archive", "revisions-000001-000002")
	if v.Revision != 3 || !v.Created || len(v.Archived) != 2 || v.ArchiveDir != want {
		t.Fatalf("compact result %+v", v)
	}
	for _, name := range v.Archived {
		if _, e := os.Stat(filepath.Join(want, name)); e != nil {
			t.Fatalf("archived %s: %v", name, e)
		}
	}
	after := runOK(t, "-device-state", state, "-inspect")
	if after.Revision != 3 || after.SHA256 != v.SHA256 || !reflect.DeepEqual(after.Devices, before.Devices) {
		t.Fatalf("inspect after compact %+v (before %+v)", after, before)
	}
	// Idempotent once the move is done.
	if again := compact("-expected-revision", "3"); again.Created || len(again.Archived) != 0 || again.Revision != 3 {
		t.Fatalf("second compact %+v", again)
	}
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"-compact"}, "require -expected-revision"},
		{[]string{"-compact", "-expected-revision", "2"}, "expected 2"},
		{[]string{"-inspect", "-policy-archive", "/tmp/x"}, "-policy-archive applies only to -compact"},
		{[]string{"-compact", "-expected-revision", "3", "-policy-archive", "rel/dir"}, "absolute"},
	} {
		if e := run(append([]string{"-device-state", state}, c.args...), &bytes.Buffer{}); e == nil || !strings.Contains(e.Error(), c.want) {
			t.Fatalf("run(%v) err = %v, want %q", c.args, e, c.want)
		}
	}
}
