// x.com link preview proxy (#683 phase 2, contract "2단계 API 계약 v1").
// Clients never fetch x.com themselves: with -link-preview the relay answers
//
//	GET /v2/preview?url=<x.com status URL>  → {"url","site":"X","title","description","image"}
//	GET /v2/preview/image?u=<pbs|abs.twimg.com URL> → the image bytes
//
// both behind the same caller authentication as every other route. The
// fetcher only ever contacts a fixed allowlist of hosts over https (x.com
// family for pages, pbs/abs.twimg.com for images), re-checks every redirect
// against the same allowlist, refuses to dial non-public addresses, caps
// bodies and time, sends no client cookie or Authorization upstream, runs at
// most previewConcurrency upstream requests at once and keeps a bounded
// memory-only cache keyed by status id. Logs carry status, host and duration
// only — never a URL path or a status id, so the relay keeps no record of
// which posts the family looked at.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"html"
	"io"
	"log"
	"mime"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

const (
	previewPath      = "/v2/preview"
	previewImagePath = "/v2/preview/image"

	previewTimeout       = 5 * time.Second
	previewMaxRedirects  = 3
	previewPageMaxBytes  = 512 << 10
	previewImageMaxBytes = 2 << 20
	previewFieldMaxRunes = 2000
	previewURLMaxBytes   = 2048
	previewConcurrency   = 4
	previewCacheMax      = 512
	previewCacheOK       = 6 * time.Hour
	previewCacheFail     = 10 * time.Minute
	previewUserAgent     = "Twitterbot/1.0"
)

// previewPageHosts are the only hosts a status URL may name and the only
// hosts a page redirect may lead to.
var previewPageHosts = map[string]bool{
	"x.com": true, "www.x.com": true, "mobile.x.com": true,
	"twitter.com": true, "www.twitter.com": true, "mobile.twitter.com": true,
}

// previewImageHosts are the only hosts an og:image (and its redirects) may use.
var previewImageHosts = map[string]bool{"pbs.twimg.com": true, "abs.twimg.com": true}

// previewImageTypes is the response Content-Type allowlist for images.
var previewImageTypes = map[string]bool{"image/jpeg": true, "image/png": true, "image/webp": true, "image/gif": true}

var (
	xHandleRe = regexp.MustCompile(`^[A-Za-z0-9_]{1,15}$`)
	xIDRe     = regexp.MustCompile(`^[0-9]{1,25}$`)
	// metaTagRe matches one <meta …> tag; quoted attribute values may hold '>'.
	metaTagRe = regexp.MustCompile(`(?is)<meta\b((?:[^>"']|"[^"]*"|'[^']*')*)>`)
	// metaAttrRe matches name=value with a double-, single- or un-quoted value.
	metaAttrRe = regexp.MustCompile(`(?s)([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'<>` + "`" + `]+))`)
)

// allowedHTTPSURL reports whether u is an https URL with no userinfo and no
// explicit port whose (lower-cased) host is in hosts.
func allowedHTTPSURL(u *url.URL, hosts map[string]bool) bool {
	return u != nil && u.Scheme == "https" && u.Opaque == "" && u.User == nil &&
		!strings.Contains(u.Host, ":") && hosts[strings.ToLower(u.Host)]
}

// normalizeXStatusURL validates a client-supplied x.com/twitter.com status
// link and returns its canonical form (https://x.com/{handle}/status/{id} or
// https://x.com/i/web/status/{id}) plus the id (the cache key). Anything
// after the id, the query and the fragment are dropped; percent-encoded
// segments never match.
func normalizeXStatusURL(raw string) (canonical, id string, ok bool) {
	if raw == "" || len(raw) > previewURLMaxBytes {
		return "", "", false
	}
	u, err := url.Parse(raw)
	if err != nil || !allowedHTTPSURL(u, previewPageHosts) {
		return "", "", false
	}
	seg := strings.Split(strings.TrimPrefix(u.EscapedPath(), "/"), "/")
	switch {
	case len(seg) >= 4 && seg[0] == "i" && seg[1] == "web" && seg[2] == "status" && xIDRe.MatchString(seg[3]):
		return "https://x.com/i/web/status/" + seg[3], seg[3], true
	case len(seg) >= 3 && xHandleRe.MatchString(seg[0]) && seg[1] == "status" && xIDRe.MatchString(seg[2]):
		return "https://x.com/" + seg[0] + "/status/" + seg[2], seg[2], true
	}
	return "", "", false
}

