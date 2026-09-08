package chat

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/jinwon-int/family-messenger/server/internal/access"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Public, fixed test identities. This is deliberately NOT production authentication.
var tokens = map[string]string{"synthetic-alice": "alice", "synthetic-bob": "bob", "synthetic-charlie": "charlie"}

type API struct {
	authority     *access.Authority
	store         *Store
	streams       chan struct{}
	uploadSlots   chan struct{}
	downloadSlots chan struct{}
}

func NewHandler(store *Store) http.Handler {
	return &API{store: store, streams: make(chan struct{}, 16), uploadSlots: make(chan struct{}, 2), downloadSlots: make(chan struct{}, 2)}
}

func (a *API) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(5 * time.Second))
	// Loopback Host plus exact same-origin browser requests only; no CORS.
	host, _, e := net.SplitHostPort(r.Host)
	origins := r.Header.Values("Origin")
	site := r.Header.Get("Sec-Fetch-Site")
	asset := r.Method == "GET" && isAsset(r.URL.Path)
	if e != nil || host != "127.0.0.1" || len(origins) > 1 || (len(origins) == 1 && origins[0] != "http://"+r.Host) || (site != "" && site != "same-origin" && !(asset && site == "none")) {
		http.Error(w, "same-origin local clients only", http.StatusForbidden)
		return
	}
	if asset && r.URL.RawPath == "" && r.URL.RawQuery == "" {
		serveAsset(w, r, a.authority != nil)
		return
	}
	var actor string
	if a.authority != nil {
		grant, err := a.authority.Verify(r)
		if err != nil {
			http.Error(w, "unauthorized", 401)
			return
		}
		actor = grant.Principal().Actor
		// This Store still contains only synthetic actors. Explicit mapping is
		// required; a signed new subject never creates a database actor implicitly.
		if !actors[actor] {
			http.Error(w, "unenrolled app actor", 403)
			return
		}
		r = r.WithContext(context.WithValue(r.Context(), grantKey{}, grant))
	} else {
		if len(r.Header.Values("Authorization")) != 1 {
			http.Error(w, "unauthorized", 401)
			return
		}
		var ok bool
		actor, ok = tokens[strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")]
		if !ok || !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
			http.Error(w, "unauthorized", 401)
			return
		}
	}
	// The browser binds each request to its last verified app actor. A changed
	// upstream account must not send an old tab's pending operation as that actor.
	if expected := r.Header.Values("X-Family-Actor"); len(expected) > 0 && (len(expected) != 1 || expected[0] != actor) {
		http.Error(w, "identity changed", 401)
		return
	}
	w.Header().Set("X-Family-Actor", actor)
	if r.URL.Path == "/v1/session" && r.Method == "GET" && r.URL.RawQuery == "" {
		if err := authorize(r, func() error {
			mode, owner := "fixture", false
			if g, ok := r.Context().Value(grantKey{}).(*access.Grant); ok {
				mode, owner = "signed", g.Principal().Owner
			}
			writeJSON(w, 200, struct {
				Mode  string `json:"mode"`
				Actor string `json:"actor"`
				Owner bool   `json:"owner"`
			}{mode, actor, owner})
			return nil
		}); err != nil {
			fail(w, err)
		}
		return
	}
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	// Uploads/SSE/downloads acquire authority only at bounded state/write steps.
	streaming := len(parts) >= 4 && parts[0] == "v1" && parts[1] == "rooms" && (parts[3] == "attachments" || parts[3] == "events")
	if streaming {
		a.route(w, r, actor)
		return
	}
	// Read small JSON bodies before acquiring identity authority too. A slow
	// client cannot hold account revocation, and expiry is rechecked afterwards.
	if a.authority != nil && (r.Method == "POST" || r.Method == "PUT") {
		control := http.NewResponseController(w)
		if control.SetReadDeadline(time.Now().Add(5*time.Second)) != nil {
			fail(w, ErrInvalid)
			return
		}
		limit := int64(24 * 1024)
		if strings.HasPrefix(r.URL.Path, "/v1/mls/") {
			limit = 96 * 1024
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, limit))
		if err != nil {
			fail(w, ErrInvalid)
			return
		}
		_ = control.SetReadDeadline(time.Time{})
		r.Body = io.NopCloser(bytes.NewReader(body))
	}
	if err := authorize(r, func() error { a.route(w, r, actor); return nil }); err != nil {
		fail(w, err)
	}
}

type grantKey struct{}

func authorize(r *http.Request, fn func() error) error {
	if g, ok := r.Context().Value(grantKey{}).(*access.Grant); ok {
		if e := g.Run(fn); e != nil {
			if errors.Is(e, access.ErrDenied) {
				return ErrForbidden
			}
			return e
		}
		return nil
	}
	return fn()
}

