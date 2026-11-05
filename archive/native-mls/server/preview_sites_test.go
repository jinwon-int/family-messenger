package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"reflect"
	"strings"
	"testing"
)

// The registry is exactly the contract v2 table (#690).
func TestPreviewRegistryMatchesContract(t *testing.T) {
	type row struct {
		id, name   string
		hosts      []string
		preview    bool
		imageHosts []string
	}
	want := []row{
		{"x", "X", []string{"x.com", "www.x.com", "mobile.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"}, true, []string{"pbs.twimg.com", "abs.twimg.com"}},
		{"youtube", "YouTube", []string{"youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"}, true, []string{"i.ytimg.com"}},
		{"naver-news", "네이버 뉴스", []string{"n.news.naver.com", "news.naver.com", "m.news.naver.com"}, true, []string{"imgnews.pstatic.net"}},
		{"wikipedia", "위키백과", []string{"ko.wikipedia.org", "en.wikipedia.org", "ko.m.wikipedia.org", "en.m.wikipedia.org"}, true, []string{"thumb.wikimedia.org", "upload.wikimedia.org"}},
		{"github", "GitHub", []string{"github.com", "www.github.com"}, true, []string{"opengraph.githubassets.com", "repository-images.githubusercontent.com", "avatars.githubusercontent.com"}},
		{"bbc", "BBC", []string{"bbc.com", "www.bbc.com", "bbc.co.uk", "www.bbc.co.uk"}, true, []string{"ichef.bbci.co.uk"}},
		{"threads", "Threads", []string{"threads.net", "www.threads.net", "threads.com", "www.threads.com"}, false, nil},
		{"reuters", "Reuters", []string{"reuters.com", "www.reuters.com"}, false, nil},
	}
	if len(previewSites) != len(want) {
		t.Fatalf("registry has %d sites, contract %d", len(previewSites), len(want))
	}
	for i, w := range want {
		s := previewSites[i]
		got := row{s.id, s.name, s.hosts, s.preview(), s.imageHosts}
		if !reflect.DeepEqual(got, w) {
			t.Errorf("site %d: got %+v want %+v", i, got, w)
		}
		if s.ua() != "Twitterbot/1.0" {
			t.Errorf("site %s UA %q", s.id, s.ua())
		}
	}
	// A malformed registry is refused (duplicate host, preview without images).
	for name, bad := range map[string][]*previewSite{
		"dup host":   {{id: "a", name: "A", hosts: []string{"dup-a.example"}}, {id: "b", name: "B", hosts: []string{"dup-a.example"}}},
		"dup id":     {{id: "a", name: "A", hosts: []string{"dup-b.example"}}, {id: "a", name: "A", hosts: []string{"dup-c.example"}}},
		"upper host": {{id: "a", name: "A", hosts: []string{"Upper.example"}}},
		"no images":  {{id: "a", name: "A", hosts: []string{"noimg.example"}, page: bbcPage}},
		"link imgs":  {{id: "a", name: "A", hosts: []string{"linkimg.example"}, imageHosts: []string{"img.example"}}},
	} {
		_, err := indexPreviewSites(bad)
		if err == nil {
			t.Errorf("%s: malformed registry accepted", name)
		}
	}
}

// Every registry image host has its literal case in normalizeImageURL (and
// nothing else does): the switch and the registry cannot drift apart.
func TestPreviewRegistryImageHostsRebuilt(t *testing.T) {
	n := 0
	for _, s := range previewSites {
		for _, h := range s.imageHosts {
			n++
			in := "https://" + strings.ToUpper(h) + "/p/a.jpg?w=1#f"
			got, ok := normalizeImageURL(in)
			if !ok || got != "https://"+h+"/p/a.jpg?w=1" {
				t.Errorf("%s: normalizeImageURL(%q) = %q, %v", s.id, in, got, ok)
			}
			if got, ok := normalizeSiteImageURL(in, s); !ok || got != "https://"+h+"/p/a.jpg?w=1" {
				t.Errorf("%s: own image host %s refused", s.id, h)
			}
			for _, other := range previewSites {
				if other != s {
					if _, ok := normalizeSiteImageURL(in, other); ok {
						t.Errorf("%s image host %s accepted for site %s", s.id, h, other.id)
					}
				}
			}
		}
	}
	if n != len(previewImageHosts) {
		t.Fatalf("image hosts %d vs union %d", n, len(previewImageHosts))
	}
	// Hosts of link-only sites, page hosts and look-alikes are not image hosts.
	for _, b := range []string{
		"https://scontent-icn2-1.cdninstagram.com/v/a.jpg", "https://www.threads.net/a.jpg", "https://threads.com/a.jpg",
		"https://www.reuters.com/a.jpg", "https://reuters.com/a.jpg", "https://www.youtube.com/a.jpg", "https://github.com/a.png",
		"https://i.ytimg.com.evil.example/a.jpg", "https://ytimg.com/a.jpg", "https://i9.ytimg.com/a.jpg", "https://evilpstatic.net/a.jpg",
		"https://wikimedia.org/a.jpg", "https://commons.wikimedia.org/a.jpg", "https://githubusercontent.com/a.png",
		"https://raw.githubusercontent.com/a.png", "https://ichef.bbci.co.uk:443/a.jpg", "https://u@ichef.bbci.co.uk/a.jpg",
		"http://i.ytimg.com/a.jpg",
	} {
		if got, ok := normalizeImageURL(b); ok {
			t.Errorf("%q accepted as %q", b, got)
		}
	}
}

