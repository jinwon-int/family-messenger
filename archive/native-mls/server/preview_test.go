package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeUpstream is an in-process RoundTripper: every upstream request is
// served by handler through a recorder, so no test ever touches the network.
// It records each request (host, path, headers) for assertions.
type fakeUpstream struct {
	handler http.Handler
	mu      sync.Mutex
	reqs    []fakeReq
}

type fakeReq struct {
	scheme, host, path string
	header             http.Header
}

func (f *fakeUpstream) RoundTrip(req *http.Request) (*http.Response, error) {
	f.mu.Lock()
	f.reqs = append(f.reqs, fakeReq{scheme: req.URL.Scheme, host: req.URL.Host, path: req.URL.Path, header: req.Header.Clone()})
	f.mu.Unlock()
	rec := httptest.NewRecorder()
	f.handler.ServeHTTP(rec, req)
	if err := req.Context().Err(); err != nil {
		return nil, err
	}
	resp := rec.Result()
	resp.Request = req
	return resp, nil
}

func (f *fakeUpstream) requests() []fakeReq {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]fakeReq(nil), f.reqs...)
}

func (f *fakeUpstream) count() int { return len(f.requests()) }

func ogPage(title, desc, image string) string {
	var b strings.Builder
	b.WriteString("<!doctype html><html><head>")
	if title != "" {
		fmt.Fprintf(&b, `<meta property="og:title" content="%s">`, title)
	}
	if desc != "" {
		fmt.Fprintf(&b, `<meta property="og:description" content="%s">`, desc)
	}
	if image != "" {
		fmt.Fprintf(&b, `<meta property="og:image" content="%s">`, image)
	}
	b.WriteString("</head><body></body></html>")
	return b.String()
}

// newPreviewRelay is a relay with -link-preview on over a fake upstream.
func newPreviewRelay(t *testing.T, upstream http.Handler) (*relay, *httptest.Server, *fakeUpstream) {
	t.Helper()
	r, srv := newTestRelay(t, testPolicy())
	fake := &fakeUpstream{handler: upstream}
	r.preview = newLinkPreviewer(fake)
	srv.Config.Handler = r.routes()
	return r, srv, fake
}

