// Link preview site registry (#690, contract "계약 v2"). One place lists
// every site the clients may link to and, for the preview sites, how a link
// maps to the one canonical page the relay fetches and which image hosts its
// og:image may name. Everything else in preview.go is site-agnostic.
//
// Adding a site = one entry here + (for a preview site) one path-rule func
// and its image hosts' literal cases in normalizeImageURL. The client learns
// the list from GET /v2/preview/sites, so no app release is needed.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

const previewSitesPath = "/v2/preview/sites"

// previewSitesVersion is the "version" field of GET /v2/preview/sites.
const previewSitesVersion = 2

// previewSite is one registry entry. hosts are matched lower-cased and
// exactly (no suffix matching). page is nil for link-only sites.
type previewSite struct {
	id, name   string
	hosts      []string
	userAgent  string
	imageHosts []string
	// page maps a link already known to be https on one of hosts (no
	// userinfo, no port) to the canonical page URL the relay fetches and the
	// cache identity of that page. Every returned fetch URL is a constant
	// "https://<host>/" prefix concatenated with validated path parts
	// (CodeQL go/request-forgery): the host never comes from the caller.
	page func(u *url.URL) (fetch, key string, ok bool)

	hostSet, imageHostSet map[string]bool // derived in init
}

func (s *previewSite) preview() bool { return s.page != nil }

func (s *previewSite) ua() string {
	if s.userAgent != "" {
		return s.userAgent
	}
	return previewUserAgent
}

// previewSites is the registry, in the order GET /v2/preview/sites lists it.
var previewSites = []*previewSite{
	{
		id: "x", name: "X",
		hosts:      []string{"x.com", "www.x.com", "mobile.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"},
		imageHosts: []string{"pbs.twimg.com", "abs.twimg.com"},
		page:       xPage,
	},
	{
		id: "youtube", name: "YouTube",
		hosts:      []string{"youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"},
		imageHosts: []string{"i.ytimg.com"},
		page:       youtubePage,
	},
	{
		id: "naver-news", name: "네이버 뉴스",
		hosts:      []string{"n.news.naver.com", "news.naver.com", "m.news.naver.com"},
		imageHosts: []string{"imgnews.pstatic.net"},
		page:       naverNewsPage,
	},
	{
		id: "wikipedia", name: "위키백과",
		hosts:      []string{"ko.wikipedia.org", "en.wikipedia.org", "ko.m.wikipedia.org", "en.m.wikipedia.org"},
		imageHosts: []string{"thumb.wikimedia.org", "upload.wikimedia.org"},
		page:       wikipediaPage,
	},
	{
		id: "github", name: "GitHub",
		hosts:      []string{"github.com", "www.github.com"},
		imageHosts: []string{"opengraph.githubassets.com", "repository-images.githubusercontent.com", "avatars.githubusercontent.com"},
		page:       githubPage,
	},
	{
		id: "bbc", name: "BBC",
		hosts:      []string{"bbc.com", "www.bbc.com", "bbc.co.uk", "www.bbc.co.uk"},
		imageHosts: []string{"ichef.bbci.co.uk"},
		page:       bbcPage,
	},
	{
		id: "threads", name: "Threads",
		hosts: []string{"threads.net", "www.threads.net", "threads.com", "www.threads.com"},
	},
	{
		id: "reuters", name: "Reuters",
		hosts: []string{"reuters.com", "www.reuters.com"},
	},
	{
		// 번개장터 새 매물 알림(bunjang-bot)의 상품 링크 — 링크만, 미리보기 없음.
		id: "bunjang", name: "번개장터",
		hosts: []string{"m.bunjang.co.kr", "bunjang.co.kr", "www.bunjang.co.kr"},
	},
}

// Derived from previewSites in init; read-only afterwards.
var (
	// previewSiteByHost maps every registry host (link-only included) to its site.
	previewSiteByHost map[string]*previewSite
	// previewSiteByImageHost maps every preview site's image host to its site.
	previewSiteByImageHost map[string]*previewSite
	// previewPageHosts is the union of the preview sites' page hosts.
	previewPageHosts map[string]bool
	// previewImageHosts is the union of the preview sites' image hosts: the
	// /v2/preview/image allowlist.
	previewImageHosts map[string]bool
	// previewSitesBody is the precomputed GET /v2/preview/sites body.
	previewSitesBody []byte
)

func init() {
	idx, err := indexPreviewSites(previewSites)
	if err != nil {
		panic(err)
	}
	previewSiteByHost, previewSiteByImageHost = idx.byHost, idx.byImageHost
	previewPageHosts, previewImageHosts, previewSitesBody = idx.pageHosts, idx.imageHosts, idx.body
}

// previewIndex is what indexPreviewSites derives from a registry.
type previewIndex struct {
	byHost, byImageHost   map[string]*previewSite
	pageHosts, imageHosts map[string]bool
	body                  []byte
}