// normalizeImageURL validates an image URL (og:image or the client's ?u=)
// against the image host allowlist and returns it re-serialized.
func normalizeImageURL(raw string) (string, bool) {
	if raw == "" || len(raw) > previewURLMaxBytes {
		return "", false
	}
	u, err := url.Parse(raw)
	if err != nil || !allowedHTTPSURL(u, previewImageHosts) {
		return "", false
	}
	u.Host = strings.ToLower(u.Host)
	u.Fragment, u.RawFragment = "", ""
	return u.String(), true
}

// ogMeta is what a page told us about itself.
type ogMeta struct {
	Title, Description, Image string
}

// parseOGMeta scans html for <meta property|name="og:…" content="…"> tags.
// Attribute order and quoting are free, names are case-insensitive, the
// first non-empty value per field wins, entities are decoded and each value
// is capped at previewFieldMaxRunes.
func parseOGMeta(page []byte) ogMeta {
	var m ogMeta
	for _, tag := range metaTagRe.FindAllSubmatch(page, -1) {
		var key, content string
		haveContent := false
		for _, a := range metaAttrRe.FindAllSubmatch(tag[1], -1) {
			val := string(a[2]) + string(a[3]) + string(a[4]) // exactly one alternative matched
			switch strings.ToLower(string(a[1])) {
			case "property", "name":
				if key == "" {
					key = strings.ToLower(strings.TrimSpace(val))
				}
			case "content":
				if !haveContent {
					content, haveContent = val, true
				}
			}
		}
		if !haveContent {
			continue
		}
		var dst *string
		switch key {
		case "og:title":
			dst = &m.Title
		case "og:description":
			dst = &m.Description
		case "og:image":
			dst = &m.Image
		default:
			continue
		}
		if *dst == "" {
			*dst = cleanOGValue(content)
		}
	}
	return m
}

// cleanOGValue decodes HTML entities, forces valid UTF-8, trims and caps the
// value at previewFieldMaxRunes runes.
func cleanOGValue(v string) string {
	v = strings.TrimSpace(strings.ToValidUTF8(html.UnescapeString(v), "�"))
	if utf8.RuneCountInString(v) <= previewFieldMaxRunes {
		return v
	}
	n := 0
	for i := range v {
		if n == previewFieldMaxRunes {
			return v[:i]
		}
		n++
	}
	return v
}

// previewResult is one cached outcome for a status id. status is 200, 404
// (no_preview) or 502 (upstream_failed); image is the relay-relative image
// path or "".
type previewResult struct {
	status             int
	title, description string
	image              string
}

type previewEntry struct {
	res     previewResult
	expires time.Time
	seq     uint64 // insertion order: the smallest is evicted first
}

type previewCall struct {
	done chan struct{}
	res  previewResult
}

// linkPreviewer is the fetcher + cache behind both routes. Its own mutex is
// never taken under relay.mu.
type linkPreviewer struct {
	pageClient  *http.Client
	imageClient *http.Client
	sem         chan struct{}
	now         func() time.Time

	mu       sync.Mutex
	cache    map[string]*previewEntry
	inflight map[string]*previewCall
	seq      uint64
}

// newLinkPreviewer builds the previewer over rt; nil means the production
// transport (no proxy, public addresses only, TLS ≥ 1.2). Tests inject a
// RoundTripper so nothing touches the network.
func newLinkPreviewer(rt http.RoundTripper) *linkPreviewer {
	if rt == nil {
		rt = defaultPreviewTransport()
	}
	return &linkPreviewer{
		pageClient:  previewClient(rt, previewPageHosts),
		imageClient: previewClient(rt, previewImageHosts),
		sem:         make(chan struct{}, previewConcurrency),
		now:         time.Now,
		cache:       map[string]*previewEntry{},
		inflight:    map[string]*previewCall{},
	}
}

