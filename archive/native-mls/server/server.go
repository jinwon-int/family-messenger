// native-mls v2 relay HTTP surface (#177 §3.4). Four contract routes plus
// the room-closure deletion path and a liveness probe. Strict JSON decoding
// (duplicate keys, unknown fields, explicit nulls and nesting deeper than
// maxJSONDepth rejected, mirroring decodeMLS) guards every request body.
//
// Caller identity (review C1): with an access verifier wired, every contract
// route first needs a valid CF Access JWT, then the device the request claims
// to act as must be policy-active with subject == claims.sub
// (403 device_subject_mismatch, which deliberately does not say which). The
// health probe is the only unauthenticated route.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/jinwon-int/family-messenger/archive/native-mls/server/internal/devicepolicy"
)

const (
	// maxBodyBytes bounds every POST body (M4): one event or one key-package
	// batch; the per-room cap applies to totals separately.
	maxBodyBytes = 1 << 20
	// maxJSONDepth caps nesting in request bodies (H1): the strict-JSON walk
	// is recursive and must not be driven by a `[[[[…` body.
	maxJSONDepth = 32
	// GET /events paging (M4).
	defaultEventsLimit = 500
	maxEventsLimit     = 2000
	// maxIdentifierLen matches devicepolicy's identifier rule (L8).
	maxIdentifierLen = 64
	// Review 2 G-H4: the per-room byte cap counts event bytes only, so every
	// other stored column of an event is bounded by shape — client_id is an
	// identifier, group_id an identifier-charset string of at most
	// maxGroupIDLen, and the Welcome target / member lists are short.
	maxGroupIDLen = 256
	maxTargets    = 32
	maxMembers    = 64
)

// policy carries the §3.4 retention defaults. Tests override the fields
// directly; flags only allow positive overrides on top of the defaults.
type policy struct {
	RoomBytesCap            int64
	KeyPackagesMaxPerDevice int
	KeyPackageTTLSeconds    int64
	CommitWelcomeKeepEpochs int64
	AppEventTTLSeconds      int64
	// RemovedCursorGraceSeconds: how long a member removed by commit keeps
	// gating application-event pruning with its cursor unless it reads its
	// own removal first (H3a).
	RemovedCursorGraceSeconds int64
}

func defaultPolicy() policy {
	const day = 24 * 60 * 60
	return policy{
		RoomBytesCap:              64 << 20, // 64 MiB per room (B5)
		KeyPackagesMaxPerDevice:   4,
		KeyPackageTTLSeconds:      7 * day,
		CommitWelcomeKeepEpochs:   8,
		AppEventTTLSeconds:        30 * day,
		RemovedCursorGraceSeconds: 7 * day,
	}
}

// relay owns the single SQLite connection. Every write path takes mu and the
// DSN carries _txlock=immediate, so with SetMaxOpenConns(1) exactly one
// BEGIN IMMEDIATE transaction is in flight at a time (B2/B3). Pruning
// cursors live in mls_cursors, not in memory, so they survive a restart.
// devices is the native device-policy chain (M3b): nil means -device-state
// was not given and membership enforcement is off. access is the CF Access
// verifier (C1): nil means -access-mode disabled — local dev only.
type relay struct {
	mu      sync.Mutex
	db      *store
	policy  policy
	devices *devicepolicy.DevicePolicyStore
	access  *accessVerifier
}

// ---- wire types ----

type eventPost struct {
	Device   string       `json:"device"`
	ClientID string       `json:"client_id"`
	Kind     string       `json:"kind"`
	Epoch    int64        `json:"epoch"`
	Revision *int64       `json:"revision"`
	GroupID  string       `json:"group_id"`
	Targets  []string     `json:"targets"`
	Members  []memberWire `json:"members"`
	Bytes    []byte       `json:"bytes"`
}

// memberWire is one client-replicated leaf entry of a commit: the relay
// cannot parse MLS commit payloads, so the sender device and the post-commit
// member list travel in the outer JSON (#177 §3.3). Clients verify outer and
// inner agree after MLS processing and reject mismatches; the relay enforces
// its membership policy against the replicated list alone.
type memberWire struct {
	Device string `json:"device"`
	Actor  string `json:"actor"`
}

