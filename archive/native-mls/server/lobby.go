// Lobby key packages and pending-Welcome discovery (#380 P5-1).
//
// The per-room key-package pool (mls_keypackages) needs the device to have
// published into a room before anyone can add it there, so a steward bot
// could never invite a human device into a room that does not exist yet. The
// lobby is a room-independent pool: a device publishes once, and any
// policy-active device that is about to found a room — or is a member of an
// existing one — consumes from it. consumed_room records where the package
// went so the device can tell which room a Welcome belongs to.
//
// GET /v2/lobby/welcomes closes the loop on the receiving side: the Welcome
// itself travels on the room log (filtered to its targets by GET /events), but
// a device only knows to poll a room it was told about. The listing names the
// rooms holding an unread Welcome for the device, read-only — the device then
// reads and acks through the existing room routes.
//
// Hardening parity with the room routes: same body limit, strict JSON,
// identifier rule, caller binding, in-transaction policy re-check and the
// single-writer mutex. Package bytes are never logged.
package main

import (
	"database/sql"
	"errors"
	"log"
	"net/http"
	"time"
)

// maxListedWelcomes bounds GET /v2/lobby/welcomes: one row per unread Welcome,
// far beyond what one device can be invited into between two polls.
const maxListedWelcomes = 100

// lobbyStatusResponse is GET /v2/lobby/status: the device's live lobby count
// against the policy bounds, for the app's replenish decision.
type lobbyStatusResponse struct {
	Device     string `json:"device"`
	Live       int    `json:"live"`
	Max        int    `json:"max"`
	TTLSeconds int64  `json:"ttl_seconds"`
}

// pendingWelcome is one room holding a Welcome the device has not read past.
type pendingWelcome struct {
	Room      string `json:"room"`
	Seq       int64  `json:"seq"`
	Epoch     int64  `json:"epoch"`
	CreatedAt int64  `json:"created_at"`
}

// lobbyDeleteResponse is DELETE /v2/lobby/keypackages: how many unconsumed
// lobby packages of the device were withdrawn (#389).
type lobbyDeleteResponse struct {
	Device  string `json:"device"`
	Deleted int64  `json:"deleted"`
}

type welcomesResponse struct {
	Welcomes []pendingWelcome `json:"welcomes"`
}

// ---- handlers ----

// handlePostLobbyKeyPackages stores a device's lobby packages (≤
// LobbyKeyPackagesMaxPerDevice live, LobbyKeyPackageTTLSeconds TTL, expired
// rows swept in the same transaction). Byte-identical replays of a ref are
// idempotent (200), different bytes under a stored ref are 409.
func (s *relay) handlePostLobbyKeyPackages(w http.ResponseWriter, req *http.Request) {
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	post, ok := s.readKeyPackagePost(w, req)
	if !ok {
		return
	}
	if !s.bindDevice(w, c, post.Device) {
		return
	}
	res, err := s.postLobbyKeyPackages(post.Device, post.Packages)
	switch {
	case err == nil:
		status := http.StatusCreated
		if res.Stored == 0 {
			status = http.StatusOK
		}
		writeJSON(w, status, res)
	case errors.As(err, new(policyUnavailable)):
		log.Printf("post lobby keypackages device=%s: %v", post.Device, err)
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
		log.Printf("post lobby keypackages device=%s: %v", post.Device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
	}
}

// handleConsumeLobbyKeyPackage atomically spends the oldest live lobby package
// of ?device= for ?consumer= (the caller, bound to the JWT subject) on behalf
// of ?room=. The room may not exist yet — the consumer is about to found it
// with its first commit and the room row is NOT created here; an existing room
// with a tracked membership requires the consumer to be a member, a closed
// room is 410.
func (s *relay) handleConsumeLobbyKeyPackage(w http.ResponseWriter, req *http.Request) {
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	q := req.URL.Query()
	device, consumer, room := q.Get("device"), q.Get("consumer"), q.Get("room")
	if device == "" || consumer == "" || room == "" {
		s.fail(w, http.StatusBadRequest, apiError{Error: "device_consumer_and_room_required"})
		return
	}
	for _, p := range []struct{ name, value string }{{"device", device}, {"consumer", consumer}, {"room", room}} {
		if !validIdentifier(p.value) {
			s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: p.name})
			return
		}
	}
	if !s.bindDevice(w, c, consumer) {
		return
	}
	pkg, err := s.consumeLobbyKeyPackage(device, consumer, room)
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, pkg)
	case errors.Is(err, errNoKeyPackage):
		s.fail(w, http.StatusNotFound, apiError{Error: "no_live_key_package"})
	case errors.Is(err, errClosed):
		s.fail(w, http.StatusGone, apiError{Error: "room_closed"})
	case errors.Is(err, errNotMember):
		s.fail(w, http.StatusForbidden, apiError{Error: "not_a_member"})
	case errors.As(err, new(policyUnavailable)):
		log.Printf("consume lobby keypackage room=%s: %v", room, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "device_policy_unavailable", Detail: "device policy chain unreadable; writes fail closed"})
	case errors.As(err, new(deviceNotAllowed)):
		var na deviceNotAllowed
		errors.As(err, &na)
		s.fail(w, http.StatusForbidden, apiError{Error: "device_not_allowed", Detail: na.Error()})
	default:
		log.Printf("consume lobby keypackage room=%s device=%s: %v", room, device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
	}
}