// previewClient: no cookie jar, overall timeout, redirects only to https
// hosts in the same allowlist and at most previewMaxRedirects of them.
func previewClient(rt http.RoundTripper, hosts map[string]bool) *http.Client {
	return &http.Client{
		Transport: rt,
		Timeout:   previewTimeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) > previewMaxRedirects {
				return errPreviewRedirect
			}
			if !allowedHTTPSURL(req.URL, hosts) {
				return errPreviewRedirect
			}
			// Nothing but our own fixed headers ever travels upstream.
			req.Header.Del("Cookie")
			req.Header.Del("Authorization")
			return nil
		},
	}
}

var errPreviewRedirect = errors.New("preview: redirect refused")

func defaultPreviewTransport() http.RoundTripper {
	d := &net.Dialer{Timeout: previewTimeout, Control: previewDialControl}
	return &http.Transport{
		Proxy:                 nil,
		DialContext:           d.DialContext,
		ForceAttemptHTTP2:     true,
		TLSHandshakeTimeout:   previewTimeout,
		ResponseHeaderTimeout: previewTimeout,
		MaxIdleConns:          8,
		IdleConnTimeout:       90 * time.Second,
	}
}

// previewNonPublic are ranges the fetcher must never dial even if DNS for an
// allowlisted name pointed there (CGNAT covers the tailnet).
var previewNonPublic = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("240.0.0.0/4"),
	netip.MustParsePrefix("64:ff9b::/96"),
	netip.MustParsePrefix("2001:db8::/32"),
}

// previewDialControl refuses loopback, private, link-local, multicast,
// unspecified and the special ranges above (defence in depth behind the host
// allowlist: an allowlisted name resolving inward is not followed).
func previewDialControl(_, address string, _ syscall.RawConn) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return errors.New("preview: dial target is not an IP")
	}
	ip = ip.Unmap()
	if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsInterfaceLocalMulticast() || ip.IsMulticast() || ip.IsUnspecified() {
		return errors.New("preview: non-public address refused")
	}
	for _, p := range previewNonPublic {
		if p.Contains(ip) {
			return errors.New("preview: non-public address refused")
		}
	}
	return nil
}

// acquire takes an upstream slot, waiting at most previewTimeout.
func (p *linkPreviewer) acquire(ctx context.Context) bool {
	t := time.NewTimer(previewTimeout)
	defer t.Stop()
	select {
	case p.sem <- struct{}{}:
		return true
	case <-ctx.Done():
		return false
	case <-t.C:
		return false
	}
}

func (p *linkPreviewer) release() { <-p.sem }

// preview returns the (possibly cached) result for one status. Concurrent
// callers for the same id share one upstream fetch.
func (p *linkPreviewer) preview(ctx context.Context, canonical, id string) previewResult {
	p.mu.Lock()
	if e, ok := p.cache[id]; ok {
		if p.now().Before(e.expires) {
			p.mu.Unlock()
			return e.res
		}
		delete(p.cache, id)
	}
	if c, ok := p.inflight[id]; ok {
		p.mu.Unlock()
		select {
		case <-c.done:
			return c.res
		case <-ctx.Done():
			return previewResult{status: http.StatusBadGateway}
		}
	}
	c := &previewCall{done: make(chan struct{})}
	p.inflight[id] = c
	p.mu.Unlock()

	res, cacheable := p.fetchPage(ctx, canonical)

	p.mu.Lock()
	delete(p.inflight, id)
	if cacheable {
		p.storeLocked(id, res)
	}
	p.mu.Unlock()
	c.res = res
	close(c.done)
	return res
}

