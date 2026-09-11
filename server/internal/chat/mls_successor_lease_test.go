package chat

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"github.com/jinwon-int/family-messenger/server/internal/access"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func leaseKey(n byte) ed25519.PrivateKey { return ed25519.NewKeyFromSeed(bytes.Repeat([]byte{n}, 32)) }
func leaseMLSFixture(t *testing.T) (*Store, *access.Authority, access.Config, *httptest.Server, func(string, string, string, any, string, int) []byte) {
	t.Helper()
	s, a, c, k, server := accessFixture(t)
	for i, p := range c.People {
		key := leaseKey(byte(i + 1)).Public().(ed25519.PublicKey)
		sum := sha256.Sum256(key)
		c.Devices = append(c.Devices, access.Device{ID: p.Actor + "-first", Actor: p.Actor, Subject: p.Subject, SigningKey: hex.EncodeToString(key), Fingerprint: hex.EncodeToString(sum[:]), Status: "active", Revision: 1, Acceptance: "out-of-band-fingerprint"})
	}
	if e := a.Replace(c); e != nil {
		t.Fatal(e)
	}
	call := func(sub, method, path string, q any, device string, want int) []byte {
		t.Helper()
		var body []byte
		if q != nil {
			body, _ = json.Marshal(q)
		}
		token := assertion(t, c, k, sub, time.Now().Add(time.Minute))
		status, b := accessRequest(t, server, token, method, path, body, map[string]string{"X-Family-Device": device})
		if status != want {
			t.Fatalf("%s %s status%d want%d: %s", method, path, status, want, b)
		}
		return b
	}
	return s, a, c, server, call
}
func leaseContextFixture(t *testing.T, mutate ...func(*access.Config)) (*Store, *access.Authority, access.Config, func(string, string, string, any, string, int) []byte) {
	t.Helper()
	s, a, c, _, call := leaseMLSFixture(t)
	group := "abababababababababababababababab"
	call("owner", "POST", "/v1/mls/rooms", mlsCreate{"source", group, "alice-first", "bob-first"}, "alice-first", 201)
	for _, q := range []MLSRequest{
		{"kp", "bob-first", group, "key_package", 0, 0, "alice-first", []byte("public fixture")},
		{"welcome", "alice-first", group, "welcome", 1, 0, "bob-first", []byte("opaque fixture")},
		{"ack", "bob-first", group, "ack", 2, 1, "alice-first", []byte{}},
	} {
		s.mu.Lock()
		room, _ := s.mlsRoom("source")
		_, _, e := s.appendMLS(room, q)
		s.mu.Unlock()
		if e != nil {
			t.Fatal(e)
		}
	}
	key := leaseKey(9).Public().(ed25519.PublicKey)
	sum := sha256.Sum256(key)
	now := time.Now().Unix()
	c.Devices[0].Status = "revoked"
	c.Devices[0].Revision = 2
	c.Successors = &access.SuccessorPolicy{Administrators: []access.DeviceAdministrator{{Subject: "family", Actor: "bob"}}, Intents: []access.SuccessorIntent{{ID: "replace-one", Action: "replace", Actor: "alice", Subject: "owner", Predecessor: "alice-first", PredecessorKey: c.Devices[0].SigningKey, PredecessorRevision: 1, Candidate: "alice-next", SigningKey: hex.EncodeToString(key), Fingerprint: hex.EncodeToString(sum[:]), PackageSHA256: digestMLS(handshakePackage), PreviousRoom: "source", PreviousGroup: group, NextRoom: "target", Administrator: access.DeviceAdministrator{Subject: "family", Actor: "bob"}, Acceptance: "out-of-band-fingerprint", BaseRevision: 2, CreatedAt: now - 2, ExpiresAt: now + 120, Status: "accepted", DecidedAt: now - 1, DecisionRevision: 4}}}
	for _, change := range mutate {
		change(&c)
	}
	if e := a.Replace(c); e != nil {
		t.Fatal(e)
	}
	return s, a, c, call
}

const leasePath = "/v1/mls/successors/replace-one/lease"
const channelPath = "/v1/mls/successors/replace-one/channel"