func TestNormalizePreviewURLSites(t *testing.T) {
	long := func(n int) string { return strings.Repeat("a", n) }
	good := []struct{ in, site, canonical string }{
		// x keeps the v1 canonical form; its cache identity is the status id.
		{"https://twitter.com/jack/status/20?s=1", "x", "https://x.com/jack/status/20"},
		// YouTube: watch / shorts / youtu.be / m. → one canonical watch URL.
		{"https://www.youtube.com/watch?v=dQw4w9WgXcQ", "youtube", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"},
		{"https://youtube.com/watch?v=dQw4w9WgXcQ&t=42s&list=PL1", "youtube", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"},
		{"https://m.youtube.com/watch?feature=share&v=a-_B9c8D7e6#t=1", "youtube", "https://www.youtube.com/watch?v=a-_B9c8D7e6"},
		{"https://WWW.YouTube.com/shorts/dQw4w9WgXcQ?feature=share", "youtube", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"},
		{"https://www.youtube.com/shorts/dQw4w9WgXcQ/", "youtube", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"},
		{"https://youtu.be/dQw4w9WgXcQ?si=abc", "youtube", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"},
		{"https://www.youtube.com/watch/?v=dQw4w9WgXcQ", "youtube", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}, // one trailing "/" is ignored on every site
		{"https://www.bbc.com/news/articles/c1234567", "bbc", "https://www.bbc.com/news/articles/c1234567"},
		// Naver news: n./news./m. and /mnews/ → n.news.naver.com/article.
		{"https://n.news.naver.com/article/001/0015000000?sid=104", "naver-news", "https://n.news.naver.com/article/001/0015000000"},
		{"https://news.naver.com/article/023/0003870000", "naver-news", "https://n.news.naver.com/article/023/0003870000"},
		{"https://m.news.naver.com/article/001/0015000000/", "naver-news", "https://n.news.naver.com/article/001/0015000000"},
		{"https://n.news.naver.com/mnews/article/001/0015000000?sid=100", "naver-news", "https://n.news.naver.com/article/001/0015000000"},
		// Wikipedia: ko/en, mobile → desktop, title stays escaped, query dropped.
		{"https://ko.wikipedia.org/wiki/%EC%84%9C%EC%9A%B8", "wikipedia", "https://ko.wikipedia.org/wiki/%EC%84%9C%EC%9A%B8"},
		{"https://ko.wikipedia.org/wiki/서울", "wikipedia", "https://ko.wikipedia.org/wiki/%EC%84%9C%EC%9A%B8"},
		{"https://ko.m.wikipedia.org/wiki/%EC%84%9C%EC%9A%B8?action=x#s", "wikipedia", "https://ko.wikipedia.org/wiki/%EC%84%9C%EC%9A%B8"},
		{"https://en.wikipedia.org/wiki/Go_(programming_language)", "wikipedia", "https://en.wikipedia.org/wiki/Go_(programming_language)"},
		{"https://en.m.wikipedia.org/wiki/AC/DC", "wikipedia", "https://en.wikipedia.org/wiki/AC/DC"},
		{"https://en.wikipedia.org/wiki/AC%2FDC", "wikipedia", "https://en.wikipedia.org/wiki/AC%2FDC"},
		{"https://en.wikipedia.org/wiki/" + long(300), "wikipedia", "https://en.wikipedia.org/wiki/" + long(300)},
		// GitHub: repo, issue, pull, discussion; www → github.com.
		{"https://github.com/golang/go", "github", "https://github.com/golang/go"},
		{"https://www.github.com/jinwon-int/family-messenger/", "github", "https://github.com/jinwon-int/family-messenger"},
		{"https://github.com/golang/go/issues/1?x=1#c", "github", "https://github.com/golang/go/issues/1"},
		{"https://github.com/a.b_c-d/r.e_p-o/pull/123456789", "github", "https://github.com/a.b_c-d/r.e_p-o/pull/123456789"},
		{"https://github.com/o/r/discussions/7", "github", "https://github.com/o/r/discussions/7"},
		// BBC: .com / .co.uk / www → www.bbc.com.
		{"https://www.bbc.com/news/articles/crz98zqkz7z0o", "bbc", "https://www.bbc.com/news/articles/crz98zqkz7z0o"},
		{"https://bbc.co.uk/news/articles/c12345678?at_medium=RSS", "bbc", "https://www.bbc.com/news/articles/c12345678"},
		{"https://www.bbc.co.uk/news/articles/" + strings.Repeat("z", 20) + "/", "bbc", "https://www.bbc.com/news/articles/" + strings.Repeat("z", 20)},
	}
	for _, g := range good {
		site, c, _, ok := normalizePreviewURL(g.in)
		if !ok || site.id != g.site || c != g.canonical {
			id := ""
			if site != nil {
				id = site.id
			}
			t.Errorf("%q: got (%s,%q,%v) want (%s,%q)", g.in, id, c, ok, g.site, g.canonical)
		}
	}
	bad := []string{
		// Link-only sites never preview.
		"https://www.threads.net/@user/post/ABC", "https://threads.com/@u/post/x", "https://www.reuters.com/world/some-story-2026-11-05/",
		"https://reuters.com/world/",
		// Scheme, userinfo, port, look-alike / unknown hosts.
		"http://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://user@www.youtube.com/watch?v=dQw4w9WgXcQ",
		"https://www.youtube.com:443/watch?v=dQw4w9WgXcQ", "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ",
		"https://evilyoutube.com/watch?v=dQw4w9WgXcQ", "https://youtu.be.evil.example/dQw4w9WgXcQ", "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
		"https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ", "https://youtube.com./watch?v=dQw4w9WgXcQ",
		"https://n.news.naver.com.evil.example/article/001/0015000000", "https://naver.com/article/001/0015000000",
		"https://entertain.naver.com/article/001/0015000000", "https://sports.news.naver.com/article/001/0015000000",
		"https://ja.wikipedia.org/wiki/Tokyo", "https://wikipedia.org/wiki/Seoul", "https://ko.wikipedia.org.evil.example/wiki/Seoul",
		"https://ko.wikipedia.org:8443/wiki/Seoul", "https://a:b@ko.wikipedia.org/wiki/Seoul",
		"https://gist.github.com/a/b", "https://github.com.evil.example/a/b", "https://githubusercontent.com/a/b", "https://user@github.com/a/b",
		"https://bbc.co/news/articles/c12345678", "https://bbc.com.evil.example/news/articles/c12345678", "https://news.bbc.co.uk/news/articles/c12345678",
		// YouTube paths and ids.
		"https://www.youtube.com/watch", "https://www.youtube.com/watch?v=", "https://www.youtube.com/watch?v=dQw4w9WgXc",
		"https://www.youtube.com/watch?v=dQw4w9WgXcQQ", "https://www.youtube.com/watch?v=dQw4w9WgXc%21",
		"https://www.youtube.com/watch?v=dQw4w9WgXcQ&v=aaaaaaaaaaa",
		"https://www.youtube.com/shorts/", "https://www.youtube.com/shorts/dQw4w9WgXcQ/extra", "https://www.youtube.com/embed/dQw4w9WgXcQ",
		"https://www.youtube.com/dQw4w9WgXcQ", "https://www.youtube.com/@channel", "https://youtu.be/", "https://youtu.be/watch?v=dQw4w9WgXcQ",
		"https://youtu.be/dQw4w9WgXcQ/x", "https://youtu.be/dQw4w9WgXc%51", "https://www.youtube.com/Shorts/dQw4w9WgXcQ",
		// Naver paths and ids.
		"https://n.news.naver.com/article/01/0015000000", "https://n.news.naver.com/article/0001/0015000000",
		"https://n.news.naver.com/article/001/001500000", "https://n.news.naver.com/article/001/00150000000",
		"https://n.news.naver.com/article/001", "https://n.news.naver.com/article/comment/001/0015000000",
		"https://n.news.naver.com/mnews/article/001", "https://n.news.naver.com/mnews/001/0015000000",
		"https://news.naver.com/main/read.naver?oid=001&aid=0015000000", "https://n.news.naver.com/article/abc/0015000000",
		"https://n.news.naver.com/article/001/0015000000/extra",
		// Wikipedia titles.
		"https://ko.wikipedia.org/wiki/", "https://ko.wikipedia.org/wiki", "https://ko.wikipedia.org/w/index.php?title=Seoul",
		"https://en.wikipedia.org/wiki/" + long(301), "https://en.wikipedia.org/wiki/../w/api.php", "https://en.wikipedia.org/wiki/./x",
		"https://en.wikipedia.org/wiki/a//b", "https://en.wikipedia.org/wiki/a/", "https://en.wikipedia.org/wiki/%2e%2e",
		"https://en.wikipedia.org/wiki/a/%2E%2E/b", "https://en.wikipedia.org/Wiki/Seoul", "https://en.wikipedia.org/wiki/%",
		// GitHub paths.
		"https://github.com/", "https://github.com/golang", "https://github.com/golang/go/tree/master", "https://github.com/golang/go/issues",
		"https://github.com/golang/go/issues/abc", "https://github.com/golang/go/issues/1234567890", "https://github.com/golang/go/pulls/1",
		"https://github.com/golang/go/issues/1/files", "https://github.com/../go", "https://github.com/golang/..", "https://github.com/./go",
		"https://github.com/" + long(101) + "/r", "https://github.com/o/r~", "https://github.com/o%2Fr/x", "https://github.com/o/r/Issues/1",
		// BBC paths and ids.
		"https://www.bbc.com/news/articles/c123456", "https://www.bbc.com/news/articles/" + long(21), "https://www.bbc.com/news/articles/C12345678",
		"https://www.bbc.com/news/world-12345678", "https://www.bbc.com/sport/articles/c12345678", "https://www.bbc.com/news/articles",
		"https://www.bbc.com/news/articles/c12345678/x", "https://www.bbc.com/news/articles/c1234567%38",
		// Misc.
		"", "javascript:alert(1)", "https://www.youtube.com/watch?v=dQw4w9WgXcQ&pad=" + long(previewURLMaxBytes),
	}
	for _, b := range bad {
		if site, c, _, ok := normalizePreviewURL(b); ok {
			t.Errorf("%q accepted as (%s,%q)", b, site.id, c)
		}
	}
}

// GET /v2/preview/sites: exact JSON, headers, auth, flag off → 404.
func TestPreviewSitesEndpoint(t *testing.T) {
	_, off := newTestRelay(t, testPolicy())
	if resp, body := getPreview(t, off, previewSitesPath, nil); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("flag off: %d %s", resp.StatusCode, body)
	}

	r, srv, fake := newPreviewRelay(t, http.NotFoundHandler())
	resp, body := getPreview(t, srv, previewSitesPath, nil)
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
	var got struct {
		Version int `json:"version"`
		Sites   []struct {
			ID      string   `json:"id"`
			Name    string   `json:"name"`
			Hosts   []string `json:"hosts"`
			Preview bool     `json:"preview"`
		} `json:"sites"`
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&got); err != nil {
		t.Fatalf("decode %s: %v", body, err)
	}
	if got.Version != 2 || len(got.Sites) != len(previewSites) {
		t.Fatalf("body %s", body)
	}
	for i, s := range previewSites {
		g := got.Sites[i]
		if g.ID != s.id || g.Name != s.name || !reflect.DeepEqual(g.Hosts, s.hosts) || g.Preview != s.preview() {
			t.Errorf("site %d: %+v", i, g)
		}
	}
	if !bytes.Contains(body, []byte(`{"id":"threads","name":"Threads","hosts":["threads.net","www.threads.net","threads.com","www.threads.com"],"preview":false}`)) ||
		!bytes.HasPrefix(body, []byte(`{"version":2,"sites":[{"id":"x","name":"X","hosts":["x.com",`)) {
		t.Errorf("wire shape %s", body)
	}
	if fake.count() != 0 {
		t.Fatalf("sites endpoint contacted upstream")
	}

	// Behind the same authentication as the other preview routes.
	iss := newTestIssuer(t)
	r.access = iss.verifier()
	srv.Config.Handler = r.routes()
	if resp, body := getPreview(t, srv, previewSitesPath, nil); resp.StatusCode != http.StatusUnauthorized || resp.Header.Get("Cache-Control") != "no-store" {
		t.Errorf("no token: %d %q %s", resp.StatusCode, resp.Header.Get("Cache-Control"), body)
	}
	if resp, _ := getPreview(t, srv, previewSitesPath, map[string]string{"Cf-Access-Jwt-Assertion": "not.a.jwt"}); resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("garbage token: %d", resp.StatusCode)
	}
	if resp, _ := getPreview(t, srv, previewSitesPath, map[string]string{"Cf-Access-Jwt-Assertion": iss.mint("s", nil), "Sec-Fetch-Site": "cross-site"}); resp.StatusCode != http.StatusForbidden {
		t.Errorf("cross-site: %d", resp.StatusCode)
	}
	if resp, b := getPreview(t, srv, previewSitesPath, map[string]string{"Cf-Access-Jwt-Assertion": iss.mint("subject-alice", nil)}); resp.StatusCode != http.StatusOK || !bytes.Equal(b, body) {
		t.Errorf("authenticated: %d %s", resp.StatusCode, b)
	}
}

// Each new preview site: canonical upstream fetch, site name in the
// response, og:image rewritten through the image route only for the site's
// own image hosts, no client credentials upstream.
func TestPreviewNewSitesSuccess(t *testing.T) {
	images := map[string]string{
		"www.youtube.com":   "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg",
		"n.news.naver.com":  "https://imgnews.pstatic.net/image/001/2026/11/05/a.jpg?type&#x3D;w800",
		"ko.wikipedia.org":  "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/ab/x.jpg/1280px-x.jpg",
		"en.wikipedia.org":  "https://upload.wikimedia.org/wikipedia/commons/a/ab/x.jpg",
		"github.com":        "https://opengraph.githubassets.com/abc/golang/go",
		"www.bbc.com":       "https://ichef.bbci.co.uk/news/1024/branded_news/a.jpg",
		"other-site-images": "https://pbs.twimg.com/media/A.jpg",
	}
	_, srv, fake := newPreviewRelay(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		img := images[r.URL.Host]
		if r.URL.Path == "/o/wrongimg" {
			img = images["other-site-images"] // an x image on a GitHub page
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		io.WriteString(w, ogPage("T "+r.URL.Host, "D", img))
	}))
	for _, c := range []struct{ link, site, canonical, host, path, query, image string }{
		{"https://youtu.be/dQw4w9WgXcQ?si=z", "YouTube", "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "www.youtube.com", "/watch", "v=dQw4w9WgXcQ", "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg"},
		{"https://m.news.naver.com/mnews/article/001/0015000000", "네이버 뉴스", "https://n.news.naver.com/article/001/0015000000", "n.news.naver.com", "/article/001/0015000000", "", "https://imgnews.pstatic.net/image/001/2026/11/05/a.jpg?type=w800"},
		{"https://ko.m.wikipedia.org/wiki/%EC%84%9C%EC%9A%B8", "위키백과", "https://ko.wikipedia.org/wiki/%EC%84%9C%EC%9A%B8", "ko.wikipedia.org", "/wiki/서울", "", "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/ab/x.jpg/1280px-x.jpg"},
		{"https://en.wikipedia.org/wiki/Seoul", "위키백과", "https://en.wikipedia.org/wiki/Seoul", "en.wikipedia.org", "/wiki/Seoul", "", "https://upload.wikimedia.org/wikipedia/commons/a/ab/x.jpg"},
		{"https://www.github.com/golang/go/pull/5", "GitHub", "https://github.com/golang/go/pull/5", "github.com", "/golang/go/pull/5", "", "https://opengraph.githubassets.com/abc/golang/go"},
		{"https://bbc.co.uk/news/articles/c12345678", "BBC", "https://www.bbc.com/news/articles/c12345678", "www.bbc.com", "/news/articles/c12345678", "", "https://ichef.bbci.co.uk/news/1024/branded_news/a.jpg"},
		{"https://github.com/o/wrongimg", "GitHub", "https://github.com/o/wrongimg", "github.com", "/o/wrongimg", "", ""},
	} {
		before := fake.count()
		resp, body := getPreview(t, srv, previewQuery(c.link), map[string]string{"Cookie": "CF_Authorization=s", "Authorization": "Bearer s"})
		if resp.StatusCode != http.StatusOK {
			t.Errorf("%s: %d %s", c.link, resp.StatusCode, body)
			continue
		}
		var got map[string]any
		if err := json.Unmarshal(body, &got); err != nil {
			t.Fatal(err)
		}
		var wantImg any
		if c.image != "" {
			wantImg = previewImagePath + "?u=" + url.QueryEscape(c.image)
		}
		if got["url"] != c.canonical || got["site"] != c.site || got["title"] != "T "+c.host || got["description"] != "D" || got["image"] != wantImg || len(got) != 5 {
			t.Errorf("%s: body %s (want image %v)", c.link, body, wantImg)
		}
		reqs := fake.requests()
		if len(reqs) != before+1 {
			t.Errorf("%s: upstream calls %d", c.link, len(reqs)-before)
			continue
		}
		u := reqs[len(reqs)-1]
		if u.scheme != "https" || u.host != c.host || u.path != c.path {
			t.Errorf("%s: upstream %s://%s%s", c.link, u.scheme, u.host, u.path)
		}
		if u.header.Get("User-Agent") != previewUserAgent || u.header.Get("Cookie") != "" || u.header.Get("Authorization") != "" {
			t.Errorf("%s: upstream headers %v", c.link, u.header)
		}
	}
	// The YouTube fetch carried only the canonical query.
	for _, r := range fake.requests() {
		if r.host == "www.youtube.com" && r.path != "/watch" {
			t.Errorf("youtube fetched %s", r.path)
		}
	}
}

// Link-only sites and rule mismatches are 400 bad_url and never fetched.
func TestPreviewLinkOnlyAndMismatchBadURL(t *testing.T) {
	_, srv, fake := newPreviewRelay(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, ogPage("t", "d", ""))
	}))
	for _, link := range []string{
		"https://www.threads.net/@user/post/ABC123", "https://threads.com/@user", "https://www.reuters.com/world/asia-pacific/story-2026-11-05/",
		"https://reuters.com/", "https://www.youtube.com/@channel", "https://github.com/golang/go/tree/master", "https://www.bbc.com/news",
		"https://n.news.naver.com/main/ranking", "https://ja.wikipedia.org/wiki/Tokyo",
	} {
		resp, body := getPreview(t, srv, previewQuery(link), nil)
		if resp.StatusCode != http.StatusBadRequest || !bytes.Contains(body, []byte(`"bad_url"`)) {
			t.Errorf("%s: %d %s", link, resp.StatusCode, body)
		}
	}
	if n := fake.count(); n != 0 {
		t.Fatalf("refused links reached upstream %d times", n)
	}
}

