package access

import (
	"crypto/sha256"
	"encoding/hex"
)

// Device is public material accepted explicitly outside the delivery directory.
// This first-device-only phase has no HTTP enrollment or replacement ceremony.
type Device struct {
	ID          string `json:"device_id"`
	Actor       string `json:"actor"`
	Subject     string `json:"subject"`
	SigningKey  string `json:"signing_key"`
	Fingerprint string `json:"fingerprint"`
	Status      string `json:"status"`
	Revision    uint64 `json:"device_revision"`
	Acceptance  string `json:"acceptance"`
}

func cloneDevices(devices []Device, people map[string]Enrollment) ([]Device, error) {
	if len(devices) > 32 {
		return nil, ErrConfig
	}
	ids, actors, keys := map[string]bool{}, map[string]bool{}, map[string]bool{}
	out := append([]Device(nil), devices...)
	for _, d := range out {
		key, e := hex.DecodeString(d.SigningKey)
		if e != nil || len(key) != 32 || hex.EncodeToString(key) != d.SigningKey {
			return nil, ErrConfig
		}
		hash := sha256.Sum256(key)
		if !identifier(d.ID, 64) || !identifier(d.Actor, 64) || !identifier(d.Subject, 128) || ids[d.ID] || actors[d.Actor] || keys[d.SigningKey] || d.Fingerprint != hex.EncodeToString(hash[:]) || d.Acceptance != "out-of-band-fingerprint" {
			return nil, ErrConfig
		}
		if (d.Status != "active" || d.Revision != 1) && (d.Status != "revoked" || d.Revision != 2) {
			return nil, ErrConfig
		}
		if d.Status == "active" {
			if p, ok := people[d.Subject]; !ok || p.Actor != d.Actor {
				return nil, ErrConfig
			}
		}
		ids[d.ID], actors[d.Actor], keys[d.SigningKey] = true, true, true
	}
	return out, nil
}

// Retain tombstones and immutable bindings across durable and live replacement.
// A second/replacement device and reactivation are deliberately not implemented.
func deviceTransition(old, next []Device) error {
	remaining := map[string]Device{}
	for _, d := range next {
		remaining[d.ID] = d
	}
	for _, d := range old {
		n, ok := remaining[d.ID]
		if !ok {
			return ErrConfig
		}
		if d != n {
			if d.Status != "active" || n.Status != "revoked" || n.Revision != 2 {
				return ErrConfig
			}
			n.Status = d.Status
			n.Revision = d.Revision
			if n != d {
				return ErrConfig
			}
		}
		delete(remaining, d.ID)
	}
	for _, d := range remaining {
		if d.Status != "active" || d.Revision != 1 {
			return ErrConfig
		}
	}
	return nil
}

// Captured at Verify; consumers must use the grant's bounded admission guard.
func (g *Grant) DeviceBindings() []Device { return append([]Device(nil), g.devices...) }
