package main

// App login hand-off (#271 §12-C, option A). The iOS app cannot run the
// Cloudflare Access login inside a web view (the account's only IdP is
// Google, which refuses embedded user agents), so it opens this route in the
// system browser sheet (ASWebAuthenticationSession). The edge performs the
// Access login as usual and injects Cf-Access-Jwt-Assertion; the relay then
// hands that very token back to the app through a FIXED custom-scheme
// redirect. The app sends it as the CF_Authorization cookie afterwards — the
// same token the paste-in flow used, so nothing new is trusted:
//
//   - the token is verified here exactly like on every contract route
//     (signature, iss, aud, exp/nbf, lifetime) before it is echoed;
//   - the redirect target is a constant (appLoginCallback) — no redirect_uri
//     parameter, so the route can never be turned into an open redirect;
//   - `state` is an app-chosen nonce echoed verbatim; the app refuses a
//     callback whose state it did not mint (CSRF / session fixation);
//   - the token travels in the URL *fragment*, which browsers never send to a
//     server and which does not land in access logs;
//   - the route exists only while caller authentication is on; without a
//     verifier there is no edge token to hand back, and the route is 404.
//
// The relay still reads the header only (auth.go bearerToken): a request
// that reaches the origin without the edge gets a bare 401 like any other
// route, so an attacker cannot use this route to mint anything.

import (
	"log"
	"net/http"
	"net/url"
)

const (
	appLoginPath = "/v2/app-login"
	// appLoginCallback is the fixed callback the app registers
	// (ASWebAuthenticationSession callbackURLScheme "hande"). Changing it is a
	// coordinated app + relay change, never a request parameter.
	appLoginCallback = "hande://auth"
	// state is a base64url nonce minted by the app (32 random bytes = 43
	// chars); bounds keep the echo small and the charset URL-safe.
	appLoginStateMin = 16
	appLoginStateMax = 128
)

// validAppLoginState accepts base64url characters only, within bounds.
func validAppLoginState(s string) bool {
	if len(s) < appLoginStateMin || len(s) > appLoginStateMax {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '-', c == '_':
		default:
			return false
		}
	}
	return true
}

// appLoginLocation builds the fixed-scheme callback: <callback>#jwt=…&state=….
func appLoginLocation(token, state string) string {
	frag := url.Values{}
	frag.Set("jwt", token)
	frag.Set("state", state)
	return appLoginCallback + "#" + frag.Encode()
}

// handleAppLogin answers GET /v2/app-login?state=<nonce> with a 302 to the
// app's fixed callback carrying the verified edge token in the fragment.
func (s *relay) handleAppLogin(w http.ResponseWriter, req *http.Request) {
	// Never cache or leak the response: it carries a session token.
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Content-Type-Options", "nosniff")
	state := req.URL.Query().Get("state")
	if !validAppLoginState(state) {
		s.fail(w, http.StatusBadRequest, apiError{Error: "bad_state", Detail: "state must be 16..128 base64url characters"})
		return
	}
	// Same verification as every contract route; a bare 401 when the edge
	// token is missing or invalid (reason in the log only).
	if _, ok := s.authenticate(w, req); !ok {
		return
	}
	token := bearerToken(req)
	log.Printf("app-login %s: ok", req.URL.Path)
	// Not http.Redirect: it writes an HTML body that repeats the Location
	// (token included). Header only, empty body.
	h.Set("Location", appLoginLocation(token, state))
	w.WriteHeader(http.StatusFound)
}