// storeLocked caches res under id (success 6 h, anything else 10 min); when
// full it drops expired entries first, then the oldest. p.mu must be held.
func (p *linkPreviewer) storeLocked(id string, res previewResult) {
	now := p.now()
	ttl := previewCacheFail
	if res.status == http.StatusOK {
		ttl = previewCacheOK
	}
	if _, ok := p.cache[id]; !ok && len(p.cache) >= previewCacheMax {
		for k, e := range p.cache {
			if !now.Before(e.expires) {
				delete(p.cache, k)
			}
		}
		for len(p.cache) >= previewCacheMax {
			var oldest string
			var min uint64
			first := true
			for k, e := range p.cache {
				if first || e.seq < min {
					oldest, min, first = k, e.seq, false
				}
			}
			delete(p.cache, oldest)
		}
	}
	p.seq++
	p.cache[id] = &previewEntry{res: res, expires: now.Add(ttl), seq: p.seq}
}

// fetchPage fetches canonical and extracts the og fields. The second result
// is false for local refusals (no upstream slot) that must not be cached.
func (p *linkPreviewer) fetchPage(ctx context.Context, canonical string) (previewResult, bool) {
	if !p.acquire(ctx) {
		log.Printf("preview: page busy (no upstream slot)")
		return previewResult{status: http.StatusBadGateway}, false
	}
	defer p.release()
	// The upstream fetch outlives a caller that went away: others may be
	// waiting on the same id. The client timeout still bounds it.
	req, err := http.NewRequestWithContext(context.WithoutCancel(ctx), http.MethodGet, canonical, nil)
	if err != nil {
		return previewResult{status: http.StatusBadGateway}, true
	}
	req.Header.Set("User-Agent", previewUserAgent)
	req.Header.Set("Accept", "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1")
	start := time.Now()
	resp, err := p.pageClient.Do(req)
	if err != nil {
		log.Printf("preview: page upstream error=%s dur=%s", previewErrClass(err), time.Since(start).Round(time.Millisecond))
		return previewResult{status: http.StatusBadGateway}, true
	}
	defer resp.Body.Close()
	host := resp.Request.URL.Hostname()
	if resp.StatusCode != http.StatusOK {
		log.Printf("preview: page upstream host=%s status=%d dur=%s", host, resp.StatusCode, time.Since(start).Round(time.Millisecond))
		return previewResult{status: http.StatusBadGateway}, true
	}
	// og tags live in <head>; a longer page is parsed up to the cap.
	body, err := io.ReadAll(io.LimitReader(resp.Body, previewPageMaxBytes))
	if err != nil {
		log.Printf("preview: page upstream host=%s read error=%s dur=%s", host, previewErrClass(err), time.Since(start).Round(time.Millisecond))
		return previewResult{status: http.StatusBadGateway}, true
	}
	log.Printf("preview: page upstream host=%s status=%d dur=%s", host, resp.StatusCode, time.Since(start).Round(time.Millisecond))
	og := parseOGMeta(body)
	if og.Title == "" && og.Description == "" {
		return previewResult{status: http.StatusNotFound}, true
	}
	res := previewResult{status: http.StatusOK, title: og.Title, description: og.Description}
	if img, ok := normalizeImageURL(og.Image); ok {
		res.image = previewImagePath + "?u=" + url.QueryEscape(img)
	}
	return res, true
}

// previewErrClass turns a client error into a word for the log. *url.Error
// carries the URL, which must never reach the log.
func previewErrClass(err error) string {
	var ne net.Error
	switch {
	case errors.Is(err, errPreviewRedirect):
		return "redirect_refused"
	case errors.Is(err, context.DeadlineExceeded), errors.As(err, &ne) && ne.Timeout():
		return "timeout"
	default:
		return "transport"
	}
}

