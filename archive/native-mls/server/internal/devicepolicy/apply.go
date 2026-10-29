package devicepolicy

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
)

// Pure transition builders shared by the owner CLI (cmd/native-devices) and
// the relay's self-service routes (#574 D1). Each takes the current device
// set and the evidence, validates everything the chain itself does not
// (signatures, revision binding, who may sign) and returns the next set for
// Commit(expected, …). Errors wrap one of the package sentinels so a caller
// can map them: ErrDevicePolicyConflict (stale base_revision — re-sign),
// ErrDevicePolicyApproval (signature / signer not allowed),
// ErrDevicePolicyConfig (malformed input or an impossible transition).

// EnrollCandidate is the E1 input: the device's public record, no evidence.
type EnrollCandidate struct {
	DeviceID   string `json:"device_id"`
	Actor      string `json:"actor"`
	Subject    string `json:"subject"`
	SigningKey string `json:"signing_key"`
}

// AddDeviceEvidence is the E2 input: the candidate plus a same-actor
// device's Ed25519 signature over the canonical approve-device payload bound
// to BaseRevision. Fingerprint and ApprovedBy are optional cross-checks
// carried by client evidence (the fingerprint the approver compared by eye,
// the approver's own id); they are recomputed, never trusted.
type AddDeviceEvidence struct {
	DeviceID     string `json:"device_id"`
	Actor        string `json:"actor"`
	Subject      string `json:"subject"`
	SigningKey   string `json:"signing_key"`
	BaseRevision uint64 `json:"base_revision"`
	Signature    string `json:"signature"`
	Fingerprint  string `json:"fingerprint,omitempty"`
	ApprovedBy   string `json:"approved_by,omitempty"`
}

// RolesEvidence is the E5 input: the target device, the complete roles list
// it ends up with, and a registrar's signature over RolesPayloadWire.
type RolesEvidence struct {
	DeviceID     string   `json:"device_id"`
	Actor        string   `json:"actor"`
	Roles        []string `json:"roles"`
	BaseRevision uint64   `json:"base_revision"`
	Signature    string   `json:"signature"`
	ApprovedBy   string   `json:"approved_by,omitempty"`
}

// Fingerprint is sha256 over the raw signing-key bytes — the value people
// compare out-of-band.
func Fingerprint(signingKey string) (string, error) {
	raw, e := DecodeSigningKey(signingKey)
	if e != nil {
		return "", fmt.Errorf("signing_key must be 32 bytes of lowercase hex (the device signing key): %w", ErrDevicePolicyConfig)
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:]), nil
}

// RequireSubject names the relay's identity binding in the error: the chain
// validator already rejects an empty subject structurally, but whoever
// enrolls a device should learn what the field is for. The value is the CF
// Access identity owning the device — the user's `sub`, or for a bot the
// service-token `common_name` (the Client-Id); every relay request made as
// this device must carry a JWT with exactly that identity (G-M6: service
// tokens carry an empty `sub`).
func RequireSubject(subject string) error {
	if !IsSubject(subject, 128) {
		return fmt.Errorf("subject is required ([A-Za-z0-9_.@-]{1,128}): the CF Access `sub` (or a bot's service-token `common_name`) the relay binds this device's requests to (DEVICES-V4.md): %w", ErrDevicePolicyConfig)
	}
	return nil
}

func cloneDevices(devices []DeviceV4) []DeviceV4 {
	return append([]DeviceV4(nil), devices...)
}

// FindByID returns the index of the device with that id.
func FindByID(devices []DeviceV4, id string) (int, bool) {
	for i := range devices {
		if devices[i].ID == id {
			return i, true
		}
	}
	return -1, false
}