type eventResponse struct {
	Seq       int64 `json:"seq"`
	Epoch     int64 `json:"epoch"`
	Revision  int64 `json:"revision"`
	Duplicate bool  `json:"duplicate"`
}

type storedRow struct {
	Seq       int64  `json:"seq"`
	Device    string `json:"device"`
	ClientID  string `json:"client_id"`
	Kind      string `json:"kind"`
	Epoch     int64  `json:"epoch"`
	Bytes     []byte `json:"bytes"`
	Sha256    string `json:"sha256"`
	CreatedAt int64  `json:"created_at"`
}

// eventsResponse is one page of the per-room order. NextAfter is the highest
// seq the page scanned (filtered Welcomes included), so a client passes it
// back as ?after= to continue; it equals the request's after when nothing
// newer exists.
type eventsResponse struct {
	Epoch     int64       `json:"epoch"`
	Revision  int64       `json:"revision"`
	Events    []storedRow `json:"events"`
	NextAfter int64       `json:"next_after"`
	// Cursor is the device's durable acknowledged position after this
	// request (M2): reads never move it; only ?ack= does.
	Cursor int64 `json:"cursor"`
}

// keyPackageInput is one posted KeyPackage: an opaque caller-chosen ref as
// identity plus the serialized package bytes.
type keyPackageInput struct {
	Ref   string `json:"ref"`
	Bytes []byte `json:"bytes"`
}

type keyPackagePost struct {
	Device   string            `json:"device"`
	Packages []keyPackageInput `json:"packages"`
}

// keyPackagesResponse: Stored counts newly inserted packages, Duplicates the
// byte-identical (room, device, ref) replays that were accepted idempotently.
type keyPackagesResponse struct {
	Stored     int `json:"stored"`
	Duplicates int `json:"duplicates"`
}

type storedKeyPackage struct {
	Ref       string `json:"ref"`
	Bytes     []byte `json:"bytes"`
	ExpiresAt int64  `json:"expires_at"`
}

// ---- error taxonomy (mapped to HTTP status codes below) ----

type casMismatch struct{ Epoch, Revision int64 }

func (e casMismatch) Error() string {
	return fmt.Sprintf("cas mismatch: current epoch=%d revision=%d", e.Epoch, e.Revision)
}

type clientIDReuse struct{ Device, ClientID string }

func (e clientIDReuse) Error() string {
	return fmt.Sprintf("client_id %q already used by device %q with different bytes", e.ClientID, e.Device)
}

type roomBytesCap struct{ Used, Cap int64 }

func (e roomBytesCap) Error() string {
	return fmt.Sprintf("room byte cap exceeded: used=%d cap=%d", e.Used, e.Cap)
}

type keyPackageLimit struct{ Live, Max int }

func (e keyPackageLimit) Error() string {
	return fmt.Sprintf("too many live key packages: live=%d max=%d", e.Live, e.Max)
}

// keyPackageRefConflict: a (room, device, ref) already holds different bytes
// (M5: byte-identical replays are idempotent, anything else is 409).
type keyPackageRefConflict struct{ Ref string }

func (e keyPackageRefConflict) Error() string {
	return fmt.Sprintf("key package ref %q already stored with different bytes", e.Ref)
}

// ---- M3b device-policy enforcement errors ----

// deviceNotAllowed: the posting device is unknown to or revoked in the native
// device policy (403). This is the revoke-then-POST-403 contract line.
type deviceNotAllowed struct{ Device string }

func (e deviceNotAllowed) Error() string {
	return fmt.Sprintf("device %q is not active in the native device policy", e.Device)
}

// commitActorMismatch: a replicated member entry names an actor other than
// the device's actor in the device policy (403, review 2 G-H3).
type commitActorMismatch struct{ Device, Posted, Policy string }

func (e commitActorMismatch) Error() string {
	return fmt.Sprintf("member %q is replicated as actor %q but the device policy binds it to %q", e.Device, e.Posted, e.Policy)
}

// policyUnavailable: the device policy chain failed fail-closed verification
// (500). No write proceeds while the chain is unreadable.
type policyUnavailable struct{ Err error }