func getPreview(t *testing.T, srv *httptest.Server, path string, headers map[string]string) (*http.Response, []byte) {
	t.Helper()
	req, err := http.NewRequest("GET", srv.URL+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultTransport.RoundTrip(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp, b
}

func previewQuery(link string) string { return previewPath + "?url=" + url.QueryEscape(link) }

func TestNormalizeXStatusURL(t *testing.T) {
	good := []struct{ in, canonical, id string }{
		{"https://x.com/jack/status/20", "https://x.com/jack/status/20", "20"},
		{"https://X.COM/jack/status/20", "https://x.com/jack/status/20", "20"},
		{"HTTPS://x.com/jack/status/20", "https://x.com/jack/status/20", "20"},
		{"https://www.x.com/Some_User1/status/1234567890123456789", "https://x.com/Some_User1/status/1234567890123456789", "1234567890123456789"},
		{"https://mobile.x.com/jack/status/20/photo/1", "https://x.com/jack/status/20", "20"},
		{"https://twitter.com/jack/status/20?s=20&t=abc#frag", "https://x.com/jack/status/20", "20"},
		{"https://www.twitter.com/jack/status/20/", "https://x.com/jack/status/20", "20"},
		{"https://mobile.twitter.com/jack/status/20", "https://x.com/jack/status/20", "20"},
		{"https://x.com/i/web/status/1850000000000000000", "https://x.com/i/web/status/1850000000000000000", "1850000000000000000"},
		{"https://twitter.com/i/web/status/7/analytics", "https://x.com/i/web/status/7", "7"},
		{"https://x.com/abcdefghijklmno/status/" + strings.Repeat("9", 25), "https://x.com/abcdefghijklmno/status/" + strings.Repeat("9", 25), strings.Repeat("9", 25)},
	}
	for _, g := range good {
		c, id, ok := normalizeXStatusURL(g.in)
		if !ok || c != g.canonical || id != g.id {
			t.Errorf("%q: got (%q,%q,%v) want (%q,%q)", g.in, c, id, ok, g.canonical, g.id)
		}
	}
	bad := []string{
		"",
		"http://x.com/jack/status/20",                          // not https
		"ftp://x.com/jack/status/20",                           // scheme
		"//x.com/jack/status/20",                               // scheme-relative
		"x.com/jack/status/20",                                 // no scheme
		"https://example.com/jack/status/20",                   // other host
		"https://x.com.evil.example/jack/status/20",            // lookalike suffix
		"https://evilx.com/jack/status/20",                     // lookalike prefix
		"https://x.co/jack/status/20",                          // lookalike
		"https://twitter.com.evil.example/jack/status/20",      // lookalike
		"https://t.co/abc",                                     // shortener
		"https://x.com./jack/status/20",                        // trailing dot
		"https://user@x.com/jack/status/20",                    // userinfo
		"https://user:pw@x.com/jack/status/20",                 // userinfo
		"https://evil.example\\@x.com/jack/status/20",          // backslash trick
		"https://x.com:443/jack/status/20",                     // explicit port
		"https://x.com:8443/jack/status/20",                    // port
		"https://x.com:/jack/status/20",                        // empty port
		"https://x.com/jack",                                   // not a status
		"https://x.com/jack/status",                            // no id
		"https://x.com/jack/status/",                           // empty id
		"https://x.com/jack/likes/20",                          // not status
		"https://x.com/jack/Status/20",                         // case of the keyword
		"https://x.com/jack/status/20abc",                      // non-numeric id
		"https://x.com/jack/status/-20",                        // sign
		"https://x.com/jack/status/" + strings.Repeat("1", 26), // huge id
		"https://x.com/abcdefghijklmnop/status/20",             // handle too long
		"https://x.com/ja-ck/status/20",                        // handle charset
		"https://x.com/%6Aack/status/20",                       // percent-encoded handle
		"https://x.com/jack%2Fstatus/20",                       // encoded slash
		"https://x.com//jack/status/20",                        // empty segment
		"https://x.com/i/web/status/abc",                       // i/web bad id
		"https://x.com/i/web/20",                               // i/web no status
		"https://x.com/home",                                   // other page
		"https://x.com/" + strings.Repeat("a", 3000),           // overlong
		"https://pbs.twimg.com/jack/status/20",                 // image host is not a page host
		"javascript:alert(1)",                                  // opaque
	}
	for _, b := range bad {
		if c, id, ok := normalizeXStatusURL(b); ok {
			t.Errorf("%q accepted as (%q,%q)", b, c, id)
		}
	}
}

func TestNormalizeImageURL(t *testing.T) {
	for _, g := range []string{
		"https://pbs.twimg.com/media/AbC.jpg?format=jpg&name=small",
		"https://abs.twimg.com/responsive-web/client-web/icon.png",
		"https://PBS.twimg.com/media/x.jpg",
	} {
		if _, ok := normalizeImageURL(g); !ok {
			t.Errorf("%q refused", g)
		}
	}
	for _, b := range []string{
		"", "http://pbs.twimg.com/media/x.jpg", "https://pbs.twimg.com:443/media/x.jpg",
		"https://u@pbs.twimg.com/media/x.jpg", "https://pbs.twimg.com.evil.example/x.jpg",
		"https://video.twimg.com/x.mp4", "https://x.com/x.jpg", "https://127.0.0.1/x.jpg",
		"/relative.jpg", "data:image/png;base64,AAAA",
	} {
		if _, ok := normalizeImageURL(b); ok {
			t.Errorf("%q accepted", b)
		}
	}
}

func TestParseOGMeta(t *testing.T) {
	page := `<html><HEAD>
<meta name="viewport" content="width=device-width">
<META CONTENT='Content first &amp; single quotes' PROPERTY='og:title'>
<meta property="og:title" content="second title must lose">
<meta
   property = "og:description"
   content  = "multi-line &lt;b&gt; &quot;q&quot; &#39;a&#39; &#x1F600; a > b">
<meta property=og:image content=https://pbs.twimg.com/media/A.jpg?name=small&amp;format=jpg>
</head></html>`
	m := parseOGMeta([]byte(page))
	if m.Title != "Content first & single quotes" {
		t.Errorf("title %q", m.Title)
	}
	if m.Description != `multi-line <b> "q" 'a' 😀 a > b` {
		t.Errorf("description %q", m.Description)
	}
	if m.Image != "https://pbs.twimg.com/media/A.jpg?name=small&format=jpg" {
		t.Errorf("image %q", m.Image)
	}

	// name= works like property=; empty content does not claim the field.
	m = parseOGMeta([]byte(`<meta property="og:title" content=""><meta name="OG:Title" content="  via name  ">`))
	if m.Title != "via name" || m.Description != "" || m.Image != "" {
		t.Errorf("name form: %+v", m)
	}
	// Caps at 2000 runes (multi-byte safe).
	long := strings.Repeat("가", previewFieldMaxRunes+50)
	m = parseOGMeta([]byte(`<meta property="og:description" content="` + long + `">`))
	if got := []rune(m.Description); len(got) != previewFieldMaxRunes || string(got) != strings.Repeat("가", previewFieldMaxRunes) {
		t.Errorf("cap: %d runes", len(got))
	}
	// Nothing useful.
	for _, p := range []string{"", "<html></html>", `<meta property="og:site_name" content="X">`, `<meta property="og:title">`, `<metadata property="og:title" content="no">`} {
		if m := parseOGMeta([]byte(p)); m != (ogMeta{}) {
			t.Errorf("%q: %+v", p, m)
		}
	}
}

func TestPreviewRoutesOffByDefault(t *testing.T) {
	_, srv := newTestRelay(t, testPolicy())
	for _, p := range []string{previewQuery("https://x.com/jack/status/20"), previewImagePath + "?u=" + url.QueryEscape("https://pbs.twimg.com/media/a.jpg")} {
		if resp, body := getPreview(t, srv, p, nil); resp.StatusCode != http.StatusNotFound {
			t.Fatalf("%s with flag off: %d %s", p, resp.StatusCode, body)
		}
	}
}

func TestPreviewSuccessCacheAndHeaders(t *testing.T) {
	_, srv, fake := newPreviewRelay(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		io.WriteString(w, ogPage("Jack on X", "just setting up my twttr", "https://pbs.twimg.com/media/A.jpg?name=small&amp;format=jpg"))
	}))
	resp, body := getPreview(t, srv, previewQuery("https://twitter.com/jack/status/20/photo/1?s=20"), map[string]string{
		"Cookie":        "CF_Authorization=secret-cookie",
		"Authorization": "Bearer secret-token",
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d %s", resp.StatusCode, body)
	}
	for h, want := range map[string]string{
		"Content-Type":           "application/json; charset=utf-8",
		"Cache-Control":          "private, max-age=3600",
		"X-Content-Type-Options": "nosniff",
	} {
		if got := resp.Header.Get(h); got != want {
			t.Errorf("%s = %q want %q", h, got, want)
		}
	}
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatal(err)
	}
	wantImg := previewImagePath + "?u=" + url.QueryEscape("https://pbs.twimg.com/media/A.jpg?name=small&format=jpg")
	if got["url"] != "https://x.com/jack/status/20" || got["site"] != "X" || got["title"] != "Jack on X" ||
		got["description"] != "just setting up my twttr" || got["image"] != wantImg || len(got) != 5 {
		t.Fatalf("body %s", body)
	}
	reqs := fake.requests()
	if len(reqs) != 1 {
		t.Fatalf("upstream calls %d", len(reqs))
	}
	u := reqs[0]
	if u.scheme != "https" || u.host != "x.com" || u.path != "/jack/status/20" {
		t.Errorf("upstream %s://%s%s", u.scheme, u.host, u.path)
	}
	if u.header.Get("User-Agent") != previewUserAgent {
		t.Errorf("UA %q", u.header.Get("User-Agent"))
	}
	if u.header.Get("Cookie") != "" || u.header.Get("Authorization") != "" || u.header.Get("Cf-Access-Jwt-Assertion") != "" {
		t.Errorf("client credentials forwarded upstream: %v", u.header)
	}

	// Same id under another handle and host: cache hit, url reflects this request.
	resp, body = getPreview(t, srv, previewQuery("https://x.com/someone/status/20"), nil)
	if resp.StatusCode != 200 || !bytes.Contains(body, []byte(`"url":"https://x.com/someone/status/20"`)) {
		t.Fatalf("cached: %d %s", resp.StatusCode, body)
	}
	if n := fake.count(); n != 1 {
		t.Fatalf("cache miss: upstream calls %d", n)
	}

	// Bad input never reaches upstream.
	resp, body = getPreview(t, srv, previewQuery("https://evil.example/jack/status/20"), nil)
	if resp.StatusCode != http.StatusBadRequest || !bytes.Contains(body, []byte(`"bad_url"`)) || resp.Header.Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("bad url: %d %s", resp.StatusCode, body)
	}
	if resp, _ := getPreview(t, srv, previewPath, nil); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("missing url: %d", resp.StatusCode)
	}
	if n := fake.count(); n != 1 {
		t.Fatalf("bad url reached upstream: %d", n)
	}
}

