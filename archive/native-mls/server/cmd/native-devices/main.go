// native-devices is the owner CLI for the native device policy v4 chain
// (#177 §3.1/§3.2). The five operations:
//
//	-init          create the genesis revision in an empty directory
//	-enroll-first  E1: an actor's first active device, out-of-band acceptance
//	-add-device    E2: add a device carrying Ed25519 approval evidence signed
//	               by an active same-actor device (trusted acceptance)
//	-revoke        E3: revoke one active device; optional device-signed
//	               revocation evidence is written once on the tombstone
//	-revoke-all    E4: revoke every active device of an actor (total device
//	               loss recovery; the replacement room is client-side)
//
// Every mutation is a compare-and-swap on the exact current revision. Output
// and -inspect never include signing keys; fingerprints (sha256 over the
// signing key bytes) are what operators compare out-of-band.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/jinwon-int/family-messenger/archive/native-mls/server/internal/devicepolicy"
)

type enrollCandidate struct {
	DeviceID   string `json:"device_id"`
	Actor      string `json:"actor"`
	Subject    string `json:"subject"`
	SigningKey string `json:"signing_key"`
}

type addDeviceCandidate struct {
	DeviceID     string `json:"device_id"`
	Actor        string `json:"actor"`
	Subject      string `json:"subject"`
	SigningKey   string `json:"signing_key"`
	BaseRevision uint64 `json:"base_revision"`
	Signature    string `json:"signature"`
}

type revokeEvidence struct {
	Action       string `json:"action"`
	DeviceID     string `json:"device_id"`
	BaseRevision uint64 `json:"base_revision"`
	Signature    string `json:"signature"`
}

// deviceSummary is the only device projection this CLI prints: no signing keys.
type deviceSummary struct {
	DeviceID    string                       `json:"device_id"`
	Actor       string                       `json:"actor"`
	Subject     string                       `json:"subject"`
	Status      string                       `json:"status"`
	Acceptance  string                       `json:"acceptance"`
	Revision    uint64                       `json:"device_revision"`
	Fingerprint string                       `json:"fingerprint"`
	ApprovedBy  *devicepolicy.DeviceApproval `json:"approved_by,omitempty"`
}

type stateView struct {
	Revision uint64          `json:"revision"`
	SHA256   string          `json:"sha256"`
	Devices  []deviceSummary `json:"devices"`
}

func main() {
	if e := run(os.Args[1:], os.Stdout); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}