func (e policyUnavailable) Error() string {
	return fmt.Sprintf("native device policy chain: %v", e.Err)
}

// commitSenderNotMember: a policy-active device that is not a tracked member
// of the room tried to commit (403).
type commitSenderNotMember struct{ Device string }

func (e commitSenderNotMember) Error() string {
	return fmt.Sprintf("commit sender %q is not a member of the room", e.Device)
}

// commitMemberNotActive: a commit tried to seed or add a device that the
// device policy does not show as active (403).
type commitMemberNotActive struct{ Device string }

func (e commitMemberNotActive) Error() string {
	return fmt.Sprintf("commit lists device %q which is not active in the device policy", e.Device)
}

// commitActorNotInRoster: a commit tried to add a device whose actor is not
// already on the room's actor roster — new devices join existing actors
// (§3.3); new actors join rooms client-side by creating or being invited into
// a group whose creation commit seeds the roster (403).
type commitActorNotInRoster struct{ Actor string }

func (e commitActorNotInRoster) Error() string {
	return fmt.Sprintf("commit adds a device of actor %q who is not on the room roster", e.Actor)
}

// apiError is the single JSON error shape; the CAS variant carries the
// current epoch/revision as required by §3.4 (409 + current values).
type apiError struct {
	Error    string `json:"error"`
	Detail   string `json:"detail,omitempty"`
	Epoch    int64  `json:"epoch,omitempty"`
	Revision int64  `json:"revision,omitempty"`
	Used     int64  `json:"used_bytes,omitempty"`
	Cap      int64  `json:"cap_bytes,omitempty"`
	Live     int    `json:"live,omitempty"`
	Max      int    `json:"max,omitempty"`
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// ---- strict JSON (K6) ----

var errJSONTooDeep = errors.New("json nesting exceeds the depth limit")

// rejectDuplicateKeys walks the token stream and fails on any object that
// repeats a key, at any depth, and on nesting deeper than maxJSONDepth (H1).
func rejectDuplicateKeys(data []byte) error {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var walkValue func(tok json.Token, depth int) error
	var walkNext func(depth int) error
	walkNext = func(depth int) error {
		tok, err := dec.Token()
		if err != nil {
			return err
		}
		return walkValue(tok, depth)
	}
	walkValue = func(tok json.Token, depth int) error {
		delim, ok := tok.(json.Delim)
		if !ok {
			return nil
		}
		if depth >= maxJSONDepth {
			return errJSONTooDeep
		}
		switch delim {
		case '{':
			seen := map[string]struct{}{}
			for dec.More() {
				keyTok, err := dec.Token()
				if err != nil {
					return err
				}
				key, ok := keyTok.(string)
				if !ok {
					return errors.New("non-string object key")
				}
				if _, dup := seen[key]; dup {
					return fmt.Errorf("duplicate key %q", key)
				}
				seen[key] = struct{}{}
				if err := walkNext(depth + 1); err != nil {
					return err
				}
			}
			_, err := dec.Token() // closing '}'
			return err
		case '[':
			for dec.More() {
				if err := walkNext(depth + 1); err != nil {
					return err
				}
			}
			_, err := dec.Token() // closing ']'
			return err
		}
		return errors.New("unexpected delimiter")
	}
	if err := walkNext(0); err != nil {
		return err
	}
	if _, err := dec.Token(); err != io.EOF {
		return errors.New("trailing data after JSON value")
	}
	return nil
}

// strictJSON decodes data into v rejecting duplicate keys, unknown fields,
// explicit nulls at the payload top level and excessive nesting.
func strictJSON(data []byte, v any) error {
	if err := rejectDuplicateKeys(data); err != nil {
		return err
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	for k, val := range raw {
		if string(val) == "null" {
			return fmt.Errorf("field %q is null", k)
		}
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return err
	}
	if _, err := dec.Token(); err != io.EOF {
		return errors.New("trailing data after JSON value")
	}
	return nil
}

// validIdentifier is the L8 rule for device ids, Welcome targets, member
// devices and actors: [A-Za-z0-9_-]{1,64}, identical to devicepolicy.
func validIdentifier(s string) bool {
	return devicepolicy.IsIdentifier(s, maxIdentifierLen)
}

// validGroupID accepts the optional group_id: identifier charset, up to
// maxGroupIDLen (an MLS group id is at most 128 bytes, hex-encoded 256).
func validGroupID(s string) bool {
	return s == "" || devicepolicy.IsIdentifier(s, maxGroupIDLen)
}

// roomParam reads the {room} path value and rejects anything that is not an
// identifier (review 2 G-M2): the mux hands over the decoded path segment, so
// without this a room name could carry newlines into the founding-commit log
// line or Unicode look-alikes into the first-come room namespace.
func (s *relay) roomParam(w http.ResponseWriter, req *http.Request) (string, bool) {
	room := req.PathValue("room")
	if !validIdentifier(room) {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "room"})
		return "", false
	}
	return room, true
}