// indexPreviewSites checks the registry's shape and builds the lookup maps
// and the sites body. A malformed registry is a programming error.
func indexPreviewSites(sites []*previewSite) (*previewIndex, error) {
	idx := &previewIndex{
		byHost: map[string]*previewSite{}, byImageHost: map[string]*previewSite{},
		pageHosts: map[string]bool{}, imageHosts: map[string]bool{},
	}
	type siteJSON struct {
		ID      string   `json:"id"`
		Name    string   `json:"name"`
		Hosts   []string `json:"hosts"`
		Preview bool     `json:"preview"`
	}
	out := struct {
		Version int        `json:"version"`
		Sites   []siteJSON `json:"sites"`
	}{Version: previewSitesVersion}
	ids := map[string]bool{}
	for _, s := range sites {
		if s.id == "" || s.name == "" || len(s.hosts) == 0 || ids[s.id] {
			return nil, fmt.Errorf("preview registry: bad or duplicate site %q", s.id)
		}
		ids[s.id] = true
		if s.preview() != (len(s.imageHosts) > 0) {
			return nil, fmt.Errorf("preview registry: site %q: image hosts iff preview", s.id)
		}
		s.hostSet, s.imageHostSet = map[string]bool{}, map[string]bool{}
		for _, h := range s.hosts {
			if h != strings.ToLower(h) || idx.byHost[h] != nil {
				return nil, fmt.Errorf("preview registry: bad or duplicate host %q", h)
			}
			idx.byHost[h], s.hostSet[h] = s, true
			if s.preview() {
				idx.pageHosts[h] = true
			}
		}
		for _, h := range s.imageHosts {
			if h != strings.ToLower(h) || idx.byImageHost[h] != nil {
				return nil, fmt.Errorf("preview registry: bad or duplicate image host %q", h)
			}
			idx.byImageHost[h], s.imageHostSet[h], idx.imageHosts[h] = s, true, true
		}
		out.Sites = append(out.Sites, siteJSON{ID: s.id, Name: s.name, Hosts: append([]string(nil), s.hosts...), Preview: s.preview()})
	}
	body, err := json.Marshal(out)
	if err != nil {
		return nil, err
	}
	idx.body = body
	return idx, nil
}

// normalizePreviewURL validates a client-supplied link and maps it to its
// preview site, the canonical page URL to fetch and the page's cache
// identity. Links of link-only sites and links whose path does not follow
// the site's rule are refused.
func normalizePreviewURL(raw string) (site *previewSite, fetch, key string, ok bool) {
	if raw == "" || len(raw) > previewURLMaxBytes {
		return nil, "", "", false
	}
	u, err := url.Parse(raw)
	if err != nil || !allowedHTTPSURL(u, previewPageHosts) {
		return nil, "", "", false
	}
	site = previewSiteByHost[strings.ToLower(u.Host)]
	if site == nil || !site.preview() {
		return nil, "", "", false
	}
	fetch, key, ok = site.page(u)
	if !ok {
		return nil, "", "", false
	}
	return site, fetch, key, true
}

// pathSegments splits u's escaped path after the leading "/"; one trailing
// "/" is ignored. Percent-encoded bytes stay encoded, so they never match
// the plain-character id patterns below.
func pathSegments(u *url.URL) []string {
	seg := strings.Split(strings.TrimPrefix(u.EscapedPath(), "/"), "/")
	if len(seg) > 1 && seg[len(seg)-1] == "" {
		seg = seg[:len(seg)-1]
	}
	return seg
}

var (
	youtubeIDRe  = regexp.MustCompile(`^[A-Za-z0-9_-]{11}$`)
	naverOIDRe   = regexp.MustCompile(`^[0-9]{3}$`)
	naverAIDRe   = regexp.MustCompile(`^[0-9]{10}$`)
	githubNameRe = regexp.MustCompile(`^[A-Za-z0-9._-]{1,100}$`)
	githubNumRe  = regexp.MustCompile(`^[0-9]{1,9}$`)
	bbcArticleRe = regexp.MustCompile(`^[a-z0-9]{8,20}$`)
	wikiTitleRe  = regexp.MustCompile(`^[A-Za-z0-9\-._~!$&'()*+,;=:@/%]{1,300}$`)
)

// xPage is the v1 rule (normalizeXStatusURL): the cache identity is the
// status id, so one post under any handle or host is fetched once.
func xPage(u *url.URL) (fetch, key string, ok bool) {
	canonical, id, ok := xStatus(u)
	if !ok {
		return "", "", false
	}
	return canonical, "https://x.com/i/web/status/" + id, true
}

// youtubePage: youtube.com|www|m /watch?v={id} or /shorts/{id}, youtu.be/{id}
// → https://www.youtube.com/watch?v={id}. Other query parameters are dropped.
func youtubePage(u *url.URL) (fetch, key string, ok bool) {
	seg := pathSegments(u)
	var id string
	switch host := strings.ToLower(u.Host); {
	case host == "youtu.be":
		if len(seg) == 1 {
			id = seg[0]
		}
	case len(seg) == 1 && seg[0] == "watch":
		if v := u.Query()["v"]; len(v) == 1 {
			id = v[0]
		}
	case len(seg) == 2 && seg[0] == "shorts":
		id = seg[1]
	}
	if !youtubeIDRe.MatchString(id) {
		return "", "", false
	}
	c := "https://www.youtube.com/watch?v=" + id
	return c, c, true
}

