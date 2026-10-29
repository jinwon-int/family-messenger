package main

import (
	"errors"
	"log"
	"net/http"
	"time"

	"github.com/jinwon-int/family-messenger/archive/native-mls/server/internal/devicepolicy"
)

// Device self-service (#574 D1): the owner CLI's E2 and E5 transitions,
// reachable over the relay so a person enrolls their own new device from a
// device they already hold — no operator, no JSON pasted between phones.
//
//   - POST /v2/devices/candidates  {device_id, actor, signing_key[, subject, fingerprint]}
//     The NEW device (JWT only — it is not in the chain yet, so bindDevice
//     cannot apply) posts its public record into a mailbox keyed by the
//     caller's subject. 201 {device_id, fingerprint, policy_revision, expires_at};
//     re-posting the same id refreshes it. Rows expire after candidateTTL.
//   - GET  /v2/devices/candidates?device=<mine>
//     An active device of the same subject (bindDevice) lists the mailbox:
//     {policy_revision, candidates:[…]}. policy_revision is the base_revision
//     the approver signs against.
//   - POST /v2/devices/approvals  = AddDeviceEvidence (the CLI -add-device input)
//     Verified exactly as the CLI does (devicepolicy.ApplyAddDevice: signature,
//     same actor, registrar once the actor has one, base_revision CAS) plus the
//     relay's own binding: the caller's subject owns both the approver device
//     and the candidate. 201 {device_id, approved_by, revision}; the candidate
//     row is dropped.
//   - POST /v2/devices/roles      = RolesEvidence (E5, devicepolicy.ApplySetRoles)
//     Same binding: caller's subject owns the approver and the target.
//     201 {device_id, roles, approved_by, revision}.
//
// Error codes: 400 bad_request / bad_identifier / bad_candidate (shape, key,
// fingerprint, unknown role, duplicate id), 403 subject_mismatch (someone
// else's device), 403 approval_rejected (signature or signer not allowed —
// detail says why), 403 first_device_out_of_band (the subject has no active
// device: E1 stays an operator ceremony until #574 D3), 409 stale_revision
// (`revision` carries the current one — re-sign), 500
// device_policy_unavailable. The routes exist only with both caller
// authentication and a device store (there is no subject, and nothing to
// write, otherwise). The chain's own file lock and CAS keep a concurrent CLI
// commit safe; every request re-reads the chain, so nothing restarts.

const (
	candidateTTL       = 10 * time.Minute
	maxCandidatesShown = 16
)

type candidatePost struct {
	DeviceID    string `json:"device_id"`
	Actor       string `json:"actor"`
	Subject     string `json:"subject,omitempty"`
	SigningKey  string `json:"signing_key"`
	Fingerprint string `json:"fingerprint,omitempty"`
}

type candidateView struct {
	DeviceID    string `json:"device_id"`
	Actor       string `json:"actor"`
	Subject     string `json:"subject"`
	SigningKey  string `json:"signing_key"`
	Fingerprint string `json:"fingerprint"`
	CreatedAt   int64  `json:"created_at"`
	ExpiresAt   int64  `json:"expires_at"`
}

type candidatePosted struct {
	DeviceID       string `json:"device_id"`
	Fingerprint    string `json:"fingerprint"`
	PolicyRevision uint64 `json:"policy_revision"`
	ExpiresAt      int64  `json:"expires_at"`
}

type candidatesResponse struct {
	PolicyRevision uint64          `json:"policy_revision"`
	Candidates     []candidateView `json:"candidates"`
}

type approvalResponse struct {
	DeviceID   string   `json:"device_id"`
	ApprovedBy string   `json:"approved_by"`
	Revision   uint64   `json:"revision"`
	Roles      []string `json:"roles,omitempty"`
}

// readPolicy reads the chain for a self-service route; a nil store or an
// unreadable chain is the same 500 the binding uses.
func (s *relay) readPolicy(w http.ResponseWriter) (devicepolicy.DevicePolicyInfo, []devicepolicy.DeviceV4, bool) {
	if s.devices == nil {
		s.fail(w, http.StatusNotFound, apiError{Error: "not_found"})
		return devicepolicy.DevicePolicyInfo{}, nil, false
	}
	info, wire, err := s.devices.Read()
	if err != nil {
		log.Printf("devices: read policy: %v", err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "device_policy_unavailable", Detail: "device policy chain unreadable; writes fail closed"})
		return devicepolicy.DevicePolicyInfo{}, nil, false
	}
	return info, wire.Devices, true
}

// subjectHasActive reports whether the caller already holds an active device.
func subjectHasActive(devices []devicepolicy.DeviceV4, subject string) bool {
	for _, d := range devices {
		if d.Subject == subject && d.Status == devicepolicy.StatusActive {
			return true
		}
	}
	return false
}

