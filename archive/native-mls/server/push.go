package main

import (
	"context"
	"database/sql"
	"log"
	"net/http"
	"strings"
	"time"
)

// Push registration and delivery (#275 L2 ②, CONTRACTS §2.3).
//
//   - POST   /v2/push/devices {device, apns_token(base64), topic} → 204, idempotent;
//     a new token for the same device replaces the old one (token rotation).
//   - DELETE /v2/push/devices?device= → 204 (also when nothing was registered).
//   - After an application or welcome event commits, member devices whose cursor
//     is behind the new seq (sender excluded) get one APNs alert, sent outside
//     the events transaction and outside s.mu. Failures are logged only; a token
//     Apple reports as gone (410, BadDeviceToken) is deleted if still current.
//
// Commit events do not push: an alert push must show a notification, and a
// roster change is not a new message. The payload carries no plaintext,
// ciphertext or sender — the device fetches the event itself.

const (
	maxAPNsTokenBytes = 100 // Apple device tokens are 32 bytes today; leave headroom, refuse junk
	maxTopicLen       = 155
)

type pushRegistration struct {
	Device    string `json:"device"`
	APNsToken []byte `json:"apns_token"` // standard base64 on the wire (encoding/json)
	Topic     string `json:"topic"`
}

// validTopic: an iOS bundle id (reverse DNS) — letters, digits, '-' and '.',
// no empty labels. Bundle ids are not identifiers (validIdentifier refuses '.').
func validTopic(s string) bool {
	if s == "" || len(s) > maxTopicLen || strings.HasPrefix(s, ".") || strings.HasSuffix(s, ".") || strings.Contains(s, "..") {
		return false
	}
	for _, r := range s {
		if (r < 'a' || r > 'z') && (r < 'A' || r > 'Z') && (r < '0' || r > '9') && r != '-' && r != '.' {
			return false
		}
	}
	return true
}

func (s *relay) handleRegisterPush(w http.ResponseWriter, req *http.Request) {
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	body, ok := s.readBody(w, req)
	if !ok {
		return
	}
	var reg pushRegistration
	if err := strictJSON(body, &reg); err != nil {
		s.failJSON(w, err)
		return
	}
	switch {
	case !validIdentifier(reg.Device):
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_identifier", Detail: "device"})
		return
	case len(reg.APNsToken) == 0 || len(reg.APNsToken) > maxAPNsTokenBytes:
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_apns_token"})
		return
	case !validTopic(reg.Topic):
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_topic"})
		return
	case len(s.pushTopics) > 0 && !s.pushTopics[reg.Topic]:
		s.fail(w, http.StatusBadRequest, apiError{Error: "topic_not_allowed"})
		return
	}
	if !s.bindDevice(w, c, reg.Device) {
		return
	}
	if err := s.savePushDevice(reg, time.Now().Unix()); err != nil {
		log.Printf("push register device=%s: %v", reg.Device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *relay) handleUnregisterPush(w http.ResponseWriter, req *http.Request) {
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
	if err := s.deletePushDevice(device, nil); err != nil {
		log.Printf("push unregister device=%s: %v", device, err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *relay) savePushDevice(reg pushRegistration, now int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`INSERT INTO push_devices (device, token, topic, updated_at) VALUES (?, ?, ?, ?)
ON CONFLICT(device) DO UPDATE SET token = excluded.token, topic = excluded.topic, updated_at = excluded.updated_at`,
		reg.Device, reg.APNsToken, reg.Topic, now)
	return err
}

// deletePushDevice removes the registration; with onlyToken set it removes it
// only while that token is still current, so a token Apple rejected cannot
// erase a rotation that landed in between.
func (s *relay) deletePushDevice(device string, onlyToken []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var err error
	if onlyToken == nil {
		_, err = s.db.Exec(`DELETE FROM push_devices WHERE device = ?`, device)
	} else {
		_, err = s.db.Exec(`DELETE FROM push_devices WHERE device = ? AND token = ?`, device, onlyToken)
	}
	return err
}

type pushTarget struct {
	device string
	token  []byte
	topic  string
}

// pushTargets: registered devices of the room, sender excluded, that are a
// tracked member or hold a cursor not removed by a commit, and whose cursor
// is behind seq (no cursor row counts as 0).
func (s *relay) pushTargets(room, sender string, seq int64) ([]pushTarget, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(`
SELECT p.device, p.token, p.topic FROM push_devices p
WHERE p.device <> ?2
  AND (EXISTS (SELECT 1 FROM mls_members m WHERE m.room = ?1 AND m.device = p.device)
       OR EXISTS (SELECT 1 FROM mls_cursors c WHERE c.room = ?1 AND c.device = p.device AND c.removed_at IS NULL))
  AND COALESCE((SELECT c.seq FROM mls_cursors c WHERE c.room = ?1 AND c.device = p.device), 0) < ?3
ORDER BY p.device`, room, sender, seq)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []pushTarget
	for rows.Next() {
		var t pushTarget
		if err := rows.Scan(&t.device, &t.token, &t.topic); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// notifyEvent runs after a new (non-duplicate) event committed. It never
// blocks the POST: the caller starts it in a goroutine tracked by pushWG.
func (s *relay) notifyEvent(room, sender, kind string, seq int64) {
	if s.push == nil || (kind != "application" && kind != "welcome") {
		return
	}
	s.pushWG.Add(1)
	go func() {
		defer s.pushWG.Done()
		targets, err := s.pushTargets(room, sender, seq)
		if err != nil {
			log.Printf("apns room=%s seq=%d: targets: %v", room, seq, err)
			return
		}
		payload := newPushPayload(room, seq)
		for _, t := range targets {
			res := s.push.send(context.Background(), t.token, t.topic, payload)
			switch {
			case res.err != nil:
				log.Printf("apns room=%s seq=%d device=%s: %v", room, seq, t.device, res.err)
			case res.status == http.StatusOK:
			case res.gone():
				log.Printf("apns room=%s seq=%d device=%s: status=%d reason=%s; dropping token", room, seq, t.device, res.status, res.reason)
				if err := s.deletePushDevice(t.device, t.token); err != nil && err != sql.ErrNoRows {
					log.Printf("apns device=%s: drop token: %v", t.device, err)
				}
			default:
				log.Printf("apns room=%s seq=%d device=%s: status=%d reason=%s", room, seq, t.device, res.status, res.reason)
			}
		}
	}()
}
