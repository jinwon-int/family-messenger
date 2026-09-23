// native-mls v2 relay HTTP surface (#177 §3.4). Four contract routes plus
// the room-closure deletion path and a liveness probe. Strict JSON decoding
// (duplicate keys, unknown fields and explicit nulls rejected, mirroring
// decodeMLS) guards every request body.
package main

import (
	"bytes"
	"crypto/sha256"
	"database/sql"
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
)

// policy carries the §3.4 retention defaults. Tests override the fields
// directly; flags only allow positive overrides on top of the defaults.
type policy struct {
	RoomBytesCap            int64
	KeyPackagesMaxPerDevice int
	KeyPackageTTLSeconds    int64
	CommitWelcomeKeepEpochs int64
	AppEventTTLSeconds      int64
}

func defaultPolicy() policy {
	const day = 24 * 60 * 60
	return policy{
		RoomBytesCap:            64 << 20, // 64 MiB per room (B5)
		KeyPackagesMaxPerDevice: 4,
		KeyPackageTTLSeconds:    7 * day,
		CommitWelcomeKeepEpochs: 8,
		AppEventTTLSeconds:      30 * day,
	}
}

// relay owns the single SQLite connection and the per-room per-device cursor
// map used by application-event pruning. Every write path takes mu, so with
// SetMaxOpenConns(1) exactly one BEGIN IMMEDIATE transaction is in flight at
// a time (B2/B3) and the cursor map cannot drift from the database.
type relay struct {
	mu      sync.Mutex
	db      *sql.DB
	cursors map[string]map[string]int64
	policy  policy
}

// ---- wire types ----

type eventPost struct {
	Device   string   `json:"device"`
	ClientID string   `json:"client_id"`
	Kind     string   `json:"kind"`
	Epoch    int64    `json:"epoch"`
	Revision *int64   `json:"revision"`
	GroupID  string   `json:"group_id"`
	Targets  []string `json:"targets"`
	Bytes    []byte   `json:"bytes"`
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

type eventsResponse struct {
	Epoch    int64       `json:"epoch"`
	Revision int64       `json:"revision"`
	Events   []storedRow `json:"events"`
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

// rejectDuplicateKeys walks the token stream and fails on any object that
// repeats a key, at any depth.
func rejectDuplicateKeys(data []byte) error {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var walkValue func(tok json.Token) error
	var walkNext func() error
	walkNext = func() error {
		tok, err := dec.Token()
		if err != nil {
			return err
		}
		return walkValue(tok)
	}
	walkValue = func(tok json.Token) error {
		delim, ok := tok.(json.Delim)
		if !ok {
			return nil
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
				if err := walkNext(); err != nil {
					return err
				}
			}
			_, err := dec.Token() // closing '}'
			return err
		case '[':
			for dec.More() {
				if err := walkNext(); err != nil {
					return err
				}
			}
			_, err := dec.Token() // closing ']'
			return err
		}
		return errors.New("unexpected delimiter")
	}
	if err := walkNext(); err != nil {
		return err
	}
	if _, err := dec.Token(); err != io.EOF {
		return errors.New("trailing data after JSON value")
	}
	return nil
}

// strictJSON decodes data into v rejecting duplicate keys, unknown fields and
// explicit nulls at the payload top level.
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

func (s *relay) readBody(w http.ResponseWriter, req *http.Request) ([]byte, bool) {
	req.Body = http.MaxBytesReader(w, req.Body, s.policy.RoomBytesCap+(1<<20))
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
// TTL 7d, expired rows swept in the same transaction).
func (s *relay) handlePostKeyPackages(w http.ResponseWriter, req *http.Request) {
	room := req.PathValue("room")
	body, ok := s.readBody(w, req)
	if !ok {
		return
	}
	var post keyPackagePost
	if err := strictJSON(body, &post); err != nil {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_request", Detail: err.Error()})
		return
	}
	if post.Device == "" {
		s.fail(w, http.StatusBadRequest, apiError{Error: "device_required"})
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
	n, err := s.postKeyPackages(room, post.Device, post.Packages)
	switch {
	case err == nil:
		writeJSON(w, http.StatusCreated, map[string]int{"stored": n})
	case errors.Is(err, errClosed):
		s.fail(w, http.StatusGone, apiError{Error: "room_closed"})
	case errors.As(err, new(keyPackageLimit)):
		var lim keyPackageLimit
		errors.As(err, &lim)
		s.fail(w, http.StatusConflict, apiError{Error: "key_package_limit", Live: lim.Live, Max: lim.Max})
	default:
		log.Printf("post keypackages room=%s: %v", room, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
	}
}

// handleConsumeKeyPackage atomically marks one live package as consumed by
// the requesting (adding) device; concurrent consumers get distinct packages.
func (s *relay) handleConsumeKeyPackage(w http.ResponseWriter, req *http.Request) {
	room := req.PathValue("room")
	device := req.URL.Query().Get("device")
	consumer := req.URL.Query().Get("consumer")
	if device == "" || consumer == "" {
		s.fail(w, http.StatusBadRequest, apiError{Error: "device_and_consumer_required"})
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
	default:
		log.Printf("consume keypackage room=%s device=%s: %v", room, device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
	}
}

// handlePostEvent appends one event under CAS discipline. 200 marks a byte
// equal replay (K4), 409 carries the current epoch/revision (§3.4).
func (s *relay) handlePostEvent(w http.ResponseWriter, req *http.Request) {
	room := req.PathValue("room")
	body, ok := s.readBody(w, req)
	if !ok {
		return
	}
	var post eventPost
	if err := strictJSON(body, &post); err != nil {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_request", Detail: err.Error()})
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
	if len(post.Bytes) == 0 {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bytes_required"})
		return
	}
	if post.Kind == "welcome" && len(post.Targets) == 0 {
		s.fail(w, http.StatusBadRequest, apiError{Error: "welcome_targets_required"})
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
	case errors.Is(err, errWelcomeTargets):
		s.fail(w, http.StatusBadRequest, apiError{Error: "welcome_targets_required"})
	default:
		log.Printf("post event room=%s: %v", room, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
	}
}

// handleGetEvents returns the per-room total order after ?after=, filtering
// welcome events not targeted at the requesting device (B4: filter, never
// 403). device is required because filtering is per device.
func (s *relay) handleGetEvents(w http.ResponseWriter, req *http.Request) {
	room := req.PathValue("room")
	device := req.URL.Query().Get("device")
	if device == "" {
		s.fail(w, http.StatusBadRequest, apiError{Error: "device_required"})
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
	rows, roomRow, err := s.readEvents(room, device, after)
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, eventsResponse{Epoch: roomRow.epoch, Revision: roomRow.revision, Events: rows})
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
// afterwards until an operator removes the database file.
func (s *relay) handleCloseRoom(w http.ResponseWriter, req *http.Request) {
	room := req.PathValue("room")
	if err := s.closeRoomDB(room, time.Now().Unix()); err != nil {
		log.Printf("close room=%s: %v", room, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"closed": true})
}
