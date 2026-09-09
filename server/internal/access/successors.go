package access

import (
	"crypto/sha256"
	"encoding/hex"
	"reflect"
)

// SuccessorPolicy is private management state, never a device admission list.
// Version 2 policies keep original Devices and all tombstones unchanged in shape.
type DeviceAdministrator struct {
	Subject string `json:"subject"`
	Actor   string `json:"actor"`
}
type SuccessorPolicy struct {
	Administrators []DeviceAdministrator `json:"administrators"`
	Intents        []SuccessorIntent     `json:"intents"`
}
type SuccessorIntent struct {
	ID                  string              `json:"intent_id"`
	Action              string              `json:"action"`
	Actor               string              `json:"actor"`
	Subject             string              `json:"subject"`
	Predecessor         string              `json:"predecessor"`
	PredecessorKey      string              `json:"predecessor_key"`
	PredecessorRevision uint64              `json:"predecessor_revision"`
	Candidate           string              `json:"candidate"`
	SigningKey          string              `json:"signing_key"`
	Fingerprint         string              `json:"fingerprint"`
	PackageSHA256       string              `json:"package_sha256"`
	PreviousRoom        string              `json:"previous_room"`
	PreviousGroup       string              `json:"previous_group"`
	NextRoom            string              `json:"next_room"`
	Administrator       DeviceAdministrator `json:"administrator"`
	Acceptance          string              `json:"acceptance"`
	BaseRevision        uint64              `json:"base_revision"`
	CreatedAt           int64               `json:"created_at"`
	ExpiresAt           int64               `json:"expires_at"`
	Status              string              `json:"status"`
	DecidedAt           int64               `json:"decided_at"`
	DecisionRevision    uint64              `json:"decision_revision"`
}

func canonicalHex(s string, min, max int) bool {
	b, e := hex.DecodeString(s)
	return e == nil && len(b) >= min && len(b) <= max && hex.EncodeToString(b) == s
}
func deviceByID(c Config, id string) (Device, bool) {
	for _, d := range c.Devices {
		if d.ID == id {
			return d, true
		}
	}
	return Device{}, false
}
func administratorCurrent(c Config, a DeviceAdministrator) bool {
	if c.Successors == nil {
		return false
	}
	listed := false
	for _, v := range c.Successors.Administrators {
		if v == a {
			listed = true
		}
	}
	for _, p := range c.People {
		if listed && p.Subject == a.Subject && p.Actor == a.Actor {
			return true
		}
	}
	return false
}
func cloneSuccessors(c Config) (*SuccessorPolicy, error) {
	if c.Successors == nil {
		return nil, nil
	}
	s := c.Successors
	if len(s.Administrators) < 1 || len(s.Administrators) > 8 || len(s.Intents) > 16 {
		return nil, ErrConfig
	}
	out := &SuccessorPolicy{Administrators: append([]DeviceAdministrator{}, s.Administrators...), Intents: append([]SuccessorIntent{}, s.Intents...)}
	admins := map[string]bool{}
	for _, a := range s.Administrators {
		if !identifier(a.Subject, 128) || !identifier(a.Actor, 64) || admins[a.Subject] || !administratorCurrent(c, a) {
			return nil, ErrConfig
		}
		admins[a.Subject] = true
	}
	ids, keys, intents, predecessors := map[string]bool{}, map[string]bool{}, map[string]bool{}, map[string]bool{}
	for _, d := range c.Devices {
		ids[d.ID] = true
		keys[d.SigningKey] = true
	}
	for _, i := range s.Intents {
		d, ok := deviceByID(c, i.Predecessor)
		if !ok || d.Actor != i.Actor || d.Subject != i.Subject || d.SigningKey != i.PredecessorKey || i.PredecessorRevision != 1 || !identifier(i.ID, 64) || intents[i.ID] || !identifier(i.Candidate, 64) || ids[i.Candidate] || keys[i.SigningKey] || i.Action != "replace" || i.Acceptance != "out-of-band-fingerprint" || !identifier(i.Administrator.Subject, 128) || !identifier(i.Administrator.Actor, 64) {
			return nil, ErrConfig
		}
		if !canonicalHex(i.SigningKey, 32, 32) || !canonicalHex(i.PackageSHA256, 32, 32) || !identifier(i.PreviousRoom, 64) || !identifier(i.NextRoom, 64) || i.PreviousRoom == i.NextRoom || !canonicalHex(i.PreviousGroup, 16, 128) {
			return nil, ErrConfig
		}
		key, _ := hex.DecodeString(i.SigningKey)
		h := sha256.Sum256(key)
		if i.Fingerprint != hex.EncodeToString(h[:]) || i.BaseRevision < 1 || i.BaseRevision >= MaxPolicyRevisions || i.CreatedAt < 1 || i.ExpiresAt > 253402297199 || i.ExpiresAt <= i.CreatedAt || i.ExpiresAt-i.CreatedAt > 900 {
			return nil, ErrConfig
		}
		switch i.Status {
		case "candidate":
			if i.DecidedAt != 0 || i.DecisionRevision != 0 {
				return nil, ErrConfig
			}
		case "accepted", "cancelled":
			if i.DecisionRevision <= i.BaseRevision+1 || i.DecisionRevision > MaxPolicyRevisions || i.DecidedAt < i.CreatedAt || i.DecidedAt > 253402297199 {
				return nil, ErrConfig
			}
			if i.Status == "accepted" && (i.DecidedAt >= i.ExpiresAt || d.Status != "revoked" || d.Revision != 2) {
				return nil, ErrConfig
			}
		default:
			return nil, ErrConfig
		}
		// Even expired candidates retain their identity/key reservations. Explicit
		// cancellation releases only the predecessor slot, never IDs or keys.
		if i.Status != "cancelled" {
			if predecessors[i.Predecessor] {
				return nil, ErrConfig
			}
			predecessors[i.Predecessor] = true
		}
		ids[i.Candidate], keys[i.SigningKey], intents[i.ID] = true, true, true
	}
	return out, nil
}
func immutableIntent(a, b SuccessorIntent) bool {
	b.Status = a.Status
	b.DecidedAt = a.DecidedAt
	b.DecisionRevision = a.DecisionRevision
	return a == b
}

