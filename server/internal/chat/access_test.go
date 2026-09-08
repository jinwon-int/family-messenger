package chat

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/jinwon-int/family-messenger/server/internal/access"
)

func accessFixture(t *testing.T) (*Store, *access.Authority, access.Config, *rsa.PrivateKey, *httptest.Server) {
	t.Helper()
	s := testStore(t)
	k, e := rsa.GenerateKey(rand.Reader, 2048)
	if e != nil {
		t.Fatal(e)
	}
	c := access.Config{Issuer: "https://synthetic.cloudflareaccess.com", Audience: "synthetic-app", Keys: map[string]*rsa.PublicKey{"key": &k.PublicKey}, People: []access.Enrollment{{Subject: "owner", Actor: "alice", Owner: true}, {Subject: "family", Actor: "bob"}, {Subject: "outsider", Actor: "charlie"}}}
	a, e := access.New(c)
	if e != nil {
		t.Fatal(e)
	}
	h, e := NewAccessHandler(s, a)
	if e != nil {
		t.Fatal(e)
	}
	server := httptest.NewServer(h)
	t.Cleanup(server.Close)
	return s, a, c, k, server
}
func assertion(t *testing.T, c access.Config, k *rsa.PrivateKey, sub string, expiry time.Time) string {
	t.Helper()
	m := jwt.MapClaims{"iss": c.Issuer, "aud": []string{c.Audience}, "sub": sub, "type": "app", "iat": time.Now().Unix() - 1, "nbf": time.Now().Unix() - 1, "exp": expiry.Unix(), "role": "owner"}
	token := jwt.NewWithClaims(jwt.SigningMethodRS256, m)
	token.Header["kid"] = "key"
	s, e := token.SignedString(k)
	if e != nil {
		t.Fatal(e)
	}
	return s
}
func accessRequest(t *testing.T, server *httptest.Server, token, method, path string, body []byte, headers map[string]string) (int, []byte) {
	t.Helper()
	r, e := http.NewRequest(method, server.URL+path, bytes.NewReader(body))
	if e != nil {
		t.Fatal(e)
	}
	r.Header.Set("Cf-Access-Jwt-Assertion", token)
	r.Header.Set("Content-Type", "application/json")
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	resp, e := server.Client().Do(r)
	if e != nil {
		t.Fatal(e)
	}
	defer resp.Body.Close()
	b, e := io.ReadAll(resp.Body)
	if e != nil {
		t.Fatal(e)
	}
	return resp.StatusCode, b
}
func TestAccessRoomAndMediaAdmission(t *testing.T) {
	_, a, c, k, server := accessFixture(t)
	owner := assertion(t, c, k, "owner", time.Now().Add(time.Minute))
	bob := assertion(t, c, k, "family", time.Now().Add(time.Minute))
	outsider := assertion(t, c, k, "outsider", time.Now().Add(time.Minute))
	call := func(token, method, path string, body []byte, h map[string]string, want int) []byte {
		t.Helper()
		status, b := accessRequest(t, server, token, method, path, body, h)
		if status != want {
			t.Fatalf("%s %s got%d want%d %s", method, path, status, want, b)
		}
		return b
	}
	call(owner, "POST", "/v1/rooms", []byte(`{"id":"family","members":["bob"]}`), nil, 201)
	call(bob, "POST", "/v1/rooms/family/messages", []byte(`{"client_id":"bob-1","payload":"eA=="}`), nil, 201)
	call(outsider, "GET", "/v1/rooms/family/messages", nil, nil, 403)
	call(bob, "DELETE", "/v1/rooms/family/members/alice", nil, nil, 403)
	call(bob, "POST", "/v1/fleet/run", []byte(`{}`), nil, 404)
	blob := []byte("synthetic attachment")
	sum := sha256.Sum256(blob)
	headers := map[string]string{"Content-Type": "application/octet-stream", "X-Upload-ID": "upload", "X-File-Name": "test.bin", "X-Content-SHA256": hex.EncodeToString(sum[:])}
	var m Attachment
	json.Unmarshal(call(owner, "POST", "/v1/rooms/family/attachments", blob, headers, 201), &m)
	got := call(bob, "GET", "/v1/rooms/family/attachments/"+m.ID, nil, nil, 200)
	if !bytes.Equal(got, blob) {
		t.Fatal("download mismatch")
	}
	call(outsider, "GET", "/v1/rooms/family/attachments/"+m.ID, nil, nil, 403)
	call(owner, "GET", "/v1/rooms", nil, map[string]string{"Authorization": "Bearer synthetic-alice"}, 401)
	call("", "GET", "/v1/rooms", nil, map[string]string{"Cf-Access-Authenticated-User-Email": "owner@example.invalid"}, 401)
	call(assertion(t, c, k, "not-enrolled", time.Now().Add(time.Minute)), "GET", "/v1/rooms", nil, nil, 401)
	c.People = []access.Enrollment{c.People[0], c.People[2]}
	if a.Replace(c) != nil {
		t.Fatal("replacement failed")
	}
	call(bob, "GET", "/v1/rooms/family/attachments/"+m.ID, nil, nil, 401)
	call(bob, "POST", "/v1/rooms/family/messages", []byte(`{"client_id":"after","payload":"eA=="}`), nil, 401)
}
func TestAccessUploadRevocationAndExpiry(t *testing.T) {
	for _, mode := range []string{"revoke-readd", "expiry"} {
		t.Run(mode, func(t *testing.T) {
			s, a, c, k, server := accessFixture(t)
			s.CreateRoom("family", "alice", []string{"bob"})
			expires := time.Now().Add(time.Minute)
			if mode == "expiry" {
				expires = time.Now().Add(time.Second)
			}
			token := assertion(t, c, k, "family", expires)
			reader, writer := io.Pipe()
			defer writer.Close()
			r, _ := http.NewRequest("POST", server.URL+"/v1/rooms/family/attachments", reader)
			r.ContentLength = 3
			r.Header.Set("Cf-Access-Jwt-Assertion", token)
			r.Header.Set("Content-Type", "application/octet-stream")
			r.Header.Set("X-Upload-ID", "pending")
			r.Header.Set("X-File-Name", "test.bin")
			sum := sha256.Sum256([]byte("abc"))
			r.Header.Set("X-Content-SHA256", hex.EncodeToString(sum[:]))
			result := make(chan int, 1)
			go func() {
				resp, e := server.Client().Do(r)
				if e != nil {
					result <- 0
					return
				}
				io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
				result <- resp.StatusCode
			}()
			if _, e := writer.Write([]byte("a")); e != nil {
				t.Fatal(e)
			}
			until := time.Now().Add(time.Second)
			for {
				s.mu.Lock()
				active := len(s.uploads)
				s.mu.Unlock()
				if active == 1 {
					break
				}
				if time.Now().After(until) {
					t.Fatal("upload not admitted")
				}
				time.Sleep(time.Millisecond)
			}
			if mode == "expiry" {
				time.Sleep(time.Until(time.Unix(expires.Unix(), 0)) + 10*time.Millisecond)
			} else {
				removed := c
				removed.People = []access.Enrollment{c.People[0]}
				done := make(chan error, 1)
				go func() { done <- a.Replace(removed) }()
				select {
				case e := <-done:
					if e != nil {
						t.Fatal(e)
					}
				case <-time.After(300 * time.Millisecond):
					t.Fatal("network upload blocked account revocation")
				}
				if a.Replace(c) != nil {
					t.Fatal("re-add failed")
				}
			}
			writer.Write([]byte("bc"))
			writer.Close()
			select {
			case status := <-result:
				if status != 403 {
					t.Fatalf("status%d", status)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("request did not finish")
			}
			s.mu.Lock()
			var n int
			s.db.QueryRow("SELECT count(*) FROM attachments").Scan(&n)
			s.mu.Unlock()
			if n != 0 {
				t.Fatal("retired upload committed")
			}
		})
	}
}
func TestAccessStreamRetiresAfterReplacement(t *testing.T) {
	s, a, c, k, server := accessFixture(t)
	s.CreateRoom("family", "alice", []string{"bob"})
	token := assertion(t, c, k, "family", time.Now().Add(time.Minute))
	r, _ := http.NewRequest("GET", server.URL+"/v1/rooms/family/events", nil)
	r.Header.Set("Cf-Access-Jwt-Assertion", token)
	resp, e := server.Client().Do(r)
	if e != nil {
		t.Fatal(e)
	}
	defer resp.Body.Close()
	b := make([]byte, 1)
	if _, e = resp.Body.Read(b); e != nil {
		t.Fatal(e)
	}
	if a.Replace(c) != nil {
		t.Fatal("replace failed")
	}
	s.Send("family", "alice", "after", []byte("new-data-after-revocation"))
	rest, e := io.ReadAll(resp.Body)
	if e != nil {
		t.Fatal(e)
	}
	if strings.Contains(string(rest), "event: message") {
		t.Fatal("retired stream wrote message")
	}
}

func TestAccessDownloadReplacementStopsNextChunk(t *testing.T) {
	s, a, c, k, server := accessFixture(t)
	_ = server
	room(t, s)
	body := bytes.Repeat([]byte("x"), 128*1024)
	m, _, e := putMedia(t, s, mediaMeta("identity-chunks", body), body)
	if e != nil {
		t.Fatal(e)
	}
	handler, _ := NewAccessHandler(s, a)
	w := &gatedMediaWriter{header: make(http.Header), entered: make(chan struct{}), release: make(chan struct{})}
	r := httptest.NewRequest("GET", "http://127.0.0.1:18920/v1/rooms/family/attachments/"+m.ID, nil)
	r.Header.Set("Cf-Access-Jwt-Assertion", assertion(t, c, k, "family", time.Now().Add(time.Minute)))
	done := make(chan struct{})
	go func() { handler.ServeHTTP(w, r); close(done) }()
	select {
	case <-w.entered:
	case <-time.After(time.Second):
		t.Fatal("download never wrote")
	}
	replaced := make(chan error, 1)
	go func() { replaced <- a.Replace(c) }()
	time.Sleep(15 * time.Millisecond)
	close(w.release)
	select {
	case e := <-replaced:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(time.Second):
		t.Fatal("replacement blocked")
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("download did not stop")
	}
	if w.body.Len() != 32*1024 {
		t.Fatalf("retired identity wrote%d bytes", w.body.Len())
	}
}

func TestAccessSlowJSONDoesNotHoldRevocation(t *testing.T) {
	s, a, c, k, server := accessFixture(t)
	room(t, s)
	reader, writer := io.Pipe()
	defer writer.Close()
	body := []byte(`{"client_id":"slow","payload":"eA=="}`)
	r, _ := http.NewRequest("POST", server.URL+"/v1/rooms/family/messages", reader)
	r.ContentLength = int64(len(body))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Cf-Access-Jwt-Assertion", assertion(t, c, k, "family", time.Now().Add(time.Minute)))
	done := make(chan int, 1)
	go func() {
		resp, e := server.Client().Do(r)
		if e != nil {
			done <- 0
			return
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		done <- resp.StatusCode
	}()
	writer.Write(body[:1])
	time.Sleep(20 * time.Millisecond)
	retired := make(chan error, 1)
	go func() { retired <- a.Replace(c) }()
	select {
	case e := <-retired:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(300 * time.Millisecond):
		t.Fatal("slow JSON body holds authority")
	}
	writer.Write(body[1:])
	writer.Close()
	select {
	case code := <-done:
		if code != 403 {
			t.Fatalf("status%d", code)
		}
	case <-time.After(time.Second):
		t.Fatal("request hangs")
	}
	ms, e := s.History("family", "alice", 0)
	if e != nil || len(ms) != 0 {
		t.Fatal("retired JSON write committed", e)
	}
}