// The image route serves every preview site's image hosts and refuses link-only
// sites' hosts (and page hosts) before any upstream contact.
func TestPreviewImageRouteV2Hosts(t *testing.T) {
	png := []byte("\x89PNG\r\n\x1a\n....")
	_, srv, fake := newPreviewRelay(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !previewImageHosts[r.URL.Host] {
			t.Errorf("image fetch contacted %s", r.URL.Host)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		w.Write(png)
	}))
	for h := range previewImageHosts {
		resp, body := getPreview(t, srv, previewImagePath+"?u="+url.QueryEscape("https://"+h+"/a/b.png?x=1"), nil)
		if resp.StatusCode != 200 || !bytes.Equal(body, png) || resp.Header.Get("Content-Security-Policy") != "default-src 'none'; sandbox" {
			t.Errorf("%s: %d %q", h, resp.StatusCode, resp.Header.Get("Content-Security-Policy"))
		}
	}
	reqs := fake.requests()
	if len(reqs) != len(previewImageHosts) {
		t.Fatalf("upstream calls %d", len(reqs))
	}
	before := fake.count()
	for _, u := range []string{
		"https://scontent-icn2-1.cdninstagram.com/v/t51/a.jpg", "https://www.threads.net/a.jpg", "https://www.reuters.com/a.jpg",
		"https://www.youtube.com/a.jpg", "https://www.bbc.com/a.jpg", "https://i.ytimg.com.evil.example/a.jpg",
	} {
		if resp, body := getPreview(t, srv, previewImagePath+"?u="+url.QueryEscape(u), nil); resp.StatusCode != http.StatusBadRequest || !bytes.Contains(body, []byte("bad_url")) {
			t.Errorf("%s: %d %s", u, resp.StatusCode, body)
		}
	}
	if fake.count() != before {
		t.Fatalf("refused image URL reached upstream")
	}
}

