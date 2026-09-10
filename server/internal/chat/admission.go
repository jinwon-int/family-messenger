package chat

// Aggregate admission service (#49 fourth slice): the server stands in for the
// real admission authority. It holds an Ed25519 admission key — generated
// deterministically from a synthetic seed, never leaving the process — and
// signs one admission per record write: rooms, actor, device id, signer key,
// peer pins, revision and expiry under the fixed canonical tuple the store
// verifies with the pinned public key. The public key itself is served from
// the same loopback origin for the synthetic qualification; a real deployment
// pins it out-of-band before the first use.

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jinwon-int/family-messenger/server/internal/access"
)

const (
	// admissionSeed is the deterministic synthetic seed for the admission
	// keypair. Synthetic only: a real deployment loads the key from the
	// signed auth state instead.
	admissionSeed = "family-synthetic-aggregate-admission-v1"
	// admissionTTLBucket is the decisional expiry bucket in milliseconds:
	// identical requests inside one bucket return the identical document, so
	// the store's fresh re-receipt check passes across its two reads.
	admissionTTLBucket = int64(60_000)
	// admissionValidity is how long one admission stays usable past its bucket.
	admissionValidity = int64(120_000)
)

var admissionPublic ed25519.PublicKey

func admissionKey() ed25519.PrivateKey {
	seed := sha256.Sum256([]byte(admissionSeed))
	return ed25519.NewKeyFromSeed(seed[:])
}

func init() { admissionPublic = admissionKey().Public().(ed25519.PublicKey) }

// admissionDocument mirrors the store's canonical tuple exactly:
// JSON.stringify([1,rooms,actor,device_id,signing_key,peers,revision,not_after])
// with peers as {"actor":..,"signing_key":..} objects in actor order.
type admissionDocument struct {
	V          int                    `json:"v"`
	Rooms      []string               `json:"rooms"`
	Actor      string                 `json:"actor"`
	DeviceID   string                 `json:"device_id"`
	SigningKey string                 `json:"signing_key"`
	Peers      []admissionPeer        `json:"peers"`
	Revision   uint64                 `json:"revision"`
	NotAfter   int64                  `json:"not_after"`
	Signature  string                 `json:"signature"`
}

type admissionPeer struct {
	Actor      string `json:"actor"`
	SigningKey string `json:"signing_key"`
}

// canonical builds the exact byte string the store signs/verifies. Every
// field is already validated to [a-z0-9-]/hex, so no JSON escaping occurs.
func (d *admissionDocument) canonical() []byte {
	peers := make([]string, 0, len(d.Peers))
	for _, p := range d.Peers {
		peers = append(peers, `{"actor":"`+p.Actor+`","signing_key":"`+p.SigningKey+`"}`)
	}
	var b strings.Builder
	b.WriteString(`[1,[`)
	b.WriteString(`"` + strings.Join(d.Rooms, `","`) + `"` + `],`)
	b.WriteString(`"` + d.Actor + `",`)
	b.WriteString(`"` + d.DeviceID + `",`)
	b.WriteString(`"` + d.SigningKey + `",`)
	b.WriteString(`[` + strings.Join(peers, ",") + `],`)
	b.WriteString(strconv.FormatUint(d.Revision, 10) + `,`)
	b.WriteString(strconv.FormatInt(d.NotAfter, 10) + `]`)
	return []byte(b.String())
}

func (d *admissionDocument) sign(key ed25519.PrivateKey) {
	d.Signature = hex.EncodeToString(ed25519.Sign(key, d.canonical()))
}

// aggregatePolicyKey serves the pinned admission public key. Synthetic only.
func (a *API) aggregatePolicyKey(w http.ResponseWriter) {
	writeJSON(w, 200, map[string]string{
		"algorithm": "ed25519",
		"public":     hex.EncodeToString(admissionPublic),
	})
}

// aggregateAdmission issues one signed admission for the requesting actor.
// The revision comes from the caller: the store enforces that it covers the
// next write. The rooms are the actor's committed rooms; the peers are the
// other active devices bound to the members of those rooms.
func (a *API) aggregateAdmission(w http.ResponseWriter, r *http.Request, g *access.Grant, actor string) {
	if r.URL.RawQuery == "" {
		fail(w, ErrInvalid)
		return
	}
	q := r.URL.Query()
	if len(q) != 1 || q.Get("revision") == "" {
		fail(w, ErrInvalid)
		return
	}
	revision, e := strconv.ParseUint(q.Get("revision"), 10, 64)
	if e != nil || revision < 1 || revision > 512 {
		fail(w, ErrInvalid)
		return
	}
	a.store.mu.Lock()
	defer a.store.mu.Unlock()
	rooms, e := a.store.rooms(actor)
	if e != nil {
		fail(w, e)
		return
	}
	roomIDs := make([]string, 0, len(rooms))
	for _, room := range rooms {
		roomIDs = append(roomIDs, room.ID)
	}
	if len(roomIDs) == 0 || len(roomIDs) > 2 {
		// The synthetic aggregate namespace commits at most two rooms; a
		// member of more rooms needs a real admission policy first.
		fail(w, ErrInvalid)
		return
	}
	var device *struct {
		id, key string
	}
	peers := []admissionPeer{}
	seen := map[string]bool{}
	for _, d := range g.DeviceBindings() {
		if d.Actor == actor {
			if d.Status == "active" && device == nil {
				device = &struct {
					id, key string
				}{d.ID, d.SigningKey}
			}
			continue
		}
		if d.Status != "active" || seen[d.Actor] {
			continue
		}
		for _, room := range roomIDs {
			if a.store.member(room, d.Actor) == nil {
				seen[d.Actor] = true
				peers = append(peers, admissionPeer{Actor: d.Actor, SigningKey: d.SigningKey})
				break
			}
		}
	}
	if device == nil {
		fail(w, ErrForbidden)
		return
	}
	// Deterministic expiry bucket: identical requests inside one bucket
	// produce the identical document, so the store's fresh re-receipt check
	// passes across its two reads.
	now := time.Now().UnixMilli()
	notAfter := now - now%admissionTTLBucket + admissionValidity
	doc := &admissionDocument{
		V: 1, Rooms: roomIDs, Actor: actor, DeviceID: device.id, SigningKey: device.key,
		Peers: peers, Revision: revision, NotAfter: notAfter,
	}
	doc.sign(admissionKey())
	writeJSON(w, 200, doc)
}