// handleDeleteLobbyKeyPackages withdraws every unconsumed lobby package of
// ?device= (bound to the JWT subject) — the app calls it before 「이 기기
// 지우기」 discards the signing key, so no inviter spends a package whose
// Welcome nobody can open (#389). Consumed rows stay until they expire: they
// carry consumed_room, the bookkeeping a pending Welcome is matched by. No
// policy gate — a device may always retract its own packages. Idempotent:
// nothing left is 200 with deleted=0.
func (s *relay) handleDeleteLobbyKeyPackages(w http.ResponseWriter, req *http.Request) {
	c, device, ok := s.lobbyDeviceParam(w, req)
	if !ok || !s.bindDevice(w, c, device) {
		return
	}
	deleted, err := s.deleteLobbyKeyPackages(device)
	if err != nil {
		log.Printf("delete lobby keypackages device=%s: %v", device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
		return
	}
	writeJSON(w, http.StatusOK, lobbyDeleteResponse{Device: device, Deleted: deleted})
}

// handleLobbyStatus reports the device's live lobby count and the policy
// bounds (expired rows swept first).
func (s *relay) handleLobbyStatus(w http.ResponseWriter, req *http.Request) {
	c, device, ok := s.lobbyDeviceParam(w, req)
	if !ok || !s.bindDevice(w, c, device) {
		return
	}
	live, err := s.lobbyLive(device)
	if err != nil {
		log.Printf("lobby status device=%s: %v", device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
		return
	}
	writeJSON(w, http.StatusOK, lobbyStatusResponse{
		Device:     device,
		Live:       live,
		Max:        s.policy.LobbyKeyPackagesMaxPerDevice,
		TTLSeconds: s.policy.LobbyKeyPackageTTLSeconds,
	})
}

// handleLobbyWelcomes lists the open rooms holding a Welcome that targets the
// device and lies past its durable cursor. Read-only: nothing moves until the
// device reads and acks through GET /v2/rooms/{room}/events.
func (s *relay) handleLobbyWelcomes(w http.ResponseWriter, req *http.Request) {
	c, device, ok := s.lobbyDeviceParam(w, req)
	if !ok || !s.bindDevice(w, c, device) {
		return
	}
	welcomes, err := s.pendingWelcomes(device)
	if err != nil {
		log.Printf("lobby welcomes device=%s: %v", device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
		return
	}
	writeJSON(w, http.StatusOK, welcomesResponse{Welcomes: welcomes})
}

// lobbyDeviceParam authenticates and reads the required ?device= identifier
// shared by the status and welcomes routes.
func (s *relay) lobbyDeviceParam(w http.ResponseWriter, req *http.Request) (caller, string, bool) {
	c, ok := s.authenticate(w, req)
	if !ok {
		return caller{}, "", false
	}
	device := req.URL.Query().Get("device")
	if device == "" {
		s.fail(w, http.StatusBadRequest, apiError{Error: "device_required"})
		return caller{}, "", false
	}
	if !validIdentifier(device) {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "device"})
		return caller{}, "", false
	}
	return c, device, true
}

// ---- store ----

// sweepLobbyKeyPackages deletes expired lobby rows inside the caller's
// transaction (consumed rows are kept until they expire).
func sweepLobbyKeyPackages(tx *sql.Tx, now int64) error {
	_, err := tx.Exec(`DELETE FROM mls_lobby_keypackages WHERE expires_at <= ?`, now)
	return err
}

// countLobbyLive returns the device's live (unconsumed, unexpired) lobby rows.
func countLobbyLive(tx *sql.Tx, device string, now int64) (int, error) {
	var live int
	err := tx.QueryRow(`SELECT COUNT(*) FROM mls_lobby_keypackages WHERE device = ? AND consumed_by IS NULL AND expires_at > ?`,
		device, now).Scan(&live)
	return live, err
}

// postLobbyKeyPackages mirrors postKeyPackages without the room: policy gate,
// expiry sweep, byte-identical replay as duplicate, ref conflict, live cap,
// insert — one BEGIN IMMEDIATE transaction under the relay mutex.
func (s *relay) postLobbyKeyPackages(device string, pkgs []keyPackageInput) (keyPackagesResult, error) {
	now := time.Now().Unix()
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return keyPackagesResult{}, err
	}
	defer tx.Rollback()
	if active, err := s.enforceDevicePolicy(); err != nil {
		return keyPackagesResult{}, err
	} else if active != nil {
		if _, ok := active[device]; !ok {
			return keyPackagesResult{}, deviceNotAllowed{Device: device}
		}
	}
	if err := sweepLobbyKeyPackages(tx, now); err != nil {
		return keyPackagesResult{}, err
	}
	var fresh []keyPackageInput
	res := keyPackagesResult{}
	for _, pkg := range pkgs {
		var existing []byte
		err := tx.QueryRow(`SELECT bytes FROM mls_lobby_keypackages WHERE device = ? AND ref = ?`, device, pkg.Ref).Scan(&existing)
		switch {
		case err == nil:
			if string(existing) != string(pkg.Bytes) {
				return keyPackagesResult{}, keyPackageRefConflict{Ref: pkg.Ref}
			}
			res.Duplicates++
		case errors.Is(err, sql.ErrNoRows):
			fresh = append(fresh, pkg)
		default:
			return keyPackagesResult{}, err
		}
	}
	live, err := countLobbyLive(tx, device, now)
	if err != nil {
		return keyPackagesResult{}, err
	}
	if live+len(fresh) > s.policy.LobbyKeyPackagesMaxPerDevice {
		return keyPackagesResult{}, keyPackageLimit{live, s.policy.LobbyKeyPackagesMaxPerDevice}
	}
	for _, pkg := range fresh {
		if _, err := tx.Exec(`INSERT INTO mls_lobby_keypackages (device, ref, bytes, created_at, expires_at) VALUES (?, ?, ?, ?, ?)`,
			device, pkg.Ref, pkg.Bytes, now, now+s.policy.LobbyKeyPackageTTLSeconds); err != nil {
			return keyPackagesResult{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return keyPackagesResult{}, err
	}
	res.Stored = len(fresh)
	res.Live = live + len(fresh)
	return res, nil
}

// consumeLobbyKeyPackage spends the oldest live lobby package of device for
// consumer, recording the room it is meant for. Room rule: a room that does
// not exist is fine (the consumer founds it with its first commit; no row is
// created here); a closed room is errClosed; a room with a tracked membership
// admits members only (errNotMember). With enforcement on the consumer must
// be policy-active at write time (the handler's bind ran before the
// transaction).
func (s *relay) consumeLobbyKeyPackage(device, consumer, room string) (storedKeyPackage, error) {
	now := time.Now().Unix()
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return storedKeyPackage{}, err
	}
	defer tx.Rollback()
	if active, err := s.enforceDevicePolicy(); err != nil {
		return storedKeyPackage{}, err
	} else if active != nil {
		if _, ok := active[consumer]; !ok {
			return storedKeyPackage{}, deviceNotAllowed{Device: consumer}
		}
	}
	row, err := readRoom(tx, room)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		// Not founded yet: the consumer's commit will create it.
	case err != nil:
		return storedKeyPackage{}, err
	case row.closed:
		return storedKeyPackage{}, errClosed
	default:
		tracked, err := readMembers(tx, room)
		if err != nil {
			return storedKeyPackage{}, err
		}
		if len(tracked) > 0 && !memberOf(tracked, consumer) {
			return storedKeyPackage{}, errNotMember
		}
	}
	if err := sweepLobbyKeyPackages(tx, now); err != nil {
		return storedKeyPackage{}, err
	}
	pkg := storedKeyPackage{}
	err = tx.QueryRow(`SELECT ref, bytes, expires_at FROM mls_lobby_keypackages
		WHERE device = ? AND consumed_by IS NULL AND expires_at > ?
		ORDER BY rowid LIMIT 1`, device, now).Scan(&pkg.Ref, &pkg.Bytes, &pkg.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return storedKeyPackage{}, errNoKeyPackage
	}
	if err != nil {
		return storedKeyPackage{}, err
	}
	if _, err := tx.Exec(`UPDATE mls_lobby_keypackages SET consumed_by = ?, consumed_room = ? WHERE device = ? AND ref = ?`,
		consumer, room, device, pkg.Ref); err != nil {
		return storedKeyPackage{}, err
	}
	if err := tx.Commit(); err != nil {
		return storedKeyPackage{}, err
	}
	return pkg, nil
}