func TestPreviewImageFieldAllowlist(t *testing.T) {
	_, srv, _ := newPreviewRelay(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		img := map[string]string{
			"/a/status/1": "https://evil.example/a.jpg",
			"/a/status/2": "http://pbs.twimg.com/a.jpg",
			"/a/status/3": "https://abs.twimg.com/a.png",
			"/a/status/4": "",
		}[r.URL.Path]
		io.WriteString(w, ogPage("t", "", img))
	}))
	for id, want := range map[string]string{
		"1": `"image":null`,
		"2": `"image":null`,
		"3": `"image":"` + previewImagePath + "?u=" + url.QueryEscape("https://abs.twimg.com/a.png") + `"`,
		"4": `"image":null`,
	} {
		resp, body := getPreview(t, srv, previewQuery("https://x.com/a/status/"+id), nil)
		if resp.StatusCode != 200 || !bytes.Contains(body, []byte(want)) || !bytes.Contains(body, []byte(`"description":""`)) {
			t.Errorf("id %s: %d %s (want %s)", id, resp.StatusCode, body, want)
		}
	}
}

func TestPreviewFailuresAndRedirects(t *testing.T) {
	var evilHit atomic.Int32
	_, srv, fake := newPreviewRelay(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Host != "x.com" && r.URL.Host != "mobile.x.com" && r.URL.Host != "twitter.com" {
			evilHit.Add(1)
			io.WriteString(w, ogPage("evil", "evil", ""))
			return
		}
		switch r.URL.Path {
		case "/a/status/1": // no og tags
			io.WriteString(w, "<html><head><title>nothing</title></head></html>")
		case "/a/status/2":
			http.Error(w, "boom", http.StatusInternalServerError)
		case "/a/status/3":
			http.Redirect(w, r, "https://evil.example/a/status/3", http.StatusFound)
		case "/a/status/4":
			http.Redirect(w, r, "http://x.com/a/status/4b", http.StatusFound)
		case "/a/status/5":
			http.Redirect(w, r, "https://x.com:8443/a/status/5b", http.StatusFound)
		case "/a/status/6": // allowed host redirect
			http.Redirect(w, r, "https://mobile.x.com/a/status/6b", http.StatusMovedPermanently)
		case "/a/status/6b":
			io.WriteString(w, ogPage("followed", "", ""))
		case "/a/status/7": // endless loop within the allowlist
			http.Redirect(w, r, "https://twitter.com/a/status/7", http.StatusFound)
		default:
			http.NotFound(w, r)
		}
	}))
	for path, want := range map[string]struct {
		code int
		body string
	}{
		"/a/status/1": {404, `"no_preview"`},
		"/a/status/2": {502, `"upstream_failed"`},
		"/a/status/3": {502, `"upstream_failed"`},
		"/a/status/4": {502, `"upstream_failed"`},
		"/a/status/5": {502, `"upstream_failed"`},
		"/a/status/6": {200, `"title":"followed"`},
		"/a/status/7": {502, `"upstream_failed"`},
	} {
		resp, body := getPreview(t, srv, previewQuery("https://x.com"+path), nil)
		if resp.StatusCode != want.code || !bytes.Contains(body, []byte(want.body)) {
			t.Errorf("%s: %d %s", path, resp.StatusCode, body)
		}
	}
	if n := evilHit.Load(); n != 0 {
		t.Fatalf("disallowed host contacted %d times", n)
	}
	for _, r := range fake.requests() {
		if r.scheme != "https" || !previewPageHosts[r.host] {
			t.Fatalf("upstream request to %s://%s", r.scheme, r.host)
		}
	}
	// The loop stops after previewMaxRedirects redirects: 1 + 3 requests.
	loop := 0
	for _, r := range fake.requests() {
		if r.path == "/a/status/7" {
			loop++
		}
	}
	if loop != 1+previewMaxRedirects {
		t.Fatalf("redirect loop requests %d", loop)
	}
	// Failures are cached too (10 min): no second upstream call.
	before := fake.count()
	getPreview(t, srv, previewQuery("https://x.com/a/status/1"), nil)
	getPreview(t, srv, previewQuery("https://x.com/a/status/2"), nil)
	if fake.count() != before {
		t.Fatalf("failure not cached: %d → %d", before, fake.count())
	}
}