func run(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("native-devices", flag.ContinueOnError)
	dir := fs.String("device-state", "", "device policy chain directory (0700, created if missing; absolute path)")
	input := fs.String("input", "", "private candidate/evidence JSON file (absolute path)")
	expected := fs.Uint64("expected-revision", 0, "required current revision for mutations (exact CAS)")
	initMode := fs.Bool("init", false, "create the genesis revision in an empty directory")
	inspect := fs.Bool("inspect", false, "print revision/hash and device fingerprints; never keys")
	enrollFirst := fs.Bool("enroll-first", false, "E1: enroll an actor's first active device (out-of-band)")
	addDevice := fs.Bool("add-device", false, "E2: add a device approved by an active same-actor device")
	revoke := fs.String("revoke", "", "E3: revoke this active device id (optional -input evidence)")
	revokeAll := fs.String("revoke-all", "", "E4: revoke every active device of this actor")
	if e := fs.Parse(args); e != nil {
		return e
	}
	if fs.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}

	modes := 0
	for _, on := range []bool{*initMode, *inspect, *enrollFirst, *addDevice, *revoke != "", *revokeAll != ""} {
		if on {
			modes++
		}
	}
	if *dir == "" || modes != 1 {
		return errors.New("requires -device-state and exactly one of -init, -inspect, -enroll-first, -add-device, -revoke, -revoke-all")
	}
	if !filepath.IsAbs(*dir) {
		return errors.New("-device-state must be an absolute path")
	}
	if *input != "" && !(*enrollFirst || *addDevice || *revoke != "") {
		return errors.New("-input applies only to -enroll-first, -add-device and (optionally) -revoke")
	}
	mutating := *enrollFirst || *addDevice || *revoke != "" || *revokeAll != ""
	if mutating && *expected == 0 {
		return errors.New("mutations require -expected-revision (exact CAS on the current revision)")
	}
	if !mutating && *expected != 0 {
		return errors.New("-expected-revision applies only to mutations")
	}

	s, e := openStore(*dir)
	if e != nil {
		return e
	}
	switch {
	case *initMode:
		info, e := s.Init()
		if e != nil {
			return e
		}
		return printView(stateView{Revision: info.Revision, SHA256: info.SHA256, Devices: []deviceSummary{}}, out)
	case *inspect:
		info, policy, e := s.Read()
		if e != nil {
			return e
		}
		return printView(view(info, policy.Devices), out)
	default:
		info, policy, e := s.Read()
		if e != nil {
			return e
		}
		if *expected != info.Revision {
			return fmt.Errorf("current revision is %d; -expected-revision must match it exactly", info.Revision)
		}
		var next []devicepolicy.DeviceV4
		switch {
		case *enrollFirst:
			next, e = enrollFirstDevice(policy.Devices, *input)
		case *addDevice:
			next, e = addApprovedDevice(policy.Devices, *input, *expected)
		case *revoke != "":
			next, e = revokeDevice(policy.Devices, *revoke, *input, *expected)
		default:
			next, e = revokeAllDevices(policy.Devices, *revokeAll)
		}
		if e != nil {
			return e
		}
		committed, e := s.Commit(*expected, devicepolicy.PolicyWire4{Version: devicepolicy.DevicePolicyVersion, Devices: next})
		if e != nil {
			return e
		}
		return printView(view(committed, next), out)
	}
}

func openStore(dir string) (*devicepolicy.DevicePolicyStore, error) {
	if e := os.MkdirAll(dir, 0700); e != nil {
		return nil, fmt.Errorf("create device state directory: %w", e)
	}
	return devicepolicy.OpenDevicePolicyStore(dir)
}

func view(info devicepolicy.DevicePolicyInfo, devices []devicepolicy.DeviceV4) stateView {
	v := stateView{Revision: info.Revision, SHA256: info.SHA256, Devices: make([]deviceSummary, 0, len(devices))}
	for _, d := range devices {
		v.Devices = append(v.Devices, deviceSummary{
			DeviceID:    d.ID,
			Actor:       d.Actor,
			Subject:     d.Subject,
			Status:      d.Status,
			Acceptance:  d.Acceptance,
			Revision:    d.Revision,
			Fingerprint: d.Fingerprint,
			ApprovedBy:  d.ApprovedBy,
		})
	}
	return v
}

func printView(v stateView, out io.Writer) error {
	return json.NewEncoder(out).Encode(v)
}

func readStrictInput(path string, v any) error {
	b, e := devicepolicy.ReadCandidate(path)
	if e != nil {
		return fmt.Errorf("read candidate: %w", e)
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if e := dec.Decode(v); e != nil {
		return fmt.Errorf("candidate JSON: %w", e)
	}
	if _, e := dec.Token(); e != io.EOF {
		return errors.New("candidate JSON has trailing data")
	}
	return nil
}

func fingerprintOf(signingKey string) (string, error) {
	raw, e := devicepolicy.DecodeSigningKey(signingKey)
	if e != nil {
		return "", errors.New("signing_key must be 32 bytes of lowercase hex (the device signing key)")
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:]), nil
}

func cloneDevices(devices []devicepolicy.DeviceV4) []devicepolicy.DeviceV4 {
	return append([]devicepolicy.DeviceV4(nil), devices...)
}

func findById(devices []devicepolicy.DeviceV4, id string) (int, bool) {
	for i := range devices {
		if devices[i].ID == id {
			return i, true
		}
	}
	return -1, false
}

