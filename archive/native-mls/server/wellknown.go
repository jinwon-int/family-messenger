package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

// Server discovery for public clients (#584): `GET /.well-known/hande` tells an
// app that only knows a domain where this server's relay lives — the Matrix
// `.well-known/matrix/client` idea. The app tries `https://<input>/.well-known/hande`,
// then `https://hande.<input>/…`, then falls back to the input as the relay base
// URL itself. The route is unauthenticated and cacheable; it exists only when
// the operator states the relay's PUBLIC base URL (`-well-known-public-url`),
// because guessing it from the request Host would let a proxy misconfiguration
// advertise a wrong address. It is served on every host the relay answers for
// (the API host and the hande web host alike) — on the hande host the path is
// routed to the API before file serving, so no static file can shadow it.
//
//	{"version":1,
//	 "relay":{"base_url":"https://relay.example","app_login":"/v2/app-login"},
//	 "hande":{"web_url":"https://hande.example"},        (only with -hande-host)
//	 "name":"서윤 가족",                                   (-well-known-name, optional)
//	 "min_app":{"ios":"0.1.0","android":"0.1.0"}}        (optional, each)

const wellKnownPath = "/.well-known/hande"

type wellKnownRelay struct {
	BaseURL  string `json:"base_url"`
	AppLogin string `json:"app_login"`
}

type wellKnownHande struct {
	WebURL string `json:"web_url"`
}

type wellKnownMinApp struct {
	IOS     string `json:"ios,omitempty"`
	Android string `json:"android,omitempty"`
}

type wellKnownDoc struct {
	Version int              `json:"version"`
	Relay   wellKnownRelay   `json:"relay"`
	Hande   *wellKnownHande  `json:"hande,omitempty"`
	Name    string           `json:"name,omitempty"`
	MinApp  *wellKnownMinApp `json:"min_app,omitempty"`
}

var semverLoose = regexp.MustCompile(`^[0-9]+(\.[0-9]+){0,2}$`)

// publicBaseURL validates an operator-stated public base URL: https (http only
// for localhost), host present, no query/fragment/userinfo, and a path that is
// either empty or a clean prefix without a trailing slash.
func publicBaseURL(raw string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Host == "" {
		return "", errors.New("must be an absolute URL with a host")
	}
	host := strings.ToLower(u.Hostname())
	switch {
	case u.Scheme == "https":
	case u.Scheme == "http" && (host == "localhost" || host == "127.0.0.1"):
	default:
		return "", errors.New("must use https (http only for localhost)")
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("must not carry userinfo, query or fragment")
	}
	p := strings.TrimSuffix(u.Path, "/")
	if p != "" && (!strings.HasPrefix(p, "/") || strings.Contains(p, "//") || strings.Contains(p, "..")) {
		return "", errors.New("path must be a clean prefix")
	}
	u.Path, u.RawPath = p, ""
	u.Host = strings.ToLower(u.Host)
	return u.String(), nil
}

// newWellKnownDoc builds the document from the flags; an empty publicURL
// disables the route (nil doc).
func newWellKnownDoc(publicURL, name, handeHost, minIOS, minAndroid string) (*wellKnownDoc, error) {
	if strings.TrimSpace(publicURL) == "" {
		if strings.TrimSpace(name) != "" || strings.TrimSpace(minIOS) != "" || strings.TrimSpace(minAndroid) != "" {
			return nil, errors.New("-well-known-name / -well-known-min-* need -well-known-public-url")
		}
		return nil, nil
	}
	base, err := publicBaseURL(publicURL)
	if err != nil {
		return nil, fmt.Errorf("-well-known-public-url: %w", err)
	}
	doc := &wellKnownDoc{Version: 1, Relay: wellKnownRelay{BaseURL: base, AppLogin: appLoginPath}}
	if name = strings.TrimSpace(name); name != "" {
		if len(name) > 64 || strings.ContainsAny(name, "\r\n\t") {
			return nil, errors.New("-well-known-name: at most 64 characters, no control characters")
		}
		doc.Name = name
	}
	if handeHost != "" {
		doc.Hande = &wellKnownHande{WebURL: "https://" + handeHost}
	}
	for _, v := range []struct{ flag, val string }{{"-well-known-min-ios", minIOS}, {"-well-known-min-android", minAndroid}} {
		if v.val = strings.TrimSpace(v.val); v.val != "" && !semverLoose.MatchString(v.val) {
			return nil, fmt.Errorf("%s: %q is not a version like 0.1.0", v.flag, v.val)
		}
	}
	if minIOS != "" || minAndroid != "" {
		doc.MinApp = &wellKnownMinApp{IOS: strings.TrimSpace(minIOS), Android: strings.TrimSpace(minAndroid)}
	}
	return doc, nil
}

// handleWellKnown answers GET/HEAD with the fixed document: public, cacheable
// for five minutes, readable cross-origin (a web client on another host may
// probe a server before pointing the user at it), never anything else.
func (s *relay) handleWellKnown(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet && req.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		s.fail(w, http.StatusMethodNotAllowed, apiError{Error: "method_not_allowed"})
		return
	}
	body, err := json.Marshal(s.wellKnown)
	if err != nil {
		log.Printf("well-known: encode: %v", err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
		return
	}
	h := w.Header()
	h.Set("Content-Type", "application/json; charset=utf-8")
	h.Set("Cache-Control", "public, max-age=300")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Access-Control-Allow-Origin", "*")
	w.WriteHeader(http.StatusOK)
	if req.Method == http.MethodHead {
		return
	}
	if _, err := w.Write(body); err != nil {
		log.Printf("write response: %v", err)
	}
}