// ApplyEnrollFirst builds the E1 transition: an out-of-band first active
// device with no approved_by. The store's transition validator enforces that
// the actor has no other active device. Since #574 the first device is the
// actor's registrar.
func ApplyEnrollFirst(devices []DeviceV4, c EnrollCandidate) ([]DeviceV4, error) {
	if e := RequireSubject(c.Subject); e != nil {
		return nil, e
	}
	fp, e := Fingerprint(c.SigningKey)
	if e != nil {
		return nil, e
	}
	if _, ok := FindByID(devices, c.DeviceID); ok {
		return nil, fmt.Errorf("device id %q already exists; ids are never reused: %w", c.DeviceID, ErrDevicePolicyConfig)
	}
	return append(cloneDevices(devices), DeviceV4{
		ID:          c.DeviceID,
		Actor:       c.Actor,
		Subject:     c.Subject,
		SigningKey:  c.SigningKey,
		Fingerprint: fp,
		Status:      StatusActive,
		Revision:    1,
		Acceptance:  AcceptanceOutOfBand,
		Roles:       []string{RoleRegistrar},
	}), nil
}

// ApplyAddDevice builds the E2 transition: a trusted-acceptance device whose
// approved_by evidence is verified against the active same-actor set (a
// registrar once the actor has one) and bound to the revision this commit
// creates. Returns the approver's device id with the next set.
func ApplyAddDevice(devices []DeviceV4, c AddDeviceEvidence, expected uint64) ([]DeviceV4, string, error) {
	if c.BaseRevision != expected {
		return nil, "", fmt.Errorf("candidate base_revision %d does not bind the current revision %d; re-sign against the current state: %w", c.BaseRevision, expected, ErrDevicePolicyConflict)
	}
	if e := RequireSubject(c.Subject); e != nil {
		return nil, "", e
	}
	fp, e := Fingerprint(c.SigningKey)
	if e != nil {
		return nil, "", e
	}
	if c.Fingerprint != "" && !strings.EqualFold(c.Fingerprint, fp) {
		return nil, "", fmt.Errorf("candidate fingerprint %q does not match sha256(signing_key) %q; the approver compared a different key: %w", c.Fingerprint, fp, ErrDevicePolicyApproval)
	}
	if _, ok := FindByID(devices, c.DeviceID); ok {
		return nil, "", fmt.Errorf("device id %q already exists; ids are never reused: %w", c.DeviceID, ErrDevicePolicyConfig)
	}
	payload := ApprovalPayloadWire{
		Action:       ApprovalActionAdd,
		DeviceID:     c.DeviceID,
		Actor:        c.Actor,
		Subject:      c.Subject,
		SigningKey:   c.SigningKey,
		Fingerprint:  fp,
		Acceptance:   AcceptanceTrusted,
		BaseRevision: c.BaseRevision,
	}
	approver, e := FindApprover(devices, payload, c.Signature, expected)
	if e != nil {
		return nil, "", e
	}
	if c.ApprovedBy != "" && c.ApprovedBy != approver {
		return nil, "", fmt.Errorf("candidate approved_by %q does not match the device whose key verifies the signature (%q): %w", c.ApprovedBy, approver, ErrDevicePolicyApproval)
	}
	return append(cloneDevices(devices), DeviceV4{
		ID:          c.DeviceID,
		Actor:       c.Actor,
		Subject:     c.Subject,
		SigningKey:  c.SigningKey,
		Fingerprint: fp,
		Status:      StatusActive,
		Revision:    1,
		Acceptance:  AcceptanceTrusted,
		ApprovedBy:  &DeviceApproval{DeviceID: approver, Revision: expected + 1},
	}), approver, nil
}

