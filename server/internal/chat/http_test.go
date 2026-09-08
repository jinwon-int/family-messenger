package chat

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func fixture(t *testing.T) (*Store, *httptest.Server) {
	t.Helper()
	s := testStore(t)
	room(t, s)
	h := httptest.NewServer(NewHandler(s))
	t.Cleanup(h.Close)
	return s, h
}
func req(t *testing.T, h *httptest.Server, method, path, actor string, body any, headers map[string]string) *http.Response {
	t.Helper()
	var data io.Reader
	if body != nil {
		b, e := json.Marshal(body)
		if e != nil {
			t.Fatal(e)
		}
		data = bytes.NewReader(b)
	}
	r, e := http.NewRequest(method, h.URL+path, data)
	if e != nil {
		t.Fatal(e)
	}
	if actor != "" {
		r.Header.Set("Authorization", "Bearer synthetic-"+actor)
	}
	r.Header.Set("Content-Type", "application/json")
	for k, v := range headers {
		if k == "Host" {
			r.Host = v
		} else {
			r.Header.Set(k, v)
		}
	}
	c := &http.Client{Timeout: 4 * time.Second}
	resp, e := c.Do(r)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}
func status(t *testing.T, r *http.Response, want int) {
	t.Helper()
	defer r.Body.Close()
	if r.StatusCode != want {
		b, _ := io.ReadAll(r.Body)
		t.Fatalf("got %d want %d: %s", r.StatusCode, want, b)
	}
}
func event(t *testing.T, r *bufio.Reader) Message {
	t.Helper()
	for {
		line, e := r.ReadString('\n')
		if e != nil {
			t.Fatal(e)
		}
		if strings.HasPrefix(line, "data: ") {
			var m Message
			if e = json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &m); e != nil {
				t.Fatal(e)
			}
			return m
		}
	}
}

func TestHTTPAuthorizationAndRequestBoundaries(t *testing.T) {
	_, h := fixture(t)
	status(t, req(t, h, "GET", "/health", "", nil, nil), 401)
	status(t, req(t, h, "GET", "/health", "charlie", nil, nil), 200)
	for _, hdr := range []map[string]string{{"Host": "attacker.invalid:80"}, {"Origin": "https://attacker.invalid"}, {"Origin": "null"}, {"Sec-Fetch-Site": "cross-site"}, {"Authorization": "Bearer synthetic-alice extra"}} {
		r := req(t, h, "GET", "/health", "alice", nil, hdr)
		if r.StatusCode != 403 && r.StatusCode != 401 {
			t.Fatal(r.StatusCode)
		}
		r.Body.Close()
	}
	status(t, req(t, h, "GET", "/v1/rooms/family/messages", "charlie", nil, nil), 403)
	status(t, req(t, h, "GET", "/v1/rooms/family/events", "charlie", nil, nil), 403)
	status(t, req(t, h, "PUT", "/v1/rooms/family/members/charlie", "bob", nil, nil), 403)
	status(t, req(t, h, "POST", "/v1/rooms/family/messages", "bob", map[string]any{"client_id": "x", "payload": []byte("x"), "actor": "alice"}, nil), 400)
	status(t, req(t, h, "POST", "/v1/rooms/family/messages", "alice", map[string]any{"client_id": "x", "payload": make([]byte, 30000)}, nil), 400)
	status(t, req(t, h, "POST", "/v1/rooms/family/messages", "alice", nil, map[string]string{"Content-Type": "text/plain"}), 415)
	for _, q := range []string{"?after=-1", "?after=1", "?after=0&after=0", "?after=1;foo=2", "?after=0&bad=%xx", "?wrong=0"} {
		status(t, req(t, h, "GET", "/v1/rooms/family/messages"+q, "alice", nil, nil), 400)
	}
}

func TestHTTPIdempotencyAndMembershipChanges(t *testing.T) {
	_, h := fixture(t)
	body := map[string]any{"client_id": "retry", "payload": []byte("synthetic")}
	status(t, req(t, h, "POST", "/v1/rooms/family/messages", "alice", body, nil), 201)
	status(t, req(t, h, "POST", "/v1/rooms/family/messages", "alice", body, nil), 200)
	body["payload"] = []byte("change")
	status(t, req(t, h, "POST", "/v1/rooms/family/messages", "alice", body, nil), 409)
	status(t, req(t, h, "POST", "/v1/rooms", "bob", map[string]any{"id": "bob-room", "members": []string{"charlie"}}, nil), 201)
	status(t, req(t, h, "GET", "/v1/rooms/bob-room/messages", "alice", nil, nil), 403)
	status(t, req(t, h, "DELETE", "/v1/rooms/family/members/bob", "alice", nil, nil), 204)
	status(t, req(t, h, "GET", "/v1/rooms/family/messages", "bob", nil, nil), 403)
	status(t, req(t, h, "POST", "/v1/rooms/family/messages", "bob", body, nil), 403)
	status(t, req(t, h, "PUT", "/v1/rooms/family/members/bob", "alice", nil, nil), 204)
	status(t, req(t, h, "GET", "/v1/rooms/family/messages", "bob", nil, nil), 200)
}

