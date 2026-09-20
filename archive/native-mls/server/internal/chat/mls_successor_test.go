package chat

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"testing"
	"time"

	"github.com/jinwon-int/family-messenger/server/internal/access"
)

const successorPath = "/v1/mls/successors/replace-one/context"

func successorContextFixture(t *testing.T, mutate ...func(*access.Config)) (*Store, *access.Authority, access.Config, func(string, string, string, any, string, int) []byte) {
	t.Helper()
	s, a, c, _, call := mlsFixture(t)
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
	key := bytes.Repeat([]byte{9}, 32)
	sum := sha256.Sum256(key)
	now := time.Now().Unix()
	c.Devices[0].Status = "revoked"
	c.Devices[0].Revision = 2
	c.Successors = &access.SuccessorPolicy{Administrators: []access.DeviceAdministrator{{Subject: "family", Actor: "bob"}}, Intents: []access.SuccessorIntent{{ID: "replace-one", Action: "replace", Actor: "alice", Subject: "owner", Predecessor: "alice-first", PredecessorKey: c.Devices[0].SigningKey, PredecessorRevision: 1, Candidate: "alice-next", SigningKey: hex.EncodeToString(key), Fingerprint: hex.EncodeToString(sum[:]), PackageSHA256: hex.EncodeToString(sum[:]), PreviousRoom: "source", PreviousGroup: group, NextRoom: "target", Administrator: access.DeviceAdministrator{Subject: "family", Actor: "bob"}, Acceptance: "out-of-band-fingerprint", BaseRevision: 2, CreatedAt: now - 2, ExpiresAt: now + 120, Status: "accepted", DecidedAt: now - 1, DecisionRevision: 4}}}
	for _, change := range mutate {
		change(&c)
	}
	if e := a.Replace(c); e != nil {
		t.Fatal(e)
	}
	return s, a, c, call
}

func TestSuccessorContextReadOnlyActorAndDeliveryBoundary(t *testing.T) {
	s, _, _, call := successorContextFixture(t)
	before, _ := s.mlsRoom("source")
	first := call("owner", "GET", successorPath, nil, "alice-next", 200)
	if len(first) > 4096 || !bytes.Equal(first, call("family", "GET", successorPath, nil, "bob-first", 200)) {
		t.Fatal("unstable public context")
	}
	var p successorContext
	if json.Unmarshal(first, &p) != nil || p.Admission != "preflight-only" || p.Predecessor.ID != "alice-first" || p.Candidate.ID != "alice-next" || p.Peer.ID != "bob-first" || p.DecisionRevision != 4 {
		t.Fatal("wrong binding")
	}
	for _, pair := range [][2]string{{"owner", "alice-first"}, {"owner", "bob-first"}, {"family", "alice-next"}, {"outsider", "charlie-first"}} {
		call(pair[0], "GET", successorPath, nil, pair[1], 403)
	}
	for _, path := range []string{successorPath + "?", successorPath + "?after=1"} {
		call("owner", "GET", path, nil, "alice-next", 400)
	}
	call("owner", "POST", successorPath, map[string]string{}, "alice-next", 400)
	call("owner", "GET", successorPath, nil, "", 400)
	call("owner", "GET", "/v1/mls/successors/missing/context", nil, "alice-next", 403)
	for _, pair := range [][2]string{{"owner", "alice-first"}, {"owner", "alice-next"}, {"family", "bob-first"}} {
		call(pair[0], "GET", "/v1/mls/rooms/source/log", nil, pair[1], 403)
		call(pair[0], "GET", "/v1/mls/rooms/source/context", nil, pair[1], 403)
	}
	call("owner", "POST", "/v1/mls/rooms", mlsCreate{"target", "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", "alice-next", "bob-first"}, "alice-next", 403)
	after, _ := s.mlsRoom("source")
	b, _ := json.Marshal(before)
	d, _ := json.Marshal(after)
	var targets int
	s.db.QueryRow("SELECT count(*) FROM rooms WHERE id='target'").Scan(&targets)
	if !bytes.Equal(b, d) || targets != 0 {
		t.Fatal("read mutated source/allocated target")
	}
}

func TestSuccessorContextCurrentPolicyAndSourceDenials(t *testing.T) {
	for _, kind := range []string{"admin", "account", "peer", "expired", "pending", "cancelled", "group", "room"} {
		t.Run(kind, func(t *testing.T) {
			change := func(c *access.Config) {
				i := &c.Successors.Intents[0]
				switch kind {
				case "admin":
					c.Successors.Administrators = nil
				case "account":
					c.People = c.People[1:]
				case "peer":
					c.Devices[1].Status = "revoked"
					c.Devices[1].Revision = 2
				case "expired":
					i.CreatedAt -= 300
					i.DecidedAt -= 300
					i.ExpiresAt -= 300
				case "pending":
					i.Status = "candidate"
					i.DecidedAt = 0
					i.DecisionRevision = 0
				case "cancelled":
					i.Status = "cancelled"
				case "group":
					i.PreviousGroup = "cccccccccccccccccccccccccccccccc"
				case "room":
					i.PreviousRoom = "family"
				}
			}
			if kind == "admin" || kind == "account" || kind == "peer" {
				_, a, c, call := successorContextFixture(t)
				call("family", "GET", successorPath, nil, "bob-first", 200)
				change(&c)
				if e := a.Replace(c); e != nil {
					t.Fatal(e)
				}
				call("family", "GET", successorPath, nil, "bob-first", 403)
			} else {
				_, _, _, call := successorContextFixture(t, change)
				call("family", "GET", successorPath, nil, "bob-first", 403)
			}
		})
	}
}

func TestSuccessorContextCorruptRoomAndOccupiedTarget(t *testing.T) {
	for _, tc := range []struct {
		name, sql string
		code      int
	}{
		{"legacy target", "INSERT INTO rooms(id,owner) VALUES('target','alice')", 409},
		{"bad pins", "UPDATE mls_rooms SET pins='[]'", 422},
		{"reversed pins", "UPDATE mls_rooms SET pins=json_array(json_extract(pins,'$[1]'),json_extract(pins,'$[0]'))", 422},
		{"epoch", "UPDATE mls_rooms SET epoch=0", 422},
		{"creator", "UPDATE mls_rooms SET creator='substituted'", 422},
		{"ack", "UPDATE mls_rooms SET phase='ack'", 403},
		{"group", "UPDATE mls_rooms SET group_id='cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd'", 403},
		{"extra member", "INSERT INTO members(room,actor) VALUES('source','charlie')", 403},
		{"removed peer", "DELETE FROM members WHERE room='source' AND actor='bob'", 403},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, _, _, call := successorContextFixture(t)
			if _, e := s.db.Exec(tc.sql); e != nil {
				t.Fatal(e)
			}
			call("family", "GET", successorPath, nil, "bob-first", tc.code)
		})
	}
}