// Forward checks allow a live manager to skip already-validated durable revisions.
// The store separately validates EVERY adjacent transition in its history.
func successorForward(old, next Config) error {
	if old.Successors == nil {
		return nil
	}
	if next.Successors == nil || old.Issuer != next.Issuer || old.Audience != next.Audience {
		return ErrConfig
	}
	m := map[string]SuccessorIntent{}
	for _, i := range next.Successors.Intents {
		m[i.ID] = i
	}
	for _, i := range old.Successors.Intents {
		n, ok := m[i.ID]
		if !ok || !immutableIntent(i, n) {
			return ErrConfig
		}
		if i.Status != "candidate" && i != n {
			return ErrConfig
		}
	}
	return nil
}

// now==0 validates immutable historical timestamps, not their current expiry.
// At a new commit, freshness is rechecked INSIDE the policy lock.
func successorTransition(old, next Config, previousRevision uint64, now int64) error {
	if successorForward(old, next) != nil {
		return ErrConfig
	}
	if next.Successors == nil {
		return nil
	}
	if old.Successors == nil {
		// Explicitly establish administrators before proposing any replacement.
		if len(next.Successors.Intents) != 0 {
			return ErrConfig
		}
		return nil
	}
	prior := map[string]SuccessorIntent{}
	for _, i := range old.Successors.Intents {
		prior[i.ID] = i
	}
	for _, i := range next.Successors.Intents {
		p, exists := prior[i.ID]
		if exists && p == i {
			continue
		}
		if !exists {
			d, ok := deviceByID(old, i.Predecessor)
			n, nok := deviceByID(next, i.Predecessor)
			if !ok || !nok || d != n || d.Status != "active" || d.Revision != i.PredecessorRevision || i.Status != "candidate" || i.BaseRevision != previousRevision || !administratorCurrent(old, i.Administrator) || !administratorCurrent(next, i.Administrator) {
				return ErrConfig
			}
			if now != 0 && (i.CreatedAt > now || now-i.CreatedAt > 60 || i.ExpiresAt <= now) {
				return ErrConfig
			}
			continue
		}
		if p.Status != "candidate" || i.Status == "candidate" || i.DecisionRevision != previousRevision+1 {
			return ErrConfig
		}
		if now != 0 && (i.DecidedAt > now || now-i.DecidedAt > 60) {
			return ErrConfig
		}
		if i.Status == "accepted" {
			d, ok := deviceByID(old, i.Predecessor)
			n, nok := deviceByID(next, i.Predecessor)
			if !ok || !nok || d.Status != "active" || d.Revision != i.PredecessorRevision || n.Status != "revoked" || n.Revision != 2 || !administratorCurrent(old, i.Administrator) || !administratorCurrent(next, i.Administrator) || (now != 0 && now >= i.ExpiresAt) {
				return ErrConfig
			}
			// No enrollment/owner change may ride along with acceptance.
			if len(old.Devices) != len(next.Devices) || !reflect.DeepEqual(old.People, next.People) || !reflect.DeepEqual(old.Successors.Administrators, next.Successors.Administrators) {
				return ErrConfig
			}
		}
	}
	return nil
}
