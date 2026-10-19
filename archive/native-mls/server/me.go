package main

// Caller identity echo (#431 stage 1). The hande web app has no JWT of its
// own to read: the edge keeps the Access session in a cookie and injects
// Cf-Access-Jwt-Assertion on every same-origin /v2/* call, so the browser
// never sees the token's claims. GET /v2/me verifies that assertion exactly
// like every contract route and answers the verified subject, which the app
// writes into the `subject` field of its device registration JSON (iOS fills
// the same field from its own copy of the JWT). Nothing is stored and nothing
// else is revealed. Like app-login the route exists only while caller
// authentication is on; without a verifier there is no subject, so it is 404.

import (
	"encoding/json"
	"log"
	"net/http"
)

const mePath = "/v2/me"

type meResponse struct {
	Subject string `json:"subject"`
}

// handleMe answers GET /v2/me with {"subject": <verified sub>}.
func (s *relay) handleMe(w http.ResponseWriter, req *http.Request) {
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	body, err := json.Marshal(meResponse{Subject: c.subject})
	if err != nil {
		log.Printf("me: encode: %v", err)
		s.fail(w, http.StatusInternalServerError, apiError{Error: "internal"})
		return
	}
	h.Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	if _, err := w.Write(body); err != nil {
		log.Printf("write response: %v", err)
	}
}
