package chat

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

// syncBuffer is safe for handler goroutines that log after the client left.
type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}
func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

// captureLog routes package records into a buffer for one test. The server
// registered afterwards is closed (draining handlers) before the logger is
// restored, because cleanups run last-in first-out.
func captureLog(t *testing.T) *syncBuffer {
	t.Helper()
	buf := &syncBuffer{}
	previous := logger.Load()
	SetLogger(slog.New(slog.NewJSONHandler(buf, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { SetLogger(previous) })
	return buf
}

func TestHealthAnswersWithoutCredentialsButKeepsOriginDiscipline(t *testing.T) {
	_, h := fixture(t)
	r := req(t, h, "GET", "/health", "", nil, nil)
	body, _ := io.ReadAll(r.Body)
	if r.StatusCode != 200 || strings.TrimSpace(string(body)) != `{"mode":"synthetic-only","status":"ok"}` {
		t.Fatalf("unauthenticated liveness: %d %s", r.StatusCode, body)
	}
	if r.Header.Get("X-Family-Actor") != "" || r.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("health must not name an actor and must stay uncached: %v", r.Header)
	}
	// A garbage credential does not matter for liveness, but bad Host/Origin does.
	status(t, req(t, h, "GET", "/health", "", nil, map[string]string{"Authorization": "Bearer nonsense"}), 200)
	for _, hdr := range []map[string]string{{"Host": "attacker.invalid:80"}, {"Origin": "https://attacker.invalid"}, {"Sec-Fetch-Site": "cross-site"}} {
		status(t, req(t, h, "GET", "/health", "", nil, hdr), 403)
	}
	// Only the exact GET /health is public; variants fall back behind auth.
	status(t, req(t, h, "POST", "/health", "", nil, nil), 401)
	status(t, req(t, h, "GET", "/health?probe=1", "", nil, nil), 401)
	status(t, req(t, h, "GET", "/heal%74h", "", nil, nil), 401)
	status(t, req(t, h, "GET", "/v1/rooms", "", nil, nil), 401)
}

func TestHealthIsPublicInSignedModeToo(t *testing.T) {
	_, _, _, _, server := accessFixture(t)
	code, body := accessRequest(t, server, "", "GET", "/health", nil, nil)
	if code != 200 || !strings.Contains(string(body), `"status":"ok"`) {
		t.Fatalf("signed-mode liveness: %d %s", code, body)
	}
	if code, _ = accessRequest(t, server, "", "GET", "/v1/session", nil, nil); code == 200 {
		t.Fatal("session must still require a verified assertion")
	}
}

func TestFailureResponsesCarryAnErrorIDThatMatchesTheLog(t *testing.T) {
	buf := captureLog(t)
	s := testStore(t)
	room(t, s)
	h := httptest.NewServer(Logged(NewHandler(s)))
	t.Cleanup(h.Close)
	// A client-side rejection: JSON code plus id, logged at debug.
	r := req(t, h, "GET", "/v1/rooms/family/messages", "charlie", nil, nil)
	var denied struct{ Error, ID string }
	if e := json.NewDecoder(r.Body).Decode(&denied); e != nil || r.StatusCode != 403 || denied.Error != "forbidden" {
		t.Fatalf("%d %+v %v", r.StatusCode, denied, e)
	}
	// Break the database so a generic storage failure surfaces.
	if e := s.db.Close(); e != nil {
		t.Fatal(e)
	}
	r = req(t, h, "GET", "/v1/rooms", "alice", nil, map[string]string{"X-Probe": "hidden-header"})
	var failed struct{ Error, ID string }
	if e := json.NewDecoder(r.Body).Decode(&failed); e != nil {
		t.Fatal(e)
	}
	if r.StatusCode != 500 || failed.Error != "storage_failure" || !regexp.MustCompile(`^[0-9a-f]{12}$`).MatchString(failed.ID) || failed.ID == denied.ID {
		t.Fatalf("storage failure must carry a fresh short id: %d %+v", r.StatusCode, failed)
	}
	if r.Header.Get("Content-Type") != "application/json" {
		t.Fatal(r.Header.Get("Content-Type"))
	}
	records := parseRecords(t, buf)
	var failure, request map[string]any
	for _, rec := range records {
		switch {
		case rec["msg"] == "request failed" && rec["id"] == failed.ID:
			failure = rec
		case rec["msg"] == "request" && rec["error_id"] == failed.ID:
			request = rec
		}
	}
	if failure == nil || failure["level"] != "ERROR" || failure["status"] != float64(500) || failure["cause"] == "" || failure["cause"] == nil {
		t.Fatalf("storage failure log record missing or incomplete: %v", failure)
	}
	if request == nil || request["method"] != "GET" || request["path"] != "/v1/rooms" || request["status"] != float64(500) || request["actor"] != "alice" || request["duration_ms"] == nil {
		t.Fatalf("request record missing or incomplete: %v", request)
	}
	// Nothing secret or bulky reaches the log.
	for _, forbidden := range []string{"synthetic-alice", "Bearer", "hidden-header"} {
		if strings.Contains(buf.String(), forbidden) {
			t.Fatalf("log must not contain %q: %s", forbidden, buf.String())
		}
	}
	// The debug-level rejection is present with its own id.
	found := false
	for _, rec := range records {
		if rec["msg"] == "request failed" && rec["id"] == denied.ID && rec["level"] == "DEBUG" && rec["status"] == float64(403) {
			found = true
		}
	}
	if !found {
		t.Fatalf("403 must be logged at debug under its id: %s", buf.String())
	}
}

func TestRequestLogOmitsQueryAndKeepsStreamsFlushing(t *testing.T) {
	buf := captureLog(t)
	s := testStore(t)
	room(t, s)
	h := httptest.NewServer(Logged(NewHandler(s)))
	t.Cleanup(h.Close)
	status(t, req(t, h, "GET", "/v1/rooms/family/messages?after=0", "alice", nil, nil), 200)
	status(t, req(t, h, "GET", "/health", "", nil, nil), 200)
	// SSE goes through ResponseController.Flush; the wrapper must not block it.
	r, e := http.NewRequest("GET", h.URL+"/v1/rooms/family/events?after=0", nil)
	if e != nil {
		t.Fatal(e)
	}
	r.Header.Set("Authorization", "Bearer synthetic-bob")
	resp, e := (&http.Client{Timeout: 4 * time.Second}).Do(r)
	if e != nil {
		t.Fatal(e)
	}
	line, e := bufio.NewReader(resp.Body).ReadString('\n')
	resp.Body.Close()
	if e != nil || line != ": synthetic-only\n" {
		t.Fatalf("stream preamble not flushed through the logging wrapper: %q %v", line, e)
	}
	if strings.Contains(buf.String(), "after=0") {
		t.Fatalf("query string must not be logged: %s", buf.String())
	}
	paths := map[string]bool{}
	for _, rec := range parseRecords(t, buf) {
		if rec["msg"] == "request" {
			paths[rec["path"].(string)] = true
			if rec["status"] != float64(200) {
				t.Fatalf("unexpected status in %v", rec)
			}
		}
	}
	if !paths["/v1/rooms/family/messages"] || !paths["/health"] {
		t.Fatalf("request records missing: %v", paths)
	}
}

func parseRecords(t *testing.T, buf *syncBuffer) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		if line == "" {
			continue
		}
		var rec map[string]any
		if e := json.Unmarshal([]byte(line), &rec); e != nil {
			t.Fatalf("%v: %s", e, line)
		}
		out = append(out, rec)
	}
	return out
}