// ---- HTTP plumbing ----

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	if err := enc.Encode(v); err != nil {
		log.Printf("write response: %v", err)
	}
}

func (s *relay) fail(w http.ResponseWriter, status int, e apiError) {
	writeJSON(w, status, e)
}

// failJSON maps a strict-JSON decode failure to its 400 code.
func (s *relay) failJSON(w http.ResponseWriter, err error) {
	if errors.Is(err, errJSONTooDeep) {
		s.fail(w, http.StatusBadRequest, apiError{Error: "json_too_deep"})
		return
	}
	s.fail(w, http.StatusBadRequest, apiError{Error: "bad_request", Detail: err.Error()})
}

func (s *relay) readBody(w http.ResponseWriter, req *http.Request) ([]byte, bool) {
	req.Body = http.MaxBytesReader(w, req.Body, maxBodyBytes)
	body, err := io.ReadAll(req.Body)
	if err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			s.fail(w, http.StatusRequestEntityTooLarge, apiError{Error: "body_too_large"})
		} else {
			s.fail(w, http.StatusBadRequest, apiError{Error: "bad_request", Detail: err.Error()})
		}
		return nil, false
	}
	if len(body) == 0 {
		s.fail(w, http.StatusBadRequest, apiError{Error: "empty_body"})
		return nil, false
	}
	return body, true
}

// ---- caller identity (C1) ----

// caller is the outcome of the JWT step: authenticated is false only when
// the relay runs with the verifier disabled (local dev).
type caller struct {
	authenticated bool
	subject       string
}

// authenticate verifies the CF Access assertion before any body is read. A
// missing or invalid token is a bare 401; the reason goes to the log only.
func (s *relay) authenticate(w http.ResponseWriter, req *http.Request) (caller, bool) {
	if s.access == nil {
		return caller{}, true
	}
	token := bearerToken(req)
	if token == "" {
		log.Printf("auth %s %s: missing token", req.Method, req.URL.Path)
		w.Header().Set("WWW-Authenticate", `Bearer realm="native-mls-v2"`)
		s.fail(w, http.StatusUnauthorized, apiError{Error: "unauthorized"})
		return caller{}, false
	}
	claims, err := s.access.verify(token)
	if err != nil {
		log.Printf("auth %s %s: %v", req.Method, req.URL.Path, err)
		w.Header().Set("WWW-Authenticate", `Bearer realm="native-mls-v2", error="invalid_token"`)
		s.fail(w, http.StatusUnauthorized, apiError{Error: "unauthorized"})
		return caller{}, false
	}
	return caller{authenticated: true, subject: claims.Subject}, true
}

// bindDevice ties the verified subject to the device the request claims to
// act as: the device must be policy-active and carry subject == claims.sub.
// Unknown, revoked and foreign-subject devices all get the same 403 so the
// response does not reveal which. The in-transaction policy check stays as
// the second line (revoke/POST race), this is the identity line.
func (s *relay) bindDevice(w http.ResponseWriter, c caller, device string) bool {
	if !c.authenticated {
		return true
	}
	active, err := s.enforceDevicePolicy()
	if err != nil {
		log.Printf("auth bind device=%s: %v", device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "device_policy_unavailable", Detail: "device policy chain unreadable; writes fail closed"})
		return false
	}
	if active == nil {
		log.Printf("auth bind device=%s: no device policy store; refusing", device)
		s.fail(w, http.StatusForbidden, apiError{Error: "device_subject_mismatch"})
		return false
	}
	d, ok := active[device]
	switch {
	case !ok:
		log.Printf("auth bind device=%s: not an active policy device", device)
	case d.Subject != c.subject:
		log.Printf("auth bind device=%s: subject mismatch", device)
	default:
		return true
	}
	s.fail(w, http.StatusForbidden, apiError{Error: "device_subject_mismatch"})
	return false
}