// A redirect may stay within the requested site's hosts only: a page of one
// preview site redirecting to another (preview or link-only) site's host, and
// an image redirecting to another site's image host, are refused.
func TestPreviewRedirectToOtherSiteRefused(t *testing.T) {
	_, srv, fake := newPreviewRelay(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Host + r.URL.Path {
		case "www.youtube.com/watch":
			switch r.URL.Query().Get("v") {
			case "aaaaaaaaaaa":
				http.Redirect(w, r, "https://x.com/a/status/1", http.StatusFound)
			case "bbbbbbbbbbb":
				http.Redirect(w, r, "https://www.threads.net/@a", http.StatusFound)
			case "ccccccccccc": // same site, other host: followed
				http.Redirect(w, r, "https://m.youtube.com/watch?v=ccccccccccc", http.StatusFound)
			}
		case "github.com/o/r":
			http.Redirect(w, r, "https://www.bbc.com/news/articles/c12345678", http.StatusMovedPermanently)
		case "www.bbc.com/news/articles/c12345678":
			http.Redirect(w, r, "https://www.bbc.co.uk/news/articles/c12345678", http.StatusFound)
		case "www.bbc.co.uk/news/articles/c12345678", "m.youtube.com/watch":
			io.WriteString(w, ogPage("followed", "", ""))
		case "i.ytimg.com/a.jpg":
			http.Redirect(w, r, "https://pbs.twimg.com/a.jpg", http.StatusFound)
		case "thumb.wikimedia.org/a.jpg":
			http.Redirect(w, r, "https://upload.wikimedia.org/a.jpg", http.StatusFound)
		case "upload.wikimedia.org/a.jpg", "pbs.twimg.com/a.jpg":
			w.Header().Set("Content-Type", "image/jpeg")
			w.Write([]byte{0xFF, 0xD8, 0xFF})
		default:
			t.Errorf("unexpected upstream %s%s", r.URL.Host, r.URL.Path)
		}
	}))
	for link, want := range map[string]int{
		"https://www.youtube.com/watch?v=aaaaaaaaaaa": 502,
		"https://www.youtube.com/watch?v=bbbbbbbbbbb": 502,
		"https://www.youtube.com/watch?v=ccccccccccc": 200,
		"https://github.com/o/r":                      502,
		"https://www.bbc.com/news/articles/c12345678": 200,
	} {
		if resp, body := getPreview(t, srv, previewQuery(link), nil); resp.StatusCode != want {
			t.Errorf("%s: %d %s (want %d)", link, resp.StatusCode, body, want)
		}
	}
	for u, want := range map[string]int{"https://i.ytimg.com/a.jpg": 502, "https://thumb.wikimedia.org/a.jpg": 200} {
		if resp, body := getPreview(t, srv, previewImagePath+"?u="+url.QueryEscape(u), nil); resp.StatusCode != want {
			t.Errorf("%s: %d %s (want %d)", u, resp.StatusCode, body, want)
		}
	}
	for _, r := range fake.requests() {
		switch r.host {
		case "x.com", "www.threads.net", "pbs.twimg.com":
			t.Errorf("cross-site redirect target %s contacted", r.host)
		}
		if r.host == "www.bbc.com" && r.path != "/news/articles/c12345678" {
			t.Errorf("github redirect followed to bbc")
		}
	}
	// youtube a,b (1 each), c (2), github (1), bbc (2), ytimg (1), thumb→upload (2).
	if n := len(fake.requests()); n != 10 {
		t.Errorf("upstream requests %d, want 10", n)
	}
}