func (s *relay) handlePostCandidate(w http.ResponseWriter, req *http.Request) {
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	body, ok := s.readBody(w, req)
	if !ok {
		return
	}
	var post candidatePost
	if err := strictJSON(body, &post); err != nil {
		s.failJSON(w, err)
		return
	}
	switch {
	case !validIdentifier(post.DeviceID):
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "device_id"})
		return
	case !validIdentifier(post.Actor):
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "actor"})
		return
	case post.Subject != "" && post.Subject != c.subject:
		// The record would be bound to someone else's identity — the chain
		// binds a device to the JWT subject that will use it, which is us.
		s.fail(w, http.StatusForbidden, apiError{Error: "subject_mismatch"})
		return
	}
	fp, err := devicepolicy.Fingerprint(post.SigningKey)
	if err != nil {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_candidate", Detail: "signing_key"})
		return
	}
	if post.Fingerprint != "" && post.Fingerprint != fp {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_candidate", Detail: "fingerprint does not match signing_key"})
		return
	}
	info, devices, ok := s.readPolicy(w)
	if !ok {
		return
	}
	if _, exists := devicepolicy.FindByID(devices, post.DeviceID); exists {
		s.fail(w, http.StatusConflict, apiError{Error: "device_exists", Detail: "ids are never reused; start again with a new device id"})
		return
	}
	if !subjectHasActive(devices, c.subject) {
		// A person with no device yet cannot approve themselves: E1 is still
		// the operator's out-of-band ceremony (#574 D3 is phase 2).
		s.fail(w, http.StatusForbidden, apiError{Error: "first_device_out_of_band"})
		return
	}
	now := time.Now().Unix()
	expires := now + int64(candidateTTL/time.Second)
	if err := s.saveCandidate(post.DeviceID, c.subject, post.Actor, post.SigningKey, fp, now, expires); err != nil {
		log.Printf("devices: save candidate %s: %v", post.DeviceID, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
		return
	}
	log.Printf("devices: candidate %s posted (actor %s)", post.DeviceID, post.Actor)
	writeJSON(w, http.StatusCreated, candidatePosted{DeviceID: post.DeviceID, Fingerprint: fp, PolicyRevision: info.Revision, ExpiresAt: expires})
}

func (s *relay) handleListCandidates(w http.ResponseWriter, req *http.Request) {
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	device := req.URL.Query().Get("device")
	if device == "" {
		s.fail(w, http.StatusBadRequest, apiError{Error: "device_required"})
		return
	}
	if !validIdentifier(device) {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "device"})
		return
	}
	if !s.bindDevice(w, c, device) {
		return
	}
	info, _, ok := s.readPolicy(w)
	if !ok {
		return
	}
	list, err := s.listCandidates(c.subject, time.Now().Unix())
	if err != nil {
		log.Printf("devices: list candidates: %v", err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
		return
	}
	writeJSON(w, http.StatusOK, candidatesResponse{PolicyRevision: info.Revision, Candidates: list})
}

// policyFailure maps a devicepolicy error to the route's status and code.
func (s *relay) policyFailure(w http.ResponseWriter, err error, current uint64) {
	switch {
	case errors.Is(err, devicepolicy.ErrDevicePolicyConflict):
		s.fail(w, http.StatusConflict, apiError{Error: "stale_revision", Detail: err.Error(), Revision: int64(current)})
	case errors.Is(err, devicepolicy.ErrDevicePolicyApproval):
		s.fail(w, http.StatusForbidden, apiError{Error: "approval_rejected", Detail: err.Error()})
	case errors.Is(err, devicepolicy.ErrDevicePolicyConfig):
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_candidate", Detail: err.Error()})
	default:
		log.Printf("devices: policy: %v", err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "device_policy_unavailable", Detail: "device policy chain unreadable; writes fail closed"})
	}
}

// subjectOwns reports whether the device with that id belongs to subject.
func subjectOwns(devices []devicepolicy.DeviceV4, id, subject string) bool {
	i, ok := devicepolicy.FindByID(devices, id)
	return ok && devices[i].Subject == subject
}