// NewAccessHandler is an isolated integration surface, not an exposed CF
// deployment or a new fixture fallback. The CLI still runs public synthetic mode.
func NewAccessHandler(store *Store, authority *access.Authority) (http.Handler, error) {
	if store == nil || authority == nil {
		return nil, ErrInvalid
	}
	a := NewHandler(store).(*API)
	a.authority = authority
	return a, nil
}
func (a *API) route(w http.ResponseWriter, r *http.Request, actor string) {
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if r.URL.RawPath != "" || r.URL.Path != "/"+strings.Join(parts, "/") {
		http.NotFound(w, r)
		return
	}
	if len(parts) >= 3 && parts[0] == "v1" && parts[1] == "mls" {
		a.mlsRoute(w, r, actor, parts)
		return
	}
	if r.Method == "GET" && r.URL.Path == "/health" {
		writeJSON(w, 200, map[string]string{"mode": "synthetic-only", "status": "ok"})
		return
	}
	if r.Method == "GET" && r.URL.Path == "/v1/rooms" {
		a.store.mu.Lock()
		defer a.store.mu.Unlock()
		rooms, e := a.store.rooms(actor)
		if e != nil {
			fail(w, e)
			return
		}
		writeJSON(w, 200, rooms)
		return
	}
	if r.Method == "POST" && r.URL.Path == "/v1/rooms" {
		var req struct {
			ID      string   `json:"id"`
			Members []string `json:"members"`
		}
		if !decode(w, r, &req) {
			return
		}
		if e := a.store.CreateRoom(req.ID, actor, req.Members); e != nil {
			fail(w, e)
			return
		}
		writeJSON(w, 201, map[string]string{"id": req.ID})
		return
	}
	if len(parts) < 4 || parts[0] != "v1" || parts[1] != "rooms" || !validID(parts[2]) {
		http.NotFound(w, r)
		return
	}
	room := parts[2]
	if parts[3] != "devices" {
		a.store.mu.Lock()
		e := a.store.legacyRoom(room)
		a.store.mu.Unlock()
		if e != nil {
			fail(w, e)
			return
		}
	}
	if parts[3] == "attachments" {
		a.media(w, r, room, actor, parts)
		return
	}
	if len(parts) == 5 && parts[3] == "members" && (r.Method == "PUT" || r.Method == "DELETE") {
		if e := a.store.SetMember(room, actor, parts[4], r.Method == "PUT"); e != nil {
			fail(w, e)
			return
		}
		w.WriteHeader(204)
		return
	}
	if len(parts) != 4 {
		http.NotFound(w, r)
		return
	}
	if parts[3] == "devices" && r.Method == "GET" {
		g, ok := r.Context().Value(grantKey{}).(*access.Grant)
		if !ok {
			fail(w, ErrForbidden)
			return
		}
		if r.URL.RawQuery != "" {
			fail(w, ErrInvalid)
			return
		}
		a.store.mu.Lock()
		defer a.store.mu.Unlock()
		if e := a.store.member(room, actor); e != nil {
			fail(w, e)
			return
		}
		type publicDevice struct {
			ID          string `json:"device_id"`
			Actor       string `json:"actor"`
			Key         string `json:"signing_key"`
			Fingerprint string `json:"fingerprint"`
			Status      string `json:"status"`
			Revision    uint64 `json:"device_revision"`
		}
		out := []publicDevice{}
		for _, d := range g.DeviceBindings() {
			if e := a.store.member(room, d.Actor); e == nil {
				out = append(out, publicDevice{d.ID, d.Actor, d.SigningKey, d.Fingerprint, d.Status, d.Revision})
			} else if e != ErrForbidden {
				fail(w, e)
				return
			}
		}
		writeJSON(w, 200, struct {
			Version int            `json:"version"`
			Room    string         `json:"room"`
			Devices []publicDevice `json:"devices"`
		}{1, room, out})
		return
	}
	if parts[3] == "messages" && r.Method == "POST" {
		var req struct {
			ClientID string `json:"client_id"`
			Payload  []byte `json:"payload"`
		}
		if !decode(w, r, &req) {
			return
		}
		m, created, e := a.store.Send(room, actor, req.ClientID, req.Payload)
		if e != nil {
			fail(w, e)
			return
		}
		status := 200
		if created {
			status = 201
		}
		writeJSON(w, status, m)
		return
	}
	if (parts[3] == "messages" || parts[3] == "events") && r.Method == "GET" {
		after, e := cursor(r)
		if e != nil {
			fail(w, e)
			return
		}
		if parts[3] == "events" {
			a.events(w, r, room, actor, after)
			return
		}
		// Hold the ACL lock through the bounded response write. Once a revocation
		// commits, no old membership snapshot can write further message bytes.
		a.store.mu.Lock()
		defer a.store.mu.Unlock()
		ms, e := a.store.history(room, actor, after)
		if e != nil {
			fail(w, e)
			return
		}
		writeJSON(w, 200, ms)
		return
	}
	http.NotFound(w, r)
}