func (s *relay) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v2/rooms/{room}/keypackages", s.handlePostKeyPackages)
	mux.HandleFunc("GET /v2/rooms/{room}/keypackages", s.handleConsumeKeyPackage)
	mux.HandleFunc("POST /v2/rooms/{room}/events", s.handlePostEvent)
	mux.HandleFunc("GET /v2/rooms/{room}/events", s.handleGetEvents)
	mux.HandleFunc("POST /v2/rooms/{room}/close", s.handleCloseRoom)
	mux.HandleFunc("GET /v2/health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})
	return mux
}

// ---- handlers ----

// handlePostKeyPackages stores a device's key packages (≤4 live per device,
// TTL 7d, expired rows swept in the same transaction). Byte-identical
// replays of a ref are idempotent (200), different bytes under a stored ref
// are 409 (M5).
func (s *relay) handlePostKeyPackages(w http.ResponseWriter, req *http.Request) {
	room, ok := s.roomParam(w, req)
	if !ok {
		return
	}
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	body, ok := s.readBody(w, req)
	if !ok {
		return
	}
	var post keyPackagePost
	if err := strictJSON(body, &post); err != nil {
		s.failJSON(w, err)
		return
	}
	if post.Device == "" {
		s.fail(w, http.StatusBadRequest, apiError{Error: "device_required"})
		return
	}
	if !validIdentifier(post.Device) {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "device"})
		return
	}
	if len(post.Packages) == 0 {
		s.fail(w, http.StatusBadRequest, apiError{Error: "packages_required"})
		return
	}
	for i, pkg := range post.Packages {
		if pkg.Ref == "" || len(pkg.Bytes) == 0 {
			s.fail(w, http.StatusBadRequest, apiError{Error: "bad_package", Detail: fmt.Sprintf("packages[%d] needs non-empty ref and bytes", i)})
			return
		}
	}
	if !s.bindDevice(w, c, post.Device) {
		return
	}
	res, err := s.postKeyPackages(room, post.Device, post.Packages)
	switch {
	case err == nil:
		status := http.StatusCreated
		if res.Stored == 0 {
			status = http.StatusOK
		}
		writeJSON(w, status, res)
	case errors.Is(err, errClosed):
		s.fail(w, http.StatusGone, apiError{Error: "room_closed"})
	case errors.As(err, new(policyUnavailable)):
		log.Printf("post keypackages room=%s: %v", room, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "device_policy_unavailable", Detail: "device policy chain unreadable; writes fail closed"})
	case errors.As(err, new(deviceNotAllowed)):
		var na deviceNotAllowed
		errors.As(err, &na)
		s.fail(w, http.StatusForbidden, apiError{Error: "device_not_allowed", Detail: na.Error()})
	case errors.As(err, new(keyPackageLimit)):
		var lim keyPackageLimit
		errors.As(err, &lim)
		s.fail(w, http.StatusConflict, apiError{Error: "key_package_limit", Live: lim.Live, Max: lim.Max})
	case errors.As(err, new(keyPackageRefConflict)):
		var rc keyPackageRefConflict
		errors.As(err, &rc)
		s.fail(w, http.StatusConflict, apiError{Error: "key_package_ref_conflict", Detail: rc.Error()})
	default:
		log.Printf("post keypackages room=%s: %v", room, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
	}
}