func TestPreviewCacheExpiryAndBound(t *testing.T) {
	r, srv, fake := newPreviewRelay(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/2") {
			io.WriteString(w, "<html></html>")
			return
		}
		io.WriteString(w, ogPage("t", "d", ""))
	}))
	now := time.Unix(1_800_000_000, 0)
	var mu sync.Mutex
	r.preview.now = func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	advance := func(d time.Duration) { mu.Lock(); now = now.Add(d); mu.Unlock() }
	hit := func(id string) { getPreview(t, srv, previewQuery("https://x.com/a/status/"+id), nil) }

	hit("1") // success
	hit("2") // no_preview (failure TTL)
	if fake.count() != 2 {
		t.Fatalf("calls %d", fake.count())
	}
	advance(previewCacheFail + time.Second)
	hit("1")
	hit("2")
	if fake.count() != 3 {
		t.Fatalf("after 10m: calls %d (want only the failure refetched)", fake.count())
	}
	advance(previewCacheOK)
	hit("1")
	if fake.count() != 4 {
		t.Fatalf("after 6h: calls %d", fake.count())
	}

	// Bound: never more than previewCacheMax entries, oldest evicted first.
	p := r.preview
	p.mu.Lock()
	p.cache = map[string]*previewEntry{}
	for i := 0; i < previewCacheMax+10; i++ {
		p.storeLocked(fmt.Sprint(i), previewResult{status: 200})
	}
	n := len(p.cache)
	_, oldest := p.cache["0"]
	_, newest := p.cache[fmt.Sprint(previewCacheMax+9)]
	p.mu.Unlock()
	if n != previewCacheMax || oldest || !newest {
		t.Fatalf("cache len %d oldest=%v newest=%v", n, oldest, newest)
	}
}

