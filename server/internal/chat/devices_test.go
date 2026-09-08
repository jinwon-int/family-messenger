package chat

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"github.com/jinwon-int/family-messenger/server/internal/access"
	"testing"
	"time"
)

func TestDeviceDirectoryAdmissionAndRevocation(t *testing.T) {
	s, a, c, k, server := accessFixture(t)
	if e := s.CreateRoom("family", "alice", []string{"bob"}); e != nil {
		t.Fatal(e)
	}
	for i, p := range c.People {
		key := bytes.Repeat([]byte{byte(i + 1)}, 32)
		h := sha256.Sum256(key)
		c.Devices = append(c.Devices, access.Device{ID: p.Actor + "-first", Actor: p.Actor, Subject: p.Subject, SigningKey: hex.EncodeToString(key), Fingerprint: hex.EncodeToString(h[:]), Status: "active", Revision: 1, Acceptance: "out-of-band-fingerprint"})
	}
	if e := a.Replace(c); e != nil {
		t.Fatal(e)
	}
	token := func(sub string) string { return assertion(t, c, k, sub, time.Now().Add(time.Minute)) }
	owner, bob, outsider := token("owner"), token("family"), token("outsider")
	call := func(tok, method, path string, want int) []byte {
		t.Helper()
		status, b := accessRequest(t, server, tok, method, path, nil, nil)
		if status != want {
			t.Fatalf("status%d want%d", status, want)
		}
		return b
	}
	out := call(bob, "GET", "/v1/rooms/family/devices", 200)
	if !bytes.Contains(out, []byte("alice-first")) || !bytes.Contains(out, []byte("bob-first")) || bytes.Contains(out, []byte("charlie")) || bytes.Contains(out, []byte("subject")) {
		t.Fatal("directory scope leak")
	}
	call(outsider, "GET", "/v1/rooms/family/devices", 403)
	call(owner, "GET", "/v1/rooms/missing/devices", 403)
	call(owner, "GET", "/v1/rooms/family/devices?actor=charlie", 400)
	call(owner, "POST", "/v1/rooms/family/devices", 404)
	call(bob, "POST", "/v1/fleet/run", 404)
	c.Devices[1].Status = "revoked"
	c.Devices[1].Revision = 2
	if e := a.Replace(c); e != nil {
		t.Fatal(e)
	}
	out = call(owner, "GET", "/v1/rooms/family/devices", 200)
	if !bytes.Contains(out, []byte(`"status":"revoked"`)) {
		t.Fatal("revocation omitted")
	}
	if e := s.SetMember("family", "alice", "bob", false); e != nil {
		t.Fatal(e)
	}
	call(bob, "GET", "/v1/rooms/family/devices", 403)
	out = call(owner, "GET", "/v1/rooms/family/devices", 200)
	if bytes.Contains(out, []byte("bob-first")) {
		t.Fatal("removed member key exposed")
	}
	expired := assertion(t, c, k, "owner", time.Now().Add(-time.Second))
	call(expired, "GET", "/v1/rooms/family/devices", 401)
}