// The cache key is site id + page identity: equal identities in two sites
// never share an entry, and results stay per site.
func TestPreviewCacheKeySiteIsolation(t *testing.T) {
	if previewCacheKey(previewSites[0], "k") == previewCacheKey(previewSites[1], "k") {
		t.Fatal("cache keys of two sites collide")
	}
	r, srv, fake := newPreviewRelay(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, ogPage("title "+r.URL.Host, "", ""))
	}))
	links := []string{
		"https://x.com/a/status/20", "https://github.com/a/b/issues/20", "https://www.youtube.com/watch?v=aaaaaaaaaaa",
		"https://en.wikipedia.org/wiki/aaaaaaaaaaa", "https://www.bbc.com/news/articles/aaaaaaaaaaa",
	}
	for range 2 {
		for _, l := range links {
			resp, body := getPreview(t, srv, previewQuery(l), nil)
			site, _, _, _ := normalizePreviewURL(l)
			host := map[string]string{"x": "x.com", "github": "github.com", "youtube": "www.youtube.com", "wikipedia": "en.wikipedia.org", "bbc": "www.bbc.com"}[site.id]
			if resp.StatusCode != 200 || !bytes.Contains(body, []byte(`"title":"title `+host+`"`)) || !bytes.Contains(body, []byte(`"site":"`+site.name+`"`)) {
				t.Errorf("%s: %d %s", l, resp.StatusCode, body)
			}
		}
	}
	if n := fake.count(); n != len(links) {
		t.Fatalf("upstream calls %d, want %d (one per site, then cached)", n, len(links))
	}
	r.preview.mu.Lock()
	keys := make([]string, 0, len(r.preview.cache))
	for k := range r.preview.cache {
		keys = append(keys, k)
	}
	r.preview.mu.Unlock()
	want := map[string]bool{
		"x\x00https://x.com/i/web/status/20":                     true,
		"github\x00https://github.com/a/b/issues/20":             true,
		"youtube\x00https://www.youtube.com/watch?v=aaaaaaaaaaa": true,
		"wikipedia\x00https://en.wikipedia.org/wiki/aaaaaaaaaaa": true,
		"bbc\x00https://www.bbc.com/news/articles/aaaaaaaaaaa":   true,
	}
	if len(keys) != len(want) {
		t.Fatalf("cache keys %q", keys)
	}
	for _, k := range keys {
		if !want[k] {
			t.Errorf("unexpected cache key %q", k)
		}
	}
}