// enrollFirstDevice builds the E1 transition: an out-of-band first active
// device with no approved_by. The store's transition validator enforces that
// the actor has no other active device.
func enrollFirstDevice(devices []devicepolicy.DeviceV4, input string) ([]devicepolicy.DeviceV4, error) {
	if input == "" {
		return nil, errors.New("-enroll-first requires -input (private candidate JSON)")
	}
	var c enrollCandidate
	if e := readStrictInput(input, &c); e != nil {
		return nil, e
	}
	if e := requireSubject(c.Subject); e != nil {
		return nil, e
	}
	fp, e := fingerprintOf(c.SigningKey)
	if e != nil {
		return nil, e
	}
	if _, ok := findById(devices, c.DeviceID); ok {
		return nil, fmt.Errorf("device id %q already exists; ids are never reused", c.DeviceID)
	}
	return append(cloneDevices(devices), devicepolicy.DeviceV4{
		ID:          c.DeviceID,
		Actor:       c.Actor,
		Subject:     c.Subject,
		SigningKey:  c.SigningKey,
		Fingerprint: fp,
		Status:      devicepolicy.StatusActive,
		Revision:    1,
		Acceptance:  devicepolicy.AcceptanceOutOfBand,
	}), nil
}

// requireSubject names the relay's identity binding in the error: the v4
// chain validator already rejects an empty subject structurally, but an
// operator enrolling a device should learn what the field is for. The value
// is the CF Access identity owning the device — the user's `sub`, or for a
// bot the service-token `common_name` (the Client-Id); every relay request
// made as this device must carry a JWT with exactly that identity (G-M6:
// service tokens carry an empty `sub`).
func requireSubject(subject string) error {
	if !devicepolicy.IsSubject(subject, 128) {
		return errors.New("subject is required ([A-Za-z0-9_.@-]{1,128}): the CF Access `sub` (or a bot's service-token `common_name`) the relay binds this device's requests to (DEVICES-V4.md)")
	}
	return nil
}

// addApprovedDevice builds the E2 transition: a trusted-acceptance device whose
// approved_by evidence is verified against the active same-actor set and bound
// to the revision this commit creates.
func addApprovedDevice(devices []devicepolicy.DeviceV4, input string, expected uint64) ([]devicepolicy.DeviceV4, error) {
	if input == "" {
		return nil, errors.New("-add-device requires -input (private candidate JSON with approval evidence)")
	}
	var c addDeviceCandidate
	if e := readStrictInput(input, &c); e != nil {
		return nil, e
	}
	if c.BaseRevision != expected {
		return nil, fmt.Errorf("candidate base_revision %d does not bind the current revision %d; re-sign against the current state", c.BaseRevision, expected)
	}
	if e := requireSubject(c.Subject); e != nil {
		return nil, e
	}
	fp, e := fingerprintOf(c.SigningKey)
	if e != nil {
		return nil, e
	}
	if _, ok := findById(devices, c.DeviceID); ok {
		return nil, fmt.Errorf("device id %q already exists; ids are never reused", c.DeviceID)
	}
	payload := devicepolicy.ApprovalPayloadWire{
		Action:       devicepolicy.ApprovalActionAdd,
		DeviceID:     c.DeviceID,
		Actor:        c.Actor,
		Subject:      c.Subject,
		SigningKey:   c.SigningKey,
		Fingerprint:  fp,
		Acceptance:   devicepolicy.AcceptanceTrusted,
		BaseRevision: c.BaseRevision,
	}
	approver, e := findApprover(devices, payload, c.Signature, expected)
	if e != nil {
		return nil, e
	}
	return append(cloneDevices(devices), devicepolicy.DeviceV4{
		ID:          c.DeviceID,
		Actor:       c.Actor,
		Subject:     c.Subject,
		SigningKey:  c.SigningKey,
		Fingerprint: fp,
		Status:      devicepolicy.StatusActive,
		Revision:    1,
		Acceptance:  devicepolicy.AcceptanceTrusted,
		ApprovedBy:  &devicepolicy.DeviceApproval{DeviceID: approver, Revision: expected + 1},
	}), nil
}