// lobbyLive sweeps expired rows and returns the device's live lobby count.
func (s *relay) lobbyLive(device string) (int, error) {
	now := time.Now().Unix()
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	if err := sweepLobbyKeyPackages(tx, now); err != nil {
		return 0, err
	}
	live, err := countLobbyLive(tx, device, now)
	if err != nil {
		return 0, err
	}
	return live, tx.Commit()
}

// deleteLobbyKeyPackages removes the device's unconsumed lobby rows (live or
// expired) and sweeps expired ones, in one transaction under the mutex.
func (s *relay) deleteLobbyKeyPackages(device string) (int64, error) {
	now := time.Now().Unix()
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	res, err := tx.Exec(`DELETE FROM mls_lobby_keypackages WHERE device = ? AND consumed_by IS NULL`, device)
	if err != nil {
		return 0, err
	}
	deleted, err := res.RowsAffected()
	if err != nil {
		return 0, err
	}
	if err := sweepLobbyKeyPackages(tx, now); err != nil {
		return 0, err
	}
	return deleted, tx.Commit()
}

// pendingWelcomes lists, oldest first, the open rooms whose log holds a
// welcome event targeting device that the device's durable cursor has not
// passed (no cursor row, or cursor.seq < event.seq). targets is stored as
// encodeTargets' comma-joined list; the match is on the whole identifier via
// instr over ','||targets||',' (LIKE would treat '_' in an identifier as a
// wildcard). Read-only: the cursor moves only through GET /events?ack=.
func (s *relay) pendingWelcomes(device string) ([]pendingWelcome, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	rows, err := tx.Query(`
SELECT e.room, e.seq, e.epoch, e.created_at
FROM mls_events e
JOIN mls_rooms r ON r.room = e.room
LEFT JOIN mls_cursors c ON c.room = e.room AND c.device = ?1
WHERE e.kind = 'welcome'
  AND e.targets IS NOT NULL
  AND instr(',' || e.targets || ',', ',' || ?1 || ',') > 0
  AND r.closed_at IS NULL
  AND (c.seq IS NULL OR c.seq < e.seq)
ORDER BY e.created_at, e.room, e.seq
LIMIT ?2`, device, maxListedWelcomes)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []pendingWelcome{}
	for rows.Next() {
		var pw pendingWelcome
		if err := rows.Scan(&pw.Room, &pw.Seq, &pw.Epoch, &pw.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, pw)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, tx.Commit()
}