// handleConsumeKeyPackage atomically marks one live package as consumed by
// the requesting (adding) device; concurrent consumers get distinct packages.
// ?consumer= is the caller (bound to the JWT subject), ?device= the target.
func (s *relay) handleConsumeKeyPackage(w http.ResponseWriter, req *http.Request) {
	room, ok := s.roomParam(w, req)
	if !ok {
		return
	}
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	device := req.URL.Query().Get("device")
	consumer := req.URL.Query().Get("consumer")
	if device == "" || consumer == "" {
		s.fail(w, http.StatusBadRequest, apiError{Error: "device_and_consumer_required"})
		return
	}
	if !validIdentifier(device) || !validIdentifier(consumer) {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "device or consumer"})
		return
	}
	if !s.bindDevice(w, c, consumer) {
		return
	}
	pkg, err := s.consumeKeyPackage(room, device, consumer)
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, pkg)
	case errors.Is(err, errNoRoom):
		s.fail(w, http.StatusNotFound, apiError{Error: "no_such_room"})
	case errors.Is(err, errNoKeyPackage):
		s.fail(w, http.StatusNotFound, apiError{Error: "no_live_key_package"})
	case errors.Is(err, errClosed):
		s.fail(w, http.StatusGone, apiError{Error: "room_closed"})
	case errors.As(err, new(policyUnavailable)):
		log.Printf("consume keypackage room=%s: %v", room, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "device_policy_unavailable", Detail: "device policy chain unreadable; writes fail closed"})
	case errors.As(err, new(deviceNotAllowed)):
		var na deviceNotAllowed
		errors.As(err, &na)
		s.fail(w, http.StatusForbidden, apiError{Error: "device_not_allowed", Detail: na.Error()})
	case errors.Is(err, errNotMember):
		s.fail(w, http.StatusForbidden, apiError{Error: "not_a_member"})
	default:
		log.Printf("consume keypackage room=%s device=%s: %v", room, device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
	}
}