func TestPreviewConcurrencyLimit(t *testing.T) {
	var cur, peak atomic.Int32
	_, srv, _ := newPreviewRelay(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := cur.Add(1)
		for {
			p := peak.Load()
			if n <= p || peak.CompareAndSwap(p, n) {
				break
			}
		}
		time.Sleep(30 * time.Millisecond)
		cur.Add(-1)
		io.WriteString(w, ogPage("t", "", ""))
	}))
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			req, _ := http.NewRequest("GET", srv.URL+previewQuery(fmt.Sprintf("https://x.com/a/status/%d", 100+i)), nil)
			resp, err := http.DefaultTransport.RoundTrip(req)
			if err == nil {
				io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
			}
		}(i)
	}
	wg.Wait()
	if p := peak.Load(); p < 1 || p > previewConcurrency {
		t.Fatalf("peak concurrent upstream requests %d (limit %d)", p, previewConcurrency)
	}
}

func TestPreviewUpstreamTimeout(t *testing.T) {
	r, srv, _ := newPreviewRelay(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	r.preview.pageClient.Timeout = 50 * time.Millisecond
	start := time.Now()
	resp, body := getPreview(t, srv, previewQuery("https://x.com/a/status/1"), nil)
	if resp.StatusCode != http.StatusBadGateway || !bytes.Contains(body, []byte("upstream_failed")) {
		t.Fatalf("timeout: %d %s", resp.StatusCode, body)
	}
	if d := time.Since(start); d > 3*time.Second {
		t.Fatalf("timeout took %s", d)
	}
}

func TestPreviewImageRoute(t *testing.T) {
	jpeg := append([]byte{0xFF, 0xD8, 0xFF}, bytes.Repeat([]byte{1}, 100)...)
	_, srv, fake := newPreviewRelay(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !previewImageHosts[r.URL.Host] {
			t.Errorf("image fetch contacted %s", r.URL.Host)
			return
		}
		switch r.URL.Path {
		case "/ok.jpg":
			w.Header().Set("Content-Type", "image/jpeg")
			w.Write(jpeg)
		case "/ok.webp":
			w.Header().Set("Content-Type", "IMAGE/WEBP; charset=binary")
			w.Write([]byte("RIFF....WEBP"))
		case "/html":
			w.Header().Set("Content-Type", "text/html")
			io.WriteString(w, "<script>alert(1)</script>")
		case "/svg":
			w.Header().Set("Content-Type", "image/svg+xml")
			io.WriteString(w, "<svg/>")
		case "/none":
			w.Header()["Content-Type"] = nil
			w.Write(jpeg)
		case "/big":
			w.Header().Set("Content-Type", "image/png")
			w.Write(make([]byte, previewImageMaxBytes+1))
		case "/exact":
			w.Header().Set("Content-Type", "image/png")
			w.Write(make([]byte, previewImageMaxBytes))
		case "/redir-ok":
			http.Redirect(w, r, "https://abs.twimg.com/ok.jpg", http.StatusFound)
		case "/redir-bad":
			http.Redirect(w, r, "https://x.com/ok.jpg", http.StatusFound)
		case "/404":
			http.NotFound(w, r)
		}
	}))
	img := func(u string) (*http.Response, []byte) {
		return getPreview(t, srv, previewImagePath+"?u="+url.QueryEscape(u), map[string]string{"Cookie": "a=b", "Authorization": "Bearer z"})
	}
	resp, body := img("https://pbs.twimg.com/ok.jpg")
	if resp.StatusCode != 200 || !bytes.Equal(body, jpeg) {
		t.Fatalf("jpeg: %d %d bytes", resp.StatusCode, len(body))
	}
	for h, want := range map[string]string{
		"Content-Type":           "image/jpeg",
		"Cache-Control":          "private, max-age=86400",
		"X-Content-Type-Options": "nosniff",
	} {
		if got := resp.Header.Get(h); got != want {
			t.Errorf("%s = %q want %q", h, got, want)
		}
	}
	if resp, _ := img("https://abs.twimg.com/ok.webp"); resp.StatusCode != 200 || resp.Header.Get("Content-Type") != "image/webp" {
		t.Errorf("webp: %d %q", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	if resp, body := img("https://pbs.twimg.com/exact"); resp.StatusCode != 200 || len(body) != previewImageMaxBytes {
		t.Errorf("exact cap: %d %d", resp.StatusCode, len(body))
	}
	if resp, _ := img("https://pbs.twimg.com/redir-ok"); resp.StatusCode != 200 {
		t.Errorf("allowed redirect: %d", resp.StatusCode)
	}
	for _, p := range []string{"/html", "/svg", "/none", "/big", "/redir-bad", "/404"} {
		resp, body := img("https://pbs.twimg.com" + p)
		if resp.StatusCode != http.StatusBadGateway || !bytes.Contains(body, []byte("upstream_failed")) || resp.Header.Get("Content-Type") == "text/html" {
			t.Errorf("%s: %d %q %s", p, resp.StatusCode, resp.Header.Get("Content-Type"), body)
		}
	}
	before := fake.count()
	for _, u := range []string{"", "http://pbs.twimg.com/ok.jpg", "https://evil.example/ok.jpg", "https://pbs.twimg.com:443/ok.jpg", "https://a@pbs.twimg.com/ok.jpg", "https://pbs.twimg.com.evil.example/ok.jpg", "https://x.com/ok.jpg"} {
		if resp, body := img(u); resp.StatusCode != http.StatusBadRequest || !bytes.Contains(body, []byte("bad_url")) {
			t.Errorf("%q: %d %s", u, resp.StatusCode, body)
		}
	}
	if fake.count() != before {
		t.Fatalf("invalid image URL reached upstream")
	}
	for _, r := range fake.requests() {
		if r.header.Get("Cookie") != "" || r.header.Get("Authorization") != "" {
			t.Fatalf("credentials forwarded to %s", r.host)
		}
	}
}

// With caller authentication on, both routes are behind it like every other
// contract route: no token → 401, cross-site → 403, valid token → served.
func TestPreviewRequiresAuthentication(t *testing.T) {
	r, srv, fake := newPreviewRelay(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		io.WriteString(w, ogPage("t", "d", ""))
	}))
	iss := newTestIssuer(t)
	r.access = iss.verifier()
	srv.Config.Handler = r.routes()
	page := previewQuery("https://x.com/a/status/1")
	image := previewImagePath + "?u=" + url.QueryEscape("https://pbs.twimg.com/a.png")
	for _, p := range []string{page, image} {
		for name, h := range map[string]map[string]string{
			"none":    nil,
			"garbage": {"Cf-Access-Jwt-Assertion": "not.a.jwt"},
			"cookie":  {"Cookie": "CF_Authorization=" + iss.mint("s", nil)},
		} {
			if resp, body := getPreview(t, srv, p, h); resp.StatusCode != http.StatusUnauthorized || !bytes.Contains(body, []byte("unauthorized")) {
				t.Errorf("%s %s: %d %s", p, name, resp.StatusCode, body)
			}
		}
		if resp, _ := getPreview(t, srv, p, map[string]string{"Cf-Access-Jwt-Assertion": iss.mint("s", nil), "Sec-Fetch-Site": "cross-site"}); resp.StatusCode != http.StatusForbidden {
			t.Errorf("%s cross-site: %d", p, resp.StatusCode)
		}
	}
	if fake.count() != 0 {
		t.Fatalf("unauthenticated request reached upstream")
	}
	tok := map[string]string{"Cf-Access-Jwt-Assertion": iss.mint("subject-alice", nil)}
	if resp, body := getPreview(t, srv, page, tok); resp.StatusCode != 200 {
		t.Fatalf("authenticated page: %d %s", resp.StatusCode, body)
	}
	if resp, body := getPreview(t, srv, image, tok); resp.StatusCode != 200 {
		t.Fatalf("authenticated image: %d %s", resp.StatusCode, body)
	}
	if resp, _ := getPreview(t, srv, page, nil); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("cache must not bypass auth: %d", resp.StatusCode)
	}
}

