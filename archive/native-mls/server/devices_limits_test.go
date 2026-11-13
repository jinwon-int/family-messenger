// Device policy limit logging (#421): a size-limit rejection reaches the log
// as `limit=<name> current=<n> max=<m>` (no ids) while the 400 bad_candidate
// body stays as it was, and loading or committing a chain near its revision
// or active-device limit logs a warning.
package main

import (
	"bytes"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/jinwon-int/family-messenger/archive/native-mls/server/internal/devicepolicy"
)

func TestPolicyLimitRejectionIsLogged(t *testing.T) {
	_, srv, st, iss := selfServiceRelay(t)
	ka := enrollFirstKeyed(t, st, "alice-iphone", "alice", "subject-alice", false) // revision 2, registrar
	alice := iss.mint("subject-alice", nil)
	var buf bytes.Buffer
	captureLog(t, &buf)
	approve := func(id string, base uint64) (int, []byte) {
		ev := signAddEvidence(t, ka, newRealKey(t), id, "alice", "subject-alice", base)
		return doAuth(t, srv, "POST", "/v2/devices/approvals", mustJSON(t, ev), alice)
	}
	base := uint64(2)
	for i := 1; i < devicepolicy.MaxActivePerActor; i++ {
		if code, raw := approve(fmt.Sprintf("alice-dev-%d", i), base); code != http.StatusCreated {
			t.Fatalf("approve %d: %d %s", i, code, raw)
		}
		base++
	}
	if strings.Contains(buf.String(), "rejected by policy limit") {
		t.Fatalf("limit line before any rejection:\n%s", buf.String())
	}
	code, raw := approve("alice-dev-over", base)
	if code != http.StatusBadRequest || errField(t, raw) != "bad_candidate" {
		t.Fatalf("fifth active device: %d %s", code, raw)
	}
	want := fmt.Sprintf("devices: rejected by policy limit: limit=active_per_actor current=%d max=%d",
		devicepolicy.MaxActivePerActor+1, devicepolicy.MaxActivePerActor)
	var line string
	for _, l := range strings.Split(buf.String(), "\n") {
		if strings.Contains(l, "rejected by policy limit") {
			line = l
		}
	}
	if !strings.HasSuffix(line, want) {
		t.Fatalf("limit line = %q, want suffix %q\nlog:\n%s", line, want, buf.String())
	}
	if strings.Contains(line, "alice") || strings.Contains(line, "subject") {
		t.Fatalf("limit line names a device, actor or subject: %q", line)
	}
}

func TestPolicyHeadroomWarnings(t *testing.T) {
	var buf bytes.Buffer
	captureLog(t, &buf)
	set := func(active, revoked int) []devicepolicy.DeviceV4 {
		out := make([]devicepolicy.DeviceV4, 0, active+revoked)
		for i := 0; i < active; i++ {
			out = append(out, devicepolicy.DeviceV4{Status: devicepolicy.StatusActive})
		}
		for i := 0; i < revoked; i++ {
			out = append(out, devicepolicy.DeviceV4{Status: devicepolicy.StatusRevoked})
		}
		return out
	}
	// Below both thresholds — tombstones do not count as active.
	logPolicyHeadroom(47, set(23, 40))
	if buf.Len() != 0 {
		t.Fatalf("below thresholds logged:\n%s", buf.String())
	}
	logPolicyHeadroom(48, set(23, 0))
	if got := buf.String(); !strings.Contains(got, "devices: WARNING policy near limit: limit=policy_revisions current=48 max=64") ||
		strings.Contains(got, "limit=active_devices") {
		t.Fatalf("revision 48 only:\n%s", got)
	}
	buf.Reset()
	logPolicyHeadroom(47, set(24, 11))
	if got := buf.String(); !strings.Contains(got, "devices: WARNING policy near limit: limit=active_devices current=24 max=32") ||
		strings.Contains(got, "limit=policy_revisions") {
		t.Fatalf("24 active only:\n%s", got)
	}
}