func leaseReady(t *testing.T) (*Store, *access.Authority, access.Config, successorReservation, []leaseApproval, func(string, string, string, any, string, int) []byte) {
	s, a, c, call := leaseContextFixture(t)
	p, qs := confirmationReady(t, call)
	call("owner", "GET", leasePath, nil, "alice-next", 403)
	call("owner", "POST", confirmationPath, qs[0], "alice-next", 201)
	call("family", "POST", confirmationPath, qs[1], "bob-first", 201)
	var v successorLease
	if json.Unmarshal(call("owner", "GET", leasePath, nil, "alice-next", 200), &v) != nil {
		t.Fatal("decode")
	}
	return s, a, c, p, []leaseApproval{{"candidate", ed25519.Sign(leaseKey(9), leaseFrame(v, "candidate"))}, {"peer", ed25519.Sign(leaseKey(2), leaseFrame(v, "peer"))}}, call
}
func TestSuccessorLeasePairSignaturesActualScopeAndRetry(t *testing.T) {
	s, a, c, p, qs, call := leaseReady(t)
	before := call("owner", "GET", successorReservationPath, nil, "alice-next", 200)
	call("owner", "GET", channelPath, nil, "alice-next", 403)
	for _, q := range []leaseApproval{{"candidate", qs[1].Signature}, {"candidate", make([]byte, 64)}, {"peer", qs[0].Signature}} {
		call("owner", "POST", leasePath, q, "alice-next", 403)
	}
	call("family", "POST", leasePath, qs[0], "bob-first", 403)
	call("owner", "POST", leasePath, map[string]any{"role": "candidate", "signature": []int{1, 2}}, "alice-next", 400)
	for i, q := range qs {
		who, dev := "owner", "alice-next"
		if i == 1 {
			who, dev = "family", "bob-first"
		}
		call(who, "POST", leasePath, q, dev, 201)
		call(who, "POST", leasePath, q, dev, 200)
		if i == 0 {
			call(who, "GET", channelPath, nil, dev, 403)
		}
	}
	q := leaseMessage{"one", "alice-next", []byte("opaque actual application")}
	first := call("owner", "POST", channelPath, q, "alice-next", 201)
	if !bytes.Equal(first, call("owner", "POST", channelPath, q, "alice-next", 200)) {
		t.Fatal("retry")
	}
	q.Payload = []byte("changed")
	call("owner", "POST", channelPath, q, "alice-next", 409)
	call("family", "POST", channelPath, q, "bob-first", 403)
	call("owner", "GET", channelPath, nil, "alice-first", 403)
	call("family", "POST", channelPath, leaseMessage{"two", "bob-first", []byte("response")}, "bob-first", 201)
	var history []leaseEvent
	json.Unmarshal(call("owner", "GET", channelPath, nil, "alice-next", 200), &history)
	if len(history) != 2 {
		t.Fatal(history)
	}
	for _, path := range []string{"/v1/mls/rooms/target/log", "/v1/rooms/target/messages"} {
		call("owner", "GET", path, nil, "alice-next", 403)
	}
	if !bytes.Equal(before, call("owner", "GET", successorReservationPath, nil, "alice-next", 200)) {
		t.Fatal("reservation changed")
	}
	for _, d := range c.Devices {
		if d.ID == p.Context.Candidate.ID {
			t.Fatal("global admission")
		}
	}
	c.Devices[1].Status = "revoked"
	c.Devices[1].Revision = 2
	if e := a.Replace(c); e != nil {
		t.Fatal(e)
	}
	call("owner", "GET", channelPath, nil, "alice-next", 403)
	events, e := s.leaseHistory(p)
	if e != nil || len(events) != 2 {
		t.Fatal("revocation lost history", e)
	}
}
func TestSuccessorLeaseConcurrentApprovalsCorruptionExpiry(t *testing.T) {
	s, _, _, p, qs, _ := leaseReady(t)
	var wg sync.WaitGroup
	created := 0
	for n := 0; n < 16; n++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			s.mu.Lock()
			defer s.mu.Unlock()
			pin := p.Context.Candidate
			if i == 1 {
				pin = p.Context.Peer
			}
			_, new, e := s.approveLease(p, pin.Actor, pin.ID, qs[i])
			if e != nil {
				t.Error(e)
			}
			if new {
				created++
			}
		}(n % 2)
	}
	wg.Wait()
	if created != 2 {
		t.Fatal(created)
	}
	v, raw, e := s.successorLease(p)
	if e != nil || v.Phase != "leased" {
		t.Fatal(v, e)
	}
	bad := v
	bad.Group = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
	if validLeaseApproval(p, bad, qs[0]) {
		t.Fatal("cross-group signature")
	}
	s.db.Exec("UPDATE mls_successor_leases SET approvals=?", []byte("[] "))
	if _, _, e = s.successorLease(p); e != ErrIntegrity {
		t.Fatal(e)
	}
	s.db.Exec("UPDATE mls_successor_leases SET approvals=?", raw)
	expired := p
	expired.Context.ExpiresAt = 1
	if _, _, e = s.appendLeaseMessage(expired, leaseMessage{"expired", "alice-next", []byte("x")}); e != ErrForbidden {
		t.Fatal(e)
	}
	s.db.Exec("DELETE FROM mls_successor_enrollments WHERE intent=?", p.Context.Intent)
	s.db.Exec("DELETE FROM mls_successor_retirements WHERE intent=?", p.Context.Intent)
	s.db.Exec("DELETE FROM mls_successor_leases WHERE intent=?", p.Context.Intent)
	if _, _, e = s.successorLease(p); e != ErrIntegrity {
		t.Fatal(e)
	}
}