func TestPreviewDialControl(t *testing.T) {
	for _, a := range []string{"104.244.42.1:443", "151.101.0.1:443", "[2606:4700::1]:443"} {
		if err := previewDialControl("tcp", a, nil); err != nil {
			t.Errorf("%s refused: %v", a, err)
		}
	}
	for _, a := range []string{
		"127.0.0.1:443", "10.0.0.1:443", "172.16.0.1:443", "192.168.1.1:443", "169.254.169.254:80",
		"100.100.100.100:443", "0.0.0.0:443", "[::1]:443", "[fd00::1]:443", "[fe80::1]:443",
		"[::ffff:127.0.0.1]:443", "224.0.0.1:443", "x.com:443",
	} {
		if err := previewDialControl("tcp", a, nil); err == nil {
			t.Errorf("%s allowed", a)
		}
	}
}

// Logs never carry the status id or a URL path, even on transport errors
// (whose *url.Error text includes the URL).
func TestPreviewLogsNoPathOrID(t *testing.T) {
	var buf bytes.Buffer
	captureLog(t, &buf)
	_, srv, _ := newPreviewRelay(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/secrethandle/status/987654321":
			io.WriteString(w, ogPage("t", "", "https://pbs.twimg.com/media/SECRETMEDIA.jpg"))
		case "/secrethandle/status/987654322":
			http.Redirect(w, r, "https://evil.example/secrethandle/status/987654322", http.StatusFound)
		default:
			w.Header().Set("Content-Type", "text/html")
			io.WriteString(w, "x")
		}
	}))
	getPreview(t, srv, previewQuery("https://x.com/secrethandle/status/987654321"), nil)
	getPreview(t, srv, previewQuery("https://x.com/secrethandle/status/987654322"), nil)
	getPreview(t, srv, previewImagePath+"?u="+url.QueryEscape("https://pbs.twimg.com/media/SECRETMEDIA.jpg"), nil)
	out := buf.String()
	if !strings.Contains(out, "host=x.com") {
		t.Fatalf("expected host-only log lines, got %q", out)
	}
	for _, leak := range []string{"secrethandle", "98765432", "SECRETMEDIA", "/status/"} {
		if strings.Contains(out, leak) {
			t.Fatalf("log leaks %q: %s", leak, out)
		}
	}
}