// revokeDevice builds the E3 transition: active/1 → revoked/2. With -input
// evidence the tombstone carries the device-signed revocation approval, which
// may be written exactly once and only when the device has no approved_by yet
// (trusted-enrolled devices always carry their enrollment evidence).
func revokeDevice(devices []devicepolicy.DeviceV4, id, input string, expected uint64) ([]devicepolicy.DeviceV4, error) {
	idx, ok := findById(devices, id)
	if !ok {
		return nil, fmt.Errorf("device %q is not in the policy", id)
	}
	target := devices[idx]
	if target.Status != devicepolicy.StatusActive {
		return nil, fmt.Errorf("device %q is already revoked; tombstones are permanent", id)
	}
	next := cloneDevices(devices)
	next[idx].Status = devicepolicy.StatusRevoked
	next[idx].Revision = 2
	if input == "" {
		return next, nil
	}
	if target.ApprovedBy != nil {
		return nil, errors.New("device already carries approved_by evidence; plain revoke only (evidence is written once)")
	}
	var ev revokeEvidence
	if e := readStrictInput(input, &ev); e != nil {
		return nil, e
	}
	if ev.Action != devicepolicy.ApprovalActionRevoke {
		return nil, fmt.Errorf("evidence action %q is not %q", ev.Action, devicepolicy.ApprovalActionRevoke)
	}
	if ev.DeviceID != id {
		return nil, fmt.Errorf("evidence binds device %q, not %q", ev.DeviceID, id)
	}
	if ev.BaseRevision != expected {
		return nil, fmt.Errorf("evidence base_revision %d does not bind the current revision %d", ev.BaseRevision, expected)
	}
	payload := devicepolicy.ApprovalPayloadWire{
		Action:       devicepolicy.ApprovalActionRevoke,
		DeviceID:     target.ID,
		Actor:        target.Actor,
		Subject:      target.Subject,
		SigningKey:   target.SigningKey,
		Fingerprint:  target.Fingerprint,
		Acceptance:   target.Acceptance,
		BaseRevision: ev.BaseRevision,
	}
	approver, e := findApprover(devices, payload, ev.Signature, expected)
	if e != nil {
		return nil, e
	}
	next[idx].ApprovedBy = &devicepolicy.DeviceApproval{DeviceID: approver, Revision: expected + 1}
	return next, nil
}

// revokeAllDevices builds the E4 transition for total device loss: every active
// device of the actor becomes a tombstone. No signatures are possible (the
// devices are lost); enrollment of the replacement device goes back through E1.
func revokeAllDevices(devices []devicepolicy.DeviceV4, actor string) ([]devicepolicy.DeviceV4, error) {
	next := cloneDevices(devices)
	changed := 0
	for i := range next {
		if next[i].Actor == actor && next[i].Status == devicepolicy.StatusActive {
			next[i].Status = devicepolicy.StatusRevoked
			next[i].Revision = 2
			changed++
		}
	}
	if changed == 0 {
		return nil, fmt.Errorf("actor %q has no active devices to revoke", actor)
	}
	return next, nil
}

// findApprover identifies which active same-actor device produced the
// signature: the policy already holds every candidate's public signing key, so
// the operator never supplies one. VerifyApproval itself rejects self-approval
// and cross-actor approvers.
func findApprover(devices []devicepolicy.DeviceV4, payload devicepolicy.ApprovalPayloadWire, signature string, base uint64) (string, error) {
	for _, d := range devices {
		if d.Actor != payload.Actor || d.Status != devicepolicy.StatusActive {
			continue
		}
		if id, e := devicepolicy.VerifyApproval(devices, payload.Action, payload, d.SigningKey, signature, base); e == nil {
			return id, nil
		}
	}
	return "", fmt.Errorf("no active %q device signature verifies this approval evidence", payload.Actor)
}