func (s *relay) handlePostApproval(w http.ResponseWriter, req *http.Request) {
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	body, ok := s.readBody(w, req)
	if !ok {
		return
	}
	var ev devicepolicy.AddDeviceEvidence
	if err := strictJSON(body, &ev); err != nil {
		s.failJSON(w, err)
		return
	}
	switch {
	case !validIdentifier(ev.DeviceID):
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "device_id"})
		return
	case !validIdentifier(ev.Actor):
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "actor"})
		return
	case ev.Subject != c.subject:
		// Only my own devices: the candidate must be bound to my identity.
		s.fail(w, http.StatusForbidden, apiError{Error: "subject_mismatch"})
		return
	}
	info, devices, ok := s.readPolicy(w)
	if !ok {
		return
	}
	next, approver, err := devicepolicy.ApplyAddDevice(devices, ev, info.Revision)
	if err != nil {
		s.policyFailure(w, err, info.Revision)
		return
	}
	if !subjectOwns(devices, approver, c.subject) {
		// The signature verified under a same-actor device that someone
		// else's token presented — refuse without naming the approver.
		s.fail(w, http.StatusForbidden, apiError{Error: "device_subject_mismatch"})
		return
	}
	committed, err := s.devices.Commit(info.Revision, devicepolicy.PolicyWire4{Version: devicepolicy.DevicePolicyVersion, Devices: next})
	if err != nil {
		s.policyFailure(w, err, info.Revision)
		return
	}
	if err := s.deleteCandidate(ev.DeviceID); err != nil {
		log.Printf("devices: drop candidate %s: %v", ev.DeviceID, err)
	}
	log.Printf("devices: %s enrolled by %s (actor %s) → revision %d", ev.DeviceID, approver, ev.Actor, committed.Revision)
	writeJSON(w, http.StatusCreated, approvalResponse{DeviceID: ev.DeviceID, ApprovedBy: approver, Revision: committed.Revision})
}

func (s *relay) handlePostRoles(w http.ResponseWriter, req *http.Request) {
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	body, ok := s.readBody(w, req)
	if !ok {
		return
	}
	var ev devicepolicy.RolesEvidence
	if err := strictJSON(body, &ev); err != nil {
		s.failJSON(w, err)
		return
	}
	switch {
	case !validIdentifier(ev.DeviceID):
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "device_id"})
		return
	case !validIdentifier(ev.Actor):
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "actor"})
		return
	case ev.Roles == nil:
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_candidate", Detail: "roles (complete list) is required"})
		return
	}
	info, devices, ok := s.readPolicy(w)
	if !ok {
		return
	}
	if !subjectOwns(devices, ev.DeviceID, c.subject) {
		s.fail(w, http.StatusForbidden, apiError{Error: "device_subject_mismatch"})
		return
	}
	next, approver, err := devicepolicy.ApplySetRoles(devices, ev, info.Revision)
	if err != nil {
		s.policyFailure(w, err, info.Revision)
		return
	}
	if !subjectOwns(devices, approver, c.subject) {
		s.fail(w, http.StatusForbidden, apiError{Error: "device_subject_mismatch"})
		return
	}
	committed, err := s.devices.Commit(info.Revision, devicepolicy.PolicyWire4{Version: devicepolicy.DevicePolicyVersion, Devices: next})
	if err != nil {
		s.policyFailure(w, err, info.Revision)
		return
	}
	roles, _ := devicepolicy.CanonicalRoles(ev.Roles)
	log.Printf("devices: %s roles=%v set by %s → revision %d", ev.DeviceID, roles, approver, committed.Revision)
	writeJSON(w, http.StatusCreated, approvalResponse{DeviceID: ev.DeviceID, ApprovedBy: approver, Revision: committed.Revision, Roles: roles})
}

// ---- candidate mailbox (sqlite, TTL) ----

func (s *relay) saveCandidate(device, subject, actor, signingKey, fingerprint string, now, expires int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := s.db.Exec(`DELETE FROM device_candidates WHERE expires_at <= ?`, now); err != nil {
		return err
	}
	_, err := s.db.Exec(`INSERT INTO device_candidates (device, subject, actor, signing_key, fingerprint, created_at, expires_at)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(device) DO UPDATE SET subject = excluded.subject, actor = excluded.actor, signing_key = excluded.signing_key,
  fingerprint = excluded.fingerprint, created_at = excluded.created_at, expires_at = excluded.expires_at`,
		device, subject, actor, signingKey, fingerprint, now, expires)
	return err
}

func (s *relay) listCandidates(subject string, now int64) ([]candidateView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(`SELECT device, actor, subject, signing_key, fingerprint, created_at, expires_at
FROM device_candidates WHERE subject = ? AND expires_at > ? ORDER BY created_at, device LIMIT ?`, subject, now, maxCandidatesShown)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []candidateView{}
	for rows.Next() {
		var v candidateView
		if err := rows.Scan(&v.DeviceID, &v.Actor, &v.Subject, &v.SigningKey, &v.Fingerprint, &v.CreatedAt, &v.ExpiresAt); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func (s *relay) deleteCandidate(device string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`DELETE FROM device_candidates WHERE device = ?`, device)
	return err
}