// handlePostEvent appends one event under CAS discipline. 200 marks a byte
// equal replay (K4), 409 carries the current epoch/revision (§3.4).
func (s *relay) handlePostEvent(w http.ResponseWriter, req *http.Request) {
	room, ok := s.roomParam(w, req)
	if !ok {
		return
	}
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	body, ok := s.readBody(w, req)
	if !ok {
		return
	}
	var post eventPost
	if err := strictJSON(body, &post); err != nil {
		s.failJSON(w, err)
		return
	}
	switch post.Kind {
	case "commit", "welcome", "application":
	default:
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_kind", Detail: "kind must be commit, welcome or application"})
		return
	}
	if post.Device == "" || post.ClientID == "" {
		s.fail(w, http.StatusBadRequest, apiError{Error: "device_and_client_id_required"})
		return
	}
	if !validIdentifier(post.Device) {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "device"})
		return
	}
	// G-H4: every stored column outside `bytes` is shape-bounded so the
	// per-room byte cap (which counts `bytes` only) cannot be sidestepped
	// through a 1 MiB client_id or group_id or a ten-thousand-entry list.
	if !validIdentifier(post.ClientID) {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "client_id"})
		return
	}
	if !validGroupID(post.GroupID) {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "group_id"})
		return
	}
	if len(post.Targets) > maxTargets {
		s.fail(w, http.StatusBadRequest, apiError{Error: "too_many_targets", Detail: fmt.Sprintf("at most %d welcome targets", maxTargets)})
		return
	}
	if len(post.Members) > maxMembers {
		s.fail(w, http.StatusBadRequest, apiError{Error: "too_many_members", Detail: fmt.Sprintf("at most %d replicated members", maxMembers)})
		return
	}
	for i, t := range post.Targets {
		if !validIdentifier(t) {
			s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: fmt.Sprintf("targets[%d]", i)})
			return
		}
	}
	for i, m := range post.Members {
		if !validIdentifier(m.Device) || !validIdentifier(m.Actor) {
			s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: fmt.Sprintf("members[%d]", i)})
			return
		}
	}
	if len(post.Bytes) == 0 {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bytes_required"})
		return
	}
	if post.Kind == "welcome" && len(post.Targets) == 0 {
		s.fail(w, http.StatusBadRequest, apiError{Error: "welcome_targets_required"})
		return
	}
	// M3b: with a device-policy store wired, a commit must replicate the
	// post-commit member list in the outer JSON (§3.3). Structural faults are
	// 400; membership and policy verdicts happen inside the store transaction.
	if s.devices != nil && post.Kind == "commit" {
		if len(post.Members) == 0 {
			s.fail(w, http.StatusBadRequest, apiError{Error: "commit_members_required", Detail: "a commit must replicate the post-commit member list"})
			return
		}
		seen := map[string]bool{}
		senderListed := false
		for i, m := range post.Members {
			if seen[m.Device] {
				s.fail(w, http.StatusBadRequest, apiError{Error: "duplicate_member", Detail: fmt.Sprintf("members[%d] repeats device %q", i, m.Device)})
				return
			}
			seen[m.Device] = true
			if m.Device == post.Device {
				senderListed = true
			}
		}
		if !senderListed {
			s.fail(w, http.StatusBadRequest, apiError{Error: "commit_sender_not_listed", Detail: "the sender device must appear in the replicated member list"})
			return
		}
	}
	if !s.bindDevice(w, c, post.Device) {
		return
	}
	ev := eventInput{
		groupID:  post.GroupID,
		device:   post.Device,
		clientID: post.ClientID,
		kind:     post.Kind,
		epoch:    post.Epoch,
		revision: post.Revision,
		targets:  post.Targets,
		members:  post.Members,
		bytes:    post.Bytes,
	}
	stored, err := s.storeEvent(room, ev)
	switch {
	case err == nil:
		status := http.StatusCreated
		if stored.duplicate {
			status = http.StatusOK
		}
		writeJSON(w, status, eventResponse{Seq: stored.seq, Epoch: stored.epoch, Revision: stored.revision, Duplicate: stored.duplicate})
	case errors.Is(err, errClosed):
		s.fail(w, http.StatusGone, apiError{Error: "room_closed"})
	case errors.As(err, new(casMismatch)):
		var mm casMismatch
		errors.As(err, &mm)
		s.fail(w, http.StatusConflict, apiError{Error: "cas_mismatch", Detail: mm.Error(), Epoch: mm.Epoch, Revision: mm.Revision})
	case errors.As(err, new(clientIDReuse)):
		var reuse clientIDReuse
		errors.As(err, &reuse)
		s.fail(w, http.StatusConflict, apiError{Error: "client_id_reuse", Detail: reuse.Error()})
	case errors.As(err, new(roomBytesCap)):
		var cap roomBytesCap
		errors.As(err, &cap)
		s.fail(w, http.StatusRequestEntityTooLarge, apiError{Error: "room_bytes_cap", Used: cap.Used, Cap: cap.Cap})
	case errors.As(err, new(policyUnavailable)):
		log.Printf("post event room=%s: %v", room, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "device_policy_unavailable", Detail: "device policy chain unreadable; writes fail closed"})
	case errors.As(err, new(deviceNotAllowed)):
		var na deviceNotAllowed
		errors.As(err, &na)
		s.fail(w, http.StatusForbidden, apiError{Error: "device_not_allowed", Detail: na.Error()})
	case errors.As(err, new(commitSenderNotMember)):
		var sm commitSenderNotMember
		errors.As(err, &sm)
		s.fail(w, http.StatusForbidden, apiError{Error: "commit_sender_not_member", Detail: sm.Error()})
	case errors.As(err, new(commitMemberNotActive)):
		var ma commitMemberNotActive
		errors.As(err, &ma)
		s.fail(w, http.StatusForbidden, apiError{Error: "commit_member_not_active", Detail: ma.Error()})
	case errors.As(err, new(commitActorNotInRoster)):
		var ra commitActorNotInRoster
		errors.As(err, &ra)
		s.fail(w, http.StatusForbidden, apiError{Error: "commit_actor_not_in_roster", Detail: ra.Error()})
	case errors.As(err, new(commitActorMismatch)):
		var am commitActorMismatch
		errors.As(err, &am)
		s.fail(w, http.StatusForbidden, apiError{Error: "commit_actor_mismatch", Detail: am.Error()})
	case errors.Is(err, errNotMember):
		// G-H1: application/welcome from an active device that is not a
		// tracked member of a seeded room.
		s.fail(w, http.StatusForbidden, apiError{Error: "not_a_member"})
	case errors.Is(err, errWelcomeTargets):
		s.fail(w, http.StatusBadRequest, apiError{Error: "welcome_targets_required"})
	default:
		log.Printf("post event room=%s: %v", room, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
	}
}