func TestSSELiveReplayAndRevocation(t *testing.T) {
	s, h := fixture(t)
	stream := req(t, h, "GET", "/v1/rooms/family/events", "bob", nil, nil)
	if stream.StatusCode != 200 || stream.Header.Get("Content-Type") != "text/event-stream" {
		t.Fatal(stream.StatusCode)
	}
	reader := bufio.NewReader(stream.Body)
	for i := 1; i <= 2; i++ {
		s.Send("family", "alice", fmt.Sprint(i), []byte("synthetic"))
		m := event(t, reader)
		if m.Seq != int64(i) {
			t.Fatal(m)
		}
	}
	stream.Body.Close()
	s.Send("family", "alice", "3", []byte("offline"))
	stream = req(t, h, "GET", "/v1/rooms/family/events?after=0", "bob", nil, map[string]string{"Last-Event-ID": "2"})
	reader = bufio.NewReader(stream.Body)
	m := event(t, reader)
	if m.Seq != 3 {
		t.Fatal(m)
	}
	status(t, req(t, h, "DELETE", "/v1/rooms/family/members/bob", "alice", nil, nil), 204)
	s.Send("family", "alice", "4", []byte("excluded"))
	remaining, e := io.ReadAll(reader)
	if e != nil || strings.Contains(string(remaining), "data:") {
		t.Fatalf("revoked stream %q %v", remaining, e)
	}
	status(t, req(t, h, "GET", "/v1/rooms/family/events", "bob", nil, map[string]string{"Last-Event-ID": "3"}), 403)
}

func TestSSEReplayAcrossPages(t *testing.T) {
	s, h := fixture(t)
	for i := 0; i < 105; i++ {
		s.Send("family", "alice", fmt.Sprint(i), []byte("synthetic"))
	}
	stream := req(t, h, "GET", "/v1/rooms/family/events", "alice", nil, nil)
	reader := bufio.NewReader(stream.Body)
	for i := 1; i <= 105; i++ {
		if m := event(t, reader); m.Seq != int64(i) {
			t.Fatal(m)
		}
	}
	stream.Body.Close()
}

func TestSSEConnectionLimitAndRelease(t *testing.T) {
	_, h := fixture(t)
	var streams []*http.Response
	for i := 0; i < 16; i++ {
		r := req(t, h, "GET", "/v1/rooms/family/events", "alice", nil, nil)
		if r.StatusCode != 200 {
			t.Fatal(r.StatusCode)
		}
		streams = append(streams, r)
	}
	status(t, req(t, h, "GET", "/v1/rooms/family/events", "alice", nil, nil), 429)
	for _, r := range streams {
		r.Body.Close()
	}
	deadline := time.Now().Add(time.Second)
	for {
		r := req(t, h, "GET", "/v1/rooms/family/events", "alice", nil, nil)
		code := r.StatusCode
		r.Body.Close()
		if code == 200 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("stream slots leaked")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestWebAssetsAndStrictBrowserOrigin(t *testing.T) {
	_, h := fixture(t)
	for _, path := range []string{"/", "/app.js", "/app.css", "/media.js"} {
		r := req(t, h, "GET", path, "", nil, map[string]string{"Sec-Fetch-Site": "none"})
		if r.StatusCode != 200 || r.Header.Get("Content-Security-Policy") == "" || r.Header.Get("X-Frame-Options") != "DENY" {
			t.Fatal(path, r.StatusCode, r.Header)
		}
		r.Body.Close()
	}
	status(t, req(t, h, "GET", "/v1/rooms", "alice", nil, map[string]string{"Origin": h.URL, "Sec-Fetch-Site": "same-origin"}), 200)
	status(t, req(t, h, "POST", "/v1/rooms", "alice", map[string]any{"id": "browser"}, map[string]string{"Origin": h.URL, "Sec-Fetch-Site": "same-origin"}), 201)
	for _, path := range []string{"/", "/app.js", "/media.js", "/v1/rooms", "/v1/rooms/family/events"} {
		for _, headers := range []map[string]string{{"Origin": "http://127.0.0.1:1"}, {"Origin": "https://127.0.0.1:1"}, {"Origin": "null"}, {"Sec-Fetch-Site": "cross-site"}, {"Sec-Fetch-Site": "same-site"}, {"Host": "attacker.invalid"}} {
			r := req(t, h, "GET", path, "alice", nil, headers)
			if r.Header.Get("Access-Control-Allow-Origin") != "" {
				t.Fatal("CORS enabled")
			}
			status(t, r, 403)
		}
	}
	status(t, req(t, h, "GET", "/v1/rooms", "alice", nil, map[string]string{"Sec-Fetch-Site": "none"}), 403)
	status(t, req(t, h, "GET", "/v1/rooms", "", nil, map[string]string{"Origin": h.URL, "Sec-Fetch-Site": "same-origin"}), 401)
}

func TestRoomListingOnlyCurrentMembership(t *testing.T) {
	s, h := fixture(t)
	if e := s.CreateRoom("private", "alice", nil); e != nil {
		t.Fatal(e)
	}
	get := func(actor string) []Room {
		r := req(t, h, "GET", "/v1/rooms", actor, nil, nil)
		defer r.Body.Close()
		var rooms []Room
		if e := json.NewDecoder(r.Body).Decode(&rooms); e != nil {
			t.Fatal(e)
		}
		return rooms
	}
	if rooms := get("alice"); len(rooms) != 2 {
		t.Fatal(rooms)
	}
	if rooms := get("bob"); len(rooms) != 1 || rooms[0].ID != "family" || rooms[0].Owner != "alice" {
		t.Fatal(rooms)
	}
	if rooms := get("charlie"); len(rooms) != 0 {
		t.Fatal(rooms)
	}
	s.SetMember("family", "alice", "bob", false)
	if rooms := get("bob"); len(rooms) != 0 {
		t.Fatal(rooms)
	}
}