// naverNewsPage: /article/{oid}/{aid} or /mnews/article/{oid}/{aid} on any
// naver news host → https://n.news.naver.com/article/{oid}/{aid}.
func naverNewsPage(u *url.URL) (fetch, key string, ok bool) {
	seg := pathSegments(u)
	if len(seg) == 4 && seg[0] == "mnews" {
		seg = seg[1:]
	}
	if len(seg) != 3 || seg[0] != "article" || !naverOIDRe.MatchString(seg[1]) || !naverAIDRe.MatchString(seg[2]) {
		return "", "", false
	}
	c := "https://n.news.naver.com/article/" + seg[1] + "/" + seg[2]
	return c, c, true
}

// wikipediaPage: /wiki/{title} on ko|en (desktop or mobile) →
// https://{ko|en}.wikipedia.org/wiki/{title}. The title is kept in its
// escaped form (1–300 bytes), the query is dropped; "." / ".." / empty
// segments (also once unescaped) and malformed escapes are refused.
func wikipediaPage(u *url.URL) (fetch, key string, ok bool) {
	p := u.EscapedPath()
	if !strings.HasPrefix(p, "/wiki/") {
		return "", "", false
	}
	title := strings.TrimPrefix(p, "/wiki/")
	if !wikiTitleRe.MatchString(title) {
		return "", "", false
	}
	plain, err := url.PathUnescape(title)
	if err != nil {
		return "", "", false
	}
	// Dot / empty segments are refused both as written and once unescaped
	// (%2e%2e), so the fetch always names an article under /wiki/.
	for _, form := range []string{title, plain} {
		for _, s := range strings.Split(form, "/") {
			if s == "" || s == "." || s == ".." {
				return "", "", false
			}
		}
	}
	var c string
	switch strings.ToLower(u.Host) {
	case "ko.wikipedia.org", "ko.m.wikipedia.org":
		c = "https://ko.wikipedia.org/wiki/" + title
	case "en.wikipedia.org", "en.m.wikipedia.org":
		c = "https://en.wikipedia.org/wiki/" + title
	default:
		return "", "", false
	}
	return c, c, true
}

// githubPage: /{owner}/{repo} or /{owner}/{repo}/(issues|pull|discussions)/{n}
// → https://github.com/….
func githubPage(u *url.URL) (fetch, key string, ok bool) {
	seg := pathSegments(u)
	if len(seg) != 2 && len(seg) != 4 {
		return "", "", false
	}
	for _, s := range seg[:2] {
		if !githubNameRe.MatchString(s) || s == "." || s == ".." {
			return "", "", false
		}
	}
	c := "https://github.com/" + seg[0] + "/" + seg[1]
	if len(seg) == 4 {
		switch seg[2] {
		case "issues", "pull", "discussions":
		default:
			return "", "", false
		}
		if !githubNumRe.MatchString(seg[3]) {
			return "", "", false
		}
		c = "https://github.com/" + seg[0] + "/" + seg[1] + "/" + seg[2] + "/" + seg[3]
	}
	return c, c, true
}

// bbcPage: /news/articles/{id} on bbc.com|bbc.co.uk (and www) →
// https://www.bbc.com/news/articles/{id}.
func bbcPage(u *url.URL) (fetch, key string, ok bool) {
	seg := pathSegments(u)
	if len(seg) != 3 || seg[0] != "news" || seg[1] != "articles" || !bbcArticleRe.MatchString(seg[2]) {
		return "", "", false
	}
	c := "https://www.bbc.com/news/articles/" + seg[2]
	return c, c, true
}

// previewCacheKey is the cache / singleflight key: site id + page identity.
func previewCacheKey(site *previewSite, key string) string {
	return site.id + "\x00" + key
}

// pageRedirectHosts: a page fetch may only be redirected within the hosts
// of the site whose page was requested.
func pageRedirectHosts(firstHost string) map[string]bool {
	if s := previewSiteByHost[firstHost]; s != nil && s.preview() {
		return s.hostSet
	}
	return nil
}

// imageRedirectHosts: an image fetch may only be redirected within the image
// hosts of the site that owns the requested image host.
func imageRedirectHosts(firstHost string) map[string]bool {
	if s := previewSiteByImageHost[firstHost]; s != nil {
		return s.imageHostSet
	}
	return nil
}

// handlePreviewSites answers GET /v2/preview/sites with the registry.
func (s *relay) handlePreviewSites(w http.ResponseWriter, req *http.Request) {
	h := w.Header()
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Cache-Control", "no-store")
	if _, ok := s.authenticate(w, req); !ok {
		return
	}
	h.Set("Content-Type", "application/json; charset=utf-8")
	h.Set("Cache-Control", "private, max-age=3600")
	w.WriteHeader(http.StatusOK)
	if _, err := w.Write(previewSitesBody); err != nil {
		log.Printf("write response: %v", err)
	}
}