// og parsing is site-agnostic: markup in the shape the new sites serve
// (live-checked 2026-11-05) yields the same fields as for x.com.
func TestParseOGMetaNewSiteShapes(t *testing.T) {
	for name, c := range map[string]struct{ page, title, image string }{
		"youtube": {`<meta property="og:title" content="Me at the zoo"><meta property="og:image" content="https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg?sqp=-oay&amp;rs=AOn4">`, "Me at the zoo", "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg?sqp=-oay&rs=AOn4"},
		"naver":   {`<meta property="og:title" content="전자·IT의 날"/><meta property="og:image" content="https://imgnews.pstatic.net/image/001/a.jpg?type&#x3D;w800"/>`, "전자·IT의 날", "https://imgnews.pstatic.net/image/001/a.jpg?type=w800"},
		"github":  {`<meta property="og:image" content="https://opengraph.githubassets.com/d2/golang/go" /><meta property="og:title" content="GitHub - golang/go" />`, "GitHub - golang/go", "https://opengraph.githubassets.com/d2/golang/go"},
		"bbc":     {`<meta property="og:title" content="Headline" data-next-head=""/><meta property="og:image" content="https://ichef.bbci.co.uk/news/1024/a.jpg" data-next-head=""/>`, "Headline", "https://ichef.bbci.co.uk/news/1024/a.jpg"},
	} {
		m := parseOGMeta([]byte(c.page))
		if m.Title != c.title || m.Image != c.image {
			t.Errorf("%s: %+v", name, m)
		}
	}
}