func decode(w http.ResponseWriter, r *http.Request, out any) bool {
	if r.Header.Get("Content-Type") != "application/json" {
		http.Error(w, "application/json required", 415)
		return false
	}
	r.Body = http.MaxBytesReader(w, r.Body, 24*1024)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if e := dec.Decode(out); e != nil {
		http.Error(w, "invalid JSON", 400)
		return false
	}
	if e := dec.Decode(new(any)); e != io.EOF {
		http.Error(w, "invalid JSON", 400)
		return false
	}
	return true
}
func cursor(r *http.Request) (int64, error) {
	vals, e := netQuery(r)
	if e != nil {
		return 0, e
	}
	v := vals
	if h := r.Header.Values("Last-Event-ID"); len(h) > 0 {
		if len(h) != 1 || h[0] == "" {
			return 0, ErrInvalid
		}
		v = h[0]
	}
	if v == "" {
		return 0, nil
	}
	for _, c := range v {
		if c < '0' || c > '9' {
			return 0, ErrInvalid
		}
	}
	q, e := strconv.ParseInt(v, 10, 64)
	if e != nil || q < 0 {
		return 0, ErrInvalid
	}
	return q, nil
}
func netQuery(r *http.Request) (string, error) {
	q, e := url.ParseQuery(r.URL.RawQuery)
	if e != nil {
		return "", ErrInvalid
	}
	// Only a single cursor argument is part of the protocol.
	if len(q) > 1 {
		return "", ErrInvalid
	}
	for k, v := range q {
		if k != "after" || len(v) != 1 || v[0] == "" {
			return "", ErrInvalid
		}
		return v[0], nil
	}
	if r.URL.RawQuery != "" {
		return "", ErrInvalid
	}
	return "", nil
}
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func fail(w http.ResponseWriter, e error) {
	status := 500
	msg := "storage failure"
	switch {
	case errors.Is(e, ErrForbidden):
		status = 403
		msg = "forbidden"
	case errors.Is(e, ErrConflict):
		status = 409
		msg = "conflict"
	case errors.Is(e, ErrInvalid):
		status = 400
		msg = "invalid request"
	case errors.Is(e, ErrIntegrity):
		status = 422
		msg = "attachment integrity failure"
	case errors.Is(e, ErrNotFound):
		status = 404
		msg = "not found"
	case errors.Is(e, ErrBusy):
		status = 409
		msg = "upload already active; retry later"
	case errors.Is(e, ErrLimit):
		status = 507
		msg = "prototype capacity reached"
	}
	http.Error(w, msg, status)
}

func (a *API) events(w http.ResponseWriter, r *http.Request, room, actor string, after int64) {
	select {
	case a.streams <- struct{}{}:
		defer func() { <-a.streams }()
	default:
		http.Error(w, "stream limit", 429)
		return
	}
	deadline := time.NewTimer(30 * time.Second)
	defer deadline.Stop()
	heartbeat := time.NewTicker(10 * time.Second)
	defer heartbeat.Stop()
	started := false
	end := time.Now().Add(30 * time.Second)
	for {
		if r.Context().Err() != nil || time.Now().After(end) {
			return
		}
		var changed <-chan struct{}
		count := 0
		e := authorize(r, func() error {
			a.store.mu.Lock()
			defer a.store.mu.Unlock()
			ms, e := a.store.history(room, actor, after)
			if e != nil {
				return e
			}
			changed = a.store.changed
			count = len(ms)
			e = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(2 * time.Second))
			if e == nil && !started {
				w.Header().Set("Content-Type", "text/event-stream")
				w.Header().Set("X-Accel-Buffering", "no")
				_, e = io.WriteString(w, ": synthetic-only\n\n")
				started = true
			}
			if e == nil && started && len(ms) == 0 {
				_, e = io.WriteString(w, ": keepalive\n\n")
			}
			for _, m := range ms {
				if e != nil {
					break
				}
				var b []byte
				b, e = json.Marshal(m)
				if e == nil {
					_, e = fmt.Fprintf(w, "id: %d\nevent: message\ndata: %s\n\n", m.Seq, b)
					after = m.Seq
				}
			}
			if e == nil {
				e = http.NewResponseController(w).Flush()
			}
			return e
		})
		if e != nil {
			if !started {
				fail(w, e)
			}
			return
		}
		if count == 100 {
			continue
		}
		select {
		case <-r.Context().Done():
			return
		case <-deadline.C:
			return
		case <-changed:
		case <-heartbeat.C:
			// Recheck membership before any subsequent stream write.
		}
	}
}
