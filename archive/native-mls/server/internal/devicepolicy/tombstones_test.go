package devicepolicy

// #421 minimal fix: revoked records (tombstones) no longer count toward the
// 32-device cap. They stay in the set — id/key reuse stays forbidden and every
// approved_by still resolves — but enrollment is bounded by active devices
// (MaxActiveDevicesTotal) plus a separate whole-set bound (MaxDeviceRecords).

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
)

// outOfBand returns n active first devices, one per actor, ids/actors prefixed by tag.
func outOfBand(t *testing.T, tag string, n int) []DeviceV4 {
	t.Helper()
	out := make([]DeviceV4, 0, n)
	for i := 0; i < n; i++ {
		k := newKey(t)
		out = append(out, k.device(fmt.Sprintf("%s-%02d", tag, i), fmt.Sprintf("%s%02d", tag, i), "person-"+tag, AcceptanceOutOfBand, StatusActive, 1, nil))
	}
	return out
}

func revoked(d DeviceV4) DeviceV4 {
	d.Status, d.Revision = StatusRevoked, 2
	return d
}

func TestTombstonesDoNotCountTowardActiveCap(t *testing.T) {
	devices := outOfBand(t, "live", MaxActiveDevicesTotal)
	for _, d := range outOfBand(t, "gone", 40) {
		devices = append(devices, revoked(d))
	}
	if e := validateDeviceSet(devices); e != nil {
		t.Fatalf("32 active + 40 tombstones must be valid: %v", e)
	}
}

func TestActiveCapStillBounds(t *testing.T) {
	devices := outOfBand(t, "live", MaxActiveDevicesTotal+1)
	e := validateDeviceSet(devices)
	if !errors.Is(e, ErrDevicePolicyConfig) || !strings.Contains(e.Error(), "too many active devices") {
		t.Fatalf("33 active devices: got %v", e)
	}
}

func TestRecordCapBoundsTheWholeSet(t *testing.T) {
	live := outOfBand(t, "live", MaxActiveDevicesTotal)
	gone := outOfBand(t, "gone", MaxDeviceRecords-MaxActiveDevicesTotal+1)
	devices := append([]DeviceV4(nil), live...)
	for _, d := range gone[:len(gone)-1] {
		devices = append(devices, revoked(d))
	}
	if e := validateDeviceSet(devices); e != nil {
		t.Fatalf("exactly %d records must be valid: %v", MaxDeviceRecords, e)
	}
	devices = append(devices, revoked(gone[len(gone)-1]))
	e := validateDeviceSet(devices)
	if !errors.Is(e, ErrDevicePolicyConfig) || !strings.Contains(e.Error(), "too many device records") {
		t.Fatalf("%d records: got %v", MaxDeviceRecords+1, e)
	}
}

// TestMaxDeviceRecordsFitPolicyBytes pins MaxDeviceRecords to the file budget:
// a full set of worst-case records (every identifier at its maximum length,
// approved_by and roles present) must still pass the write-path size check, or a
// legal commit could produce a revision that writeDevicePolicyRevision refuses.
func TestMaxDeviceRecordsFitPolicyBytes(t *testing.T) {
	pad := func(prefix string, i, n int) string {
		s := fmt.Sprintf("%s%03d", prefix, i)
		return s + strings.Repeat("x", n-len(s))
	}
	devices := make([]DeviceV4, 0, MaxDeviceRecords)
	for i := 0; i < MaxDeviceRecords; i++ {
		k := newKey(t)
		devices = append(devices, DeviceV4{
			ID: pad("d", i, 64), Actor: pad("a", i, 64), Subject: pad("s", i, 128),
			SigningKey: k.hexKey, Fingerprint: k.fp, Status: StatusRevoked, Revision: 2,
			Acceptance: AcceptanceTrusted, ApprovedBy: &DeviceApproval{DeviceID: pad("p", i, 64), Revision: MaxDevicePolicyRevisions},
			Roles: []string{RoleRegistrar},
		})
	}
	sha := strings.Repeat("f", 64)
	data, e := json.Marshal(PolicyRecord4{Revision: MaxDevicePolicyRevisions, Previous: sha, PolicySHA256: sha, Policy: set(devices...)})
	if e != nil {
		t.Fatal(e)
	}
	if len(data)+1 > MaxDevicePolicyBytes {
		t.Fatalf("%d worst-case records encode to %d bytes > %d", MaxDeviceRecords, len(data)+1, MaxDevicePolicyBytes)
	}
	t.Logf("%d worst-case records: %d of %d bytes", MaxDeviceRecords, len(data)+1, MaxDevicePolicyBytes)
}