// Logs of the new sites carry site and host only, never a path or an id.
func TestPreviewLogsNoPathOrIDV2(t *testing.T) {
	var buf bytes.Buffer
	captureLog(t, &buf)
	_, srv, _ := newPreviewRelay(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Host == "github.com" {
			http.Redirect(w, r, "https://evil.example/secretowner", http.StatusFound)
			return
		}
		io.WriteString(w, ogPage("t", "", "https://i.ytimg.com/vi/SECRETVIDEO/a.jpg"))
	}))
	getPreview(t, srv, previewQuery("https://www.youtube.com/watch?v=SECRETVIDEO"), nil)
	getPreview(t, srv, previewQuery("https://github.com/secretowner/secretrepo/issues/987654321"), nil)
	getPreview(t, srv, previewQuery("https://n.news.naver.com/article/001/0019876543"), nil)
	out := buf.String()
	if !strings.Contains(out, "site=youtube") || !strings.Contains(out, "host=www.youtube.com") || !strings.Contains(out, "site=github") {
		t.Fatalf("expected site/host log lines, got %q", out)
	}
	for _, leak := range []string{"SECRETVIDEO", "secretowner", "secretrepo", "98765432", "0019876543", "/watch", "/article/"} {
		if strings.Contains(out, leak) {
			t.Fatalf("log leaks %q: %s", leak, out)
		}
	}
}