// fetchImage fetches an allowlisted image: 200, an allowed Content-Type and
// at most previewImageMaxBytes, else ok=false.
func (p *linkPreviewer) fetchImage(ctx context.Context, src string) (body []byte, ctype string, ok bool) {
	if !p.acquire(ctx) {
		log.Printf("preview: image busy (no upstream slot)")
		return nil, "", false
	}
	defer p.release()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, src, nil)
	if err != nil {
		return nil, "", false
	}
	req.Header.Set("User-Agent", previewUserAgent)
	req.Header.Set("Accept", "image/webp,image/png,image/jpeg,image/gif;q=0.9")
	start := time.Now()
	resp, err := p.imageClient.Do(req)
	if err != nil {
		log.Printf("preview: image upstream error=%s dur=%s", previewErrClass(err), time.Since(start).Round(time.Millisecond))
		return nil, "", false
	}
	defer resp.Body.Close()
	host := resp.Request.URL.Hostname()
	log.Printf("preview: image upstream host=%s status=%d dur=%s", host, resp.StatusCode, time.Since(start).Round(time.Millisecond))
	if resp.StatusCode != http.StatusOK {
		return nil, "", false
	}
	mt, _, err := mime.ParseMediaType(resp.Header.Get("Content-Type"))
	if err != nil || !previewImageTypes[strings.ToLower(mt)] {
		log.Printf("preview: image upstream host=%s refused content type", host)
		return nil, "", false
	}
	if resp.ContentLength > previewImageMaxBytes {
		log.Printf("preview: image upstream host=%s too large", host)
		return nil, "", false
	}
	body, err = io.ReadAll(io.LimitReader(resp.Body, previewImageMaxBytes+1))
	if err != nil || len(body) > previewImageMaxBytes {
		log.Printf("preview: image upstream host=%s too large or unreadable", host)
		return nil, "", false
	}
	return body, strings.ToLower(mt), true
}

type previewResponse struct {
	URL         string  `json:"url"`
	Site        string  `json:"site"`
	Title       string  `json:"title"`
	Description string  `json:"description"`
	Image       *string `json:"image"`
}

// handlePreview answers GET /v2/preview?url=<x.com status URL>.
func (s *relay) handlePreview(w http.ResponseWriter, req *http.Request) {
	h := w.Header()
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Cache-Control", "no-store")
	if _, ok := s.authenticate(w, req); !ok {
		return
	}
	canonical, id, ok := normalizeXStatusURL(req.URL.Query().Get("url"))
	if !ok {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_url"})
		return
	}
	res := s.preview.preview(req.Context(), canonical, id)
	switch res.status {
	case http.StatusOK:
	case http.StatusNotFound:
		s.fail(w, http.StatusNotFound, apiError{Error: "no_preview"})
		return
	default:
		s.fail(w, http.StatusBadGateway, apiError{Error: "upstream_failed"})
		return
	}
	out := previewResponse{URL: canonical, Site: "X", Title: res.title, Description: res.description}
	if res.image != "" {
		img := res.image
		out.Image = &img
	}
	body, err := json.Marshal(out)
	if err != nil {
		log.Printf("preview: encode: %v", err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
		return
	}
	h.Set("Content-Type", "application/json; charset=utf-8")
	h.Set("Cache-Control", "private, max-age=3600")
	w.WriteHeader(http.StatusOK)
	if _, err := w.Write(body); err != nil {
		log.Printf("write response: %v", err)
	}
}

// handlePreviewImage answers GET /v2/preview/image?u=<pbs|abs.twimg.com URL>.
func (s *relay) handlePreviewImage(w http.ResponseWriter, req *http.Request) {
	h := w.Header()
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Cache-Control", "no-store")
	if _, ok := s.authenticate(w, req); !ok {
		return
	}
	src, ok := normalizeImageURL(req.URL.Query().Get("u"))
	if !ok {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_url"})
		return
	}
	body, ctype, ok := s.preview.fetchImage(req.Context(), src)
	if !ok {
		s.fail(w, http.StatusBadGateway, apiError{Error: "upstream_failed"})
		return
	}
	h.Set("Content-Type", ctype)
	h.Set("Cache-Control", "private, max-age=86400")
	h.Set("Content-Security-Policy", "default-src 'none'; sandbox")
	w.WriteHeader(http.StatusOK)
	if req.Method == http.MethodHead {
		return
	}
	if _, err := w.Write(body); err != nil {
		log.Printf("write response: %v", err)
	}
}