// handleGetEvents returns one page of the per-room total order after ?after=
// (?limit= default 500, max 2000; next_after in the response), filtering
// welcome events not targeted at the requesting device (B4: filter, never
// 403). device is required because filtering is per device.
func (s *relay) handleGetEvents(w http.ResponseWriter, req *http.Request) {
	room, ok := s.roomParam(w, req)
	if !ok {
		return
	}
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
	after := int64(0)
	if raw := req.URL.Query().Get("after"); raw != "" {
		v, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || v < 0 {
			s.fail(w, http.StatusBadRequest, apiError{Error: "bad_after"})
			return
		}
		after = v
	}
	limit := defaultEventsLimit
	if raw := req.URL.Query().Get("limit"); raw != "" {
		v, err := strconv.Atoi(raw)
		if err != nil || v <= 0 {
			s.fail(w, http.StatusBadRequest, apiError{Error: "bad_limit"})
			return
		}
		limit = min(v, maxEventsLimit)
	}
	// M2: ?ack=<seq> is the only thing that moves the device's durable
	// cursor (the application-event pruning gate). A client acks after it
	// has durably processed every event up to seq; `after` stays a pure read
	// offset so a response lost on the wire can be fetched again.
	var ack *int64
	if raw := req.URL.Query().Get("ack"); raw != "" {
		v, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || v < 0 {
			s.fail(w, http.StatusBadRequest, apiError{Error: "bad_ack"})
			return
		}
		ack = &v
	}
	if !s.bindDevice(w, c, device) {
		return
	}
	page, err := s.readEvents(room, device, after, limit, ack)
	var bad badAck
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, eventsResponse{Epoch: page.room.epoch, Revision: page.room.revision, Events: page.rows, NextAfter: page.nextAfter, Cursor: page.cursor})
	case errors.As(err, &bad):
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_ack", Detail: bad.Error()})
	case errors.Is(err, errNotMember):
		s.fail(w, http.StatusForbidden, apiError{Error: "not_a_member"})
	case errors.Is(err, errNoRoom):
		s.fail(w, http.StatusNotFound, apiError{Error: "no_such_room"})
	case errors.Is(err, errClosed):
		s.fail(w, http.StatusGone, apiError{Error: "room_closed"})
	default:
		log.Printf("get events room=%s device=%s: %v", room, device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
	}
}

// handleCloseRoom is the §3.4 deletion path (B1): tombstone the room and
// sweep expired key packages in one write. Every contract route answers 410
// afterwards until an operator removes the database file. The caller names
// itself with ?device= (bound to the JWT subject) and must be a tracked
// member of the room when membership enforcement is on (403 not_a_member);
// an unknown room is 404. Closing an already closed room is idempotent.
func (s *relay) handleCloseRoom(w http.ResponseWriter, req *http.Request) {
	room, ok := s.roomParam(w, req)
	if !ok {
		return
	}
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
	err := s.closeRoomDB(room, device, time.Now().Unix())
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, map[string]bool{"closed": true})
	case errors.Is(err, errNoRoom):
		s.fail(w, http.StatusNotFound, apiError{Error: "no_such_room"})
	case errors.Is(err, errNotMember):
		log.Printf("close room=%s device=%s: not a tracked member", room, device)
		s.fail(w, http.StatusForbidden, apiError{Error: "not_a_member"})
	case errors.As(err, new(policyUnavailable)):
		log.Printf("close room=%s: %v", room, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "device_policy_unavailable", Detail: "device policy chain unreadable; writes fail closed"})
	case errors.As(err, new(deviceNotAllowed)):
		var na deviceNotAllowed
		errors.As(err, &na)
		s.fail(w, http.StatusForbidden, apiError{Error: "device_not_allowed", Detail: na.Error()})
	default:
		log.Printf("close room=%s device=%s: %v", room, device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
	}
}
