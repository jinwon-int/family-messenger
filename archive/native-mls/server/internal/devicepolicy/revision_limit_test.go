package devicepolicy

import (
	"errors"
	"strings"
	"testing"
)

// TestRevisionSpaceBoundary (#421): the chain commits every revision up to
// MaxDevicePolicyRevisions, refuses the next one with a policy_revisions
// LimitError that wraps ErrDevicePolicyState (the relay maps it to 500
// device_policy_unavailable), leaves the chain untouched, and a freshly opened
// store still reads the full chain at the limit. Each commit toggles the
// registrar role of one active device — a legal transition that never consumes
// a device record, so the walk reaches the limit itself.
func TestRevisionSpaceBoundary(t *testing.T) {
	if MaxDevicePolicyRevisions < 256 {
		t.Fatalf("MaxDevicePolicyRevisions %d: #421 plan B raised it to 256", MaxDevicePolicyRevisions)
	}
	dir := testDir(t)
	s := mustOpen(t, dir)
	if _, e := s.Init(); e != nil {
		t.Fatal(e)
	}
	devices := outOfBand(t, "dev", 1)
	info, e := s.Commit(1, set(devices...))
	if e != nil {
		t.Fatal(e)
	}
	toggle := func() {
		if len(devices[0].Roles) == 0 {
			devices[0].Roles = []string{RoleRegistrar}
		} else {
			devices[0].Roles = nil
		}
	}
	for info.Revision < MaxDevicePolicyRevisions {
		toggle()
		next, e := s.Commit(info.Revision, set(devices...))
		if e != nil {
			t.Fatalf("commit on revision %d: %v", info.Revision, e)
		}
		if next.Revision != info.Revision+1 {
			t.Fatalf("revision %d after %d", next.Revision, info.Revision)
		}
		info = next
	}
	last := info

	toggle()
	_, e = s.Commit(MaxDevicePolicyRevisions, set(devices...))
	var limit *LimitError
	if !errors.As(e, &limit) || !errors.Is(e, ErrDevicePolicyState) {
		t.Fatalf("commit past the limit: got %v", e)
	}
	if limit.Limit != LimitPolicyRevisions || limit.Current != MaxDevicePolicyRevisions+1 || limit.Max != MaxDevicePolicyRevisions {
		t.Fatalf("limit error %+v", *limit)
	}
	if !strings.Contains(e.Error(), "policy revision space exhausted at 256") {
		t.Fatalf("message: %v", e)
	}

	got, _, e := mustOpen(t, dir).Read()
	if e != nil {
		t.Fatalf("a full chain must still open: %v", e)
	}
	if got.Revision != MaxDevicePolicyRevisions || got.SHA256 != last.SHA256 {
		t.Fatalf("chain after the refused commit: revision %d sha %s, want %d %s", got.Revision, got.SHA256, last.Revision, last.SHA256)
	}
}
