package access

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func deviceFixture() Device {
	key := bytes.Repeat([]byte{42}, 32)
	hash := sha256.Sum256(key)
	return Device{"alice-first", "alice", "person-1", hex.EncodeToString(key), hex.EncodeToString(hash[:]), "active", 1, "out-of-band-fingerprint"}
}
func TestDeviceImmutableHistoryAndRestart(t *testing.T) {
	s, c := storePolicy(t)
	first, e := s.Commit(0, c)
	if e != nil {
		t.Fatal(e)
	}
	old, _ := os.ReadFile(filepath.Join(s.dir, revisionName(1)))
	c.Devices = []Device{deviceFixture()}
	if _, e = s.Commit(first.Revision, c); e != nil {
		t.Fatal(e)
	}
	for _, change := range []func(*Config){
		func(c *Config) { c.Devices = nil }, func(c *Config) { c.Devices[0].ID = "replacement" },
		func(c *Config) { c.Devices[0].Actor = "bob"; c.Devices[0].Subject = "person-2" },
		func(c *Config) { d := c.Devices[0]; d.ID = "second"; c.Devices = append(c.Devices, d) },
		func(c *Config) { c.Devices[0].Acceptance = "login-only" },
		func(c *Config) { c.Devices[0].Fingerprint = "bad" },
		func(c *Config) { c.People = c.People[1:] },
	} {
		next := c
		next.Devices = append([]Device(nil), c.Devices...)
		change(&next)
		if _, e = s.Commit(2, next); e == nil {
			t.Fatal("unsafe device transition accepted")
		}
	}
	c.Devices[0].Status = "revoked"
	c.Devices[0].Revision = 2
	if _, e = s.Commit(2, c); e != nil {
		t.Fatal(e)
	}
	m, e := OpenManaged(s.dir)
	if e != nil {
		t.Fatal("restart revoked", e)
	}
	defer m.Close()
	if len(m.Authority.config.Devices) != 1 || m.Authority.config.Devices[0].Status != "revoked" {
		t.Fatal("revocation lost")
	}
	c.Devices[0].Status = "active"
	c.Devices[0].Revision = 1
	if _, e = s.Commit(3, c); e == nil {
		t.Fatal("revoked device reactivated")
	}
	unchanged, _ := os.ReadFile(filepath.Join(s.dir, revisionName(1)))
	if !bytes.Equal(old, unchanged) {
		t.Fatal("legacy policy rewritten")
	}
}
func TestDeviceConcurrentRevocationAndRetiredSnapshot(t *testing.T) {
	s, c := storePolicy(t)
	c.Devices = []Device{deviceFixture()}
	_, e := s.Commit(0, c)
	if e != nil {
		t.Fatal(e)
	}
	m, e := OpenManaged(s.dir)
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	_, k := fixture(t)
	g, e := verify(m.Authority, sign(t, values(c), k))
	if e != nil {
		t.Fatal(e)
	}
	exposed := g.DeviceBindings()
	exposed[0].Status = "revoked"
	if g.DeviceBindings()[0].Status != "active" {
		t.Fatal("snapshot alias")
	}
	next := c
	next.Devices = append([]Device(nil), c.Devices...)
	next.Devices[0].Status = "revoked"
	next.Devices[0].Revision = 2
	var wg sync.WaitGroup
	out := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); other, _ := OpenPolicyStore(s.dir); _, e := other.Commit(1, next); out <- e }()
	}
	wg.Wait()
	close(out)
	success, conflict := 0, 0
	for e := range out {
		if e == nil {
			success++
		} else if e == ErrPolicyConflict {
			conflict++
		} else {
			t.Fatal(e)
		}
	}
	if success != 1 || conflict != 1 {
		t.Fatal("CAS failed")
	}
	if e = m.Refresh(); e != nil {
		t.Fatal(e)
	}
	if g.Run(func() error { t.Fatal("old device snapshot admitted"); return nil }) != ErrDenied {
		t.Fatal("grant not retired")
	}
	if e = m.Authority.Replace(c); e == nil {
		t.Fatal("live resurrection")
	}
}
func TestDeviceStrictPolicyFieldsAndHistoryTampering(t *testing.T) {
	s, c := storePolicy(t)
	c.Devices = []Device{deviceFixture()}
	b, e := EncodePolicy(c)
	if e != nil {
		t.Fatal(e)
	}
	for _, bad := range [][]byte{bytes.Replace(b, []byte(`"device_id"`), []byte(`"Device_id"`), 1), bytes.Replace(b, []byte(`"status":"active"`), []byte(`"status":"active","status":"revoked"`), 1), bytes.Replace(b, []byte(`"device_revision":1`), []byte(`"device_revision":null`), 1)} {
		if _, e = ParsePolicy(bad); e == nil {
			t.Fatal("ambiguous device JSON accepted")
		}
	}
	_, e = s.Commit(0, c)
	if e != nil {
		t.Fatal(e)
	}
	c.Devices[0].Status = "revoked"
	c.Devices[0].Revision = 2
	_, e = s.Commit(1, c)
	if e != nil {
		t.Fatal(e)
	}
	path := filepath.Join(s.dir, revisionName(2))
	raw, _ := os.ReadFile(path)
	corrupt := bytes.Replace(raw, []byte(`"status":"revoked"`), []byte(`"status":"active"`), 1)
	if e = os.WriteFile(path, corrupt, 0600); e != nil {
		t.Fatal(e)
	}
	if _, _, e = s.Read(); e == nil {
		t.Fatal("corrupt device history accepted")
	}
	retained, _ := os.ReadFile(path)
	if !bytes.Equal(retained, corrupt) {
		t.Fatal("corruption rewritten")
	}
}
