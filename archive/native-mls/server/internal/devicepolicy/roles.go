package devicepolicy

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
)

// E5 set-roles (#574 D2): a registrar of the actor grants or releases the
// registrar role on one of the actor's active devices — this is how the
// person moves "the device that approves my devices" to a new phone before
// retiring the old one. The signing input mirrors the E2/E3 approval
// message, with its own canonical payload and action: the Rust facade
// (policy_wire `sign_roles`, PR 2+) must produce identical bytes.

// RolesPayloadWire is the canonical E5 payload (fixed field order = canonical
// byte encoding). Roles is the COMPLETE roles list the target ends up with
// (sorted, unique) — not a delta — so a replayed or reordered signature cannot
// mean anything else.
type RolesPayloadWire struct {
	Action       string   `json:"action"`
	DeviceID     string   `json:"device_id"`
	Actor        string   `json:"actor"`
	Roles        []string `json:"roles"`
	BaseRevision uint64   `json:"base_revision"`
}

// RolesMessage = "family-mls-v2/set-roles\0" ‖ sha256(canonical payload).
func RolesMessage(p RolesPayloadWire) ([]byte, error) {
	if p.Action != ApprovalActionRoles || p.Roles == nil || !validRoles(p.Roles) {
		return nil, ErrDevicePolicyApproval
	}
	canonical, err := json.Marshal(p)
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256(canonical)
	msg := make([]byte, 0, len(approvalDomainPrefix)+len(p.Action)+1+len(digest))
	msg = append(msg, approvalDomainPrefix...)
	msg = append(msg, p.Action...)
	msg = append(msg, 0x00)
	msg = append(msg, digest[:]...)
	return msg, nil
}

// CanonicalRoles returns the sorted, de-duplicated roles list, or an error
// when a role is unknown. An empty list is the canonical "no roles".
func CanonicalRoles(roles []string) ([]string, error) {
	seen := map[string]bool{}
	out := make([]string, 0, len(roles))
	for _, r := range roles {
		if r != RoleRegistrar {
			return nil, fmt.Errorf("unknown role %q: %w", r, ErrDevicePolicyConfig)
		}
		if !seen[r] {
			seen[r] = true
			out = append(out, r)
		}
	}
	sort.Strings(out)
	return out, nil
}

// VerifyRoles checks E5 evidence against the pre-transition state and returns
// the approver's device id. The approver must be an ACTIVE device of the
// target's actor with the given key; when the actor already has a registrar
// the approver must be one (the bootstrap of a pre-#574 actor is the one
// case where any active device may sign); the target must be active and of
// the same actor; and the actor may never be left without a registrar once
// it has one (the last registrar cannot release itself — grant another
// device first). The approver may be the target (self-bootstrap, or a
// registrar stepping down while another remains).
func VerifyRoles(old []DeviceV4, payload RolesPayloadWire, approverKeyHex, signatureHex string, baseRevision uint64) (string, error) {
	if payload.Action != ApprovalActionRoles || payload.BaseRevision != baseRevision || baseRevision < 1 {
		return "", ErrDevicePolicyApproval
	}
	if !validRoles(payload.Roles) {
		return "", fmt.Errorf("roles list is not canonical: %w", ErrDevicePolicyApproval)
	}
	key, err := DecodeSigningKey(approverKeyHex)
	if err != nil {
		return "", fmt.Errorf("approver key: %w", err)
	}
	var approver, target *DeviceV4
	for i := range old {
		if old[i].SigningKey == approverKeyHex {
			approver = &old[i]
		}
		if old[i].ID == payload.DeviceID {
			target = &old[i]
		}
	}
	if approver == nil || approver.Status != StatusActive {
		return "", fmt.Errorf("approver device is not active: %w", ErrDevicePolicyApproval)
	}
	if target == nil || target.Status != StatusActive {
		return "", fmt.Errorf("target device %q is not active: %w", payload.DeviceID, ErrDevicePolicyApproval)
	}
	if approver.Actor != payload.Actor || target.Actor != payload.Actor {
		return "", fmt.Errorf("approver and target must both belong to %q: %w", payload.Actor, ErrDevicePolicyApproval)
	}
	if HasRegistrar(old, payload.Actor) {
		if !IsRegistrar(*approver) {
			return "", fmt.Errorf("approver %q is not a registrar of %q: %w", approver.ID, payload.Actor, ErrDevicePolicyApproval)
		}
		// Count registrars after the change: every other active registrar
		// stays; the target counts only if it keeps/gains the role.
		remaining := 0
		for _, d := range old {
			if d.Actor == payload.Actor && d.Status == StatusActive && d.ID != target.ID && IsRegistrar(d) {
				remaining++
			}
		}
		if containsRole(payload.Roles, RoleRegistrar) {
			remaining++
		}
		if remaining == 0 {
			return "", fmt.Errorf("%q would be left without a registrar; grant another device first: %w", payload.Actor, ErrDevicePolicyApproval)
		}
	}
	sig, err := hex.DecodeString(signatureHex)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return "", fmt.Errorf("roles signature: %w", ErrDevicePolicyApproval)
	}
	msg, err := RolesMessage(payload)
	if err != nil {
		return "", err
	}
	if !ed25519.Verify(key, msg, sig) {
		return "", ErrDevicePolicyApproval
	}
	return approver.ID, nil
}

func containsRole(roles []string, role string) bool {
	for _, r := range roles {
		if r == role {
			return true
		}
	}
	return false
}