type lockedBuffer struct {
	mu  sync.Mutex
	buf *bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.Write(p)
}

// captureLog redirects the standard logger into buf for the test.
func captureLog(t *testing.T, buf *bytes.Buffer) {
	t.Helper()
	lb := &lockedBuffer{buf: buf}
	prev := log.Writer()
	log.SetOutput(lb)
	t.Cleanup(func() { log.SetOutput(prev) })
}

// The image target is rebuilt from a constant host prefix: case, fragment and
// anything but path+query from the caller are dropped (CodeQL go/request-forgery).
func TestNormalizeImageURLRebuildsFromConstantHost(t *testing.T) {
	cases := map[string]string{
		"https://PBS.twimg.com/media/a.jpg?format=jpg&name=small#frag": "https://pbs.twimg.com/media/a.jpg?format=jpg&name=small",
		"https://abs.twimg.com/emoji/v2/72x72/1f600.png":                "https://abs.twimg.com/emoji/v2/72x72/1f600.png",
	}
	for in, want := range cases {
		got, ok := normalizeImageURL(in)
		if !ok || got != want {
			t.Errorf("normalizeImageURL(%q) = %q, %v; want %q", in, got, ok, want)
		}
	}
	for _, bad := range []string{"https://pbs.twimg.com.evil.example/a.jpg", "http://pbs.twimg.com/a.jpg", "https://u@pbs.twimg.com/a.jpg", "https://pbs.twimg.com:444/a.jpg"} {
		if got, ok := normalizeImageURL(bad); ok {
			t.Errorf("normalizeImageURL(%q) = %q, want refused", bad, got)
		}
	}
}