// TestEnrollAfterTombstonesFillTheOldCap replays the 2026-11-06 production state
// (rev 44: 32 records, 11 revoked) through the store: the next enrollment used to
// fail with "too many devices: 33 > 32"; it must now commit, and a revoked id
// still cannot come back.
func TestEnrollAfterTombstonesFillTheOldCap(t *testing.T) {
	s := mustOpen(t, testDir(t))
	if _, e := s.Init(); e != nil {
		t.Fatal(e)
	}
	devices := outOfBand(t, "dev", 32)
	if _, e := s.Commit(1, set(devices...)); e != nil {
		t.Fatal(e)
	}
	for i := 0; i < 11; i++ {
		devices[i] = revoked(devices[i])
	}
	info, e := s.Commit(2, set(devices...))
	if e != nil {
		t.Fatal(e)
	}
	if info.Revision != 3 {
		t.Fatalf("revision %d", info.Revision)
	}
	fresh := outOfBand(t, "new", 1)[0]
	if _, e := s.Commit(3, set(append(append([]DeviceV4(nil), devices...), fresh)...)); e != nil {
		t.Fatalf("enrollment with 32 records (11 tombstones) must succeed now: %v", e)
	}
	current := readCurrent(t, s)
	if len(current) != 33 {
		t.Fatalf("records %d", len(current))
	}
	// A tombstone still blocks reuse of its id (and key).
	k := newKey(t)
	reuse := k.device(devices[0].ID, "someone-else", "person-x", AcceptanceOutOfBand, StatusActive, 1, nil)
	if _, e := s.Commit(4, set(append(append([]DeviceV4(nil), current...), reuse)...)); !errors.Is(e, ErrDevicePolicyConfig) {
		t.Fatalf("reusing a revoked id: got %v", e)
	}
	sameKey := devices[1]
	sameKey.ID, sameKey.Actor, sameKey.Status, sameKey.Revision = "new-key-reuse", "keyreuse", StatusActive, 1
	if _, e := s.Commit(4, set(append(append([]DeviceV4(nil), current...), sameKey)...)); !errors.Is(e, ErrDevicePolicyConfig) {
		t.Fatalf("reusing a revoked signing key: got %v", e)
	}
}

// #421 rejection logging: each set limit names itself and the count it was
// refused at through LimitError, while the error text and the sentinel mapping
// (bad_candidate on the relay) stay what they were.
func TestLimitErrorsNameTheLimit(t *testing.T) {
	sameActor := outOfBand(t, "one", MaxActivePerActor+1)
	for i := range sameActor {
		sameActor[i].Actor = "one"
	}
	records := outOfBand(t, "live", MaxActiveDevicesTotal)
	for _, d := range outOfBand(t, "gone", MaxDeviceRecords-MaxActiveDevicesTotal+1) {
		records = append(records, revoked(d))
	}
	cases := []struct {
		name    string
		devices []DeviceV4
		limit   string
		current int
		max     int
		text    string
	}{
		{"active total", outOfBand(t, "live", MaxActiveDevicesTotal+1), LimitActiveDevices, MaxActiveDevicesTotal + 1, MaxActiveDevicesTotal,
			fmt.Sprintf("too many active devices: %d > %d: %v", MaxActiveDevicesTotal+1, MaxActiveDevicesTotal, ErrDevicePolicyConfig)},
		{"records", records, LimitDeviceRecords, MaxDeviceRecords + 1, MaxDeviceRecords,
			fmt.Sprintf("too many device records: %d > %d: %v", MaxDeviceRecords+1, MaxDeviceRecords, ErrDevicePolicyConfig)},
		{"per actor", sameActor, LimitActivePerActor, MaxActivePerActor + 1, MaxActivePerActor,
			fmt.Sprintf("actor %q exceeds %d active devices: %v", "one", MaxActivePerActor, ErrDevicePolicyConfig)},
	}
	for _, c := range cases {
		e := validateDeviceSet(c.devices)
		var le *LimitError
		if !errors.As(e, &le) || !errors.Is(e, ErrDevicePolicyConfig) {
			t.Fatalf("%s: got %v", c.name, e)
		}
		if le.Limit != c.limit || le.Current != c.current || le.Max != c.max {
			t.Fatalf("%s: LimitError = %+v, want %s %d/%d", c.name, *le, c.limit, c.current, c.max)
		}
		if e.Error() != c.text {
			t.Fatalf("%s: message changed: %q, want %q", c.name, e.Error(), c.text)
		}
	}
}