// ApplySetRoles builds the E5 transition from signed evidence: the target's
// roles become exactly ev.Roles. Returns the approver's device id.
func ApplySetRoles(devices []DeviceV4, ev RolesEvidence, expected uint64) ([]DeviceV4, string, error) {
	if ev.BaseRevision != expected {
		return nil, "", fmt.Errorf("evidence base_revision %d does not bind the current revision %d; re-sign against the current state: %w", ev.BaseRevision, expected, ErrDevicePolicyConflict)
	}
	roles, e := CanonicalRoles(ev.Roles)
	if e != nil {
		return nil, "", e
	}
	payload := RolesPayloadWire{Action: ApprovalActionRoles, DeviceID: ev.DeviceID, Actor: ev.Actor, Roles: roles, BaseRevision: ev.BaseRevision}
	msg, e := RolesMessage(payload)
	if e != nil {
		return nil, "", e
	}
	signer, ok := signerOf(devices, ev.Actor, msg, ev.Signature)
	if !ok {
		return nil, "", fmt.Errorf("no active %q device signature verifies this roles evidence: %w", ev.Actor, ErrDevicePolicyApproval)
	}
	approver, e := VerifyRoles(devices, payload, signer.SigningKey, ev.Signature, expected)
	if e != nil {
		return nil, "", e
	}
	if ev.ApprovedBy != "" && ev.ApprovedBy != approver {
		return nil, "", fmt.Errorf("evidence approved_by %q does not match the device whose key verifies the signature (%q): %w", ev.ApprovedBy, approver, ErrDevicePolicyApproval)
	}
	next, e := SetRoles(devices, ev.DeviceID, roles)
	if e != nil {
		return nil, "", e
	}
	return next, approver, nil
}

// SetRoles builds the roles transition without evidence — the operator's
// out-of-band recovery when an actor lost every registrar (CLI -set-roles
// without -input). The relay never calls it. The target must be active.
func SetRoles(devices []DeviceV4, id string, roles []string) ([]DeviceV4, error) {
	canonical, e := CanonicalRoles(roles)
	if e != nil {
		return nil, e
	}
	idx, ok := FindByID(devices, id)
	if !ok {
		return nil, fmt.Errorf("device %q is not in the policy: %w", id, ErrDevicePolicyConfig)
	}
	if devices[idx].Status != StatusActive {
		return nil, fmt.Errorf("device %q is revoked; roles live on active devices only: %w", id, ErrDevicePolicyConfig)
	}
	next := cloneDevices(devices)
	if len(canonical) == 0 {
		next[idx].Roles = nil
	} else {
		next[idx].Roles = canonical
	}
	return next, nil
}

// FindApprover identifies which active same-actor device produced an E2/E3
// signature: the policy already holds every candidate's public signing key,
// so no caller ever supplies one. VerifyApproval itself rejects
// self-approval, cross-actor approvers and (E2, once the actor has one)
// non-registrars; that refusal is surfaced in preference to the generic
// "no key verifies" when the signature itself was good.
func FindApprover(devices []DeviceV4, payload ApprovalPayloadWire, signature string, base uint64) (string, error) {
	msg, e := ApprovalMessage(payload)
	if e != nil {
		return "", e
	}
	signer, ok := signerOf(devices, payload.Actor, msg, signature)
	if !ok {
		return "", fmt.Errorf("no active %q device signature verifies this approval evidence: %w", payload.Actor, ErrDevicePolicyApproval)
	}
	return VerifyApproval(devices, payload.Action, payload, signer.SigningKey, signature, base)
}

// signerOf finds the active device of the actor whose key verifies the
// signature over msg — the signature alone identifies the signer, so the
// policy verdict (registrar, self-approval, last registrar…) is then computed
// exactly once for that device and reported as is.
func signerOf(devices []DeviceV4, actor string, msg []byte, signatureHex string) (DeviceV4, bool) {
	sig, err := hex.DecodeString(signatureHex)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return DeviceV4{}, false
	}
	for _, d := range devices {
		if d.Actor != actor || d.Status != StatusActive {
			continue
		}
		key, err := DecodeSigningKey(d.SigningKey)
		if err != nil {
			continue
		}
		if ed25519.Verify(key, msg, sig) {
			return d, true
		}
	}
	return DeviceV4{}, false
}

// Tombstone marks an active device revoked (E3/E4): roles are cleared, the
// rest is immutable.
func Tombstone(d *DeviceV4) {
	d.Status = StatusRevoked
	d.Revision = 2
	d.Roles = nil
}
