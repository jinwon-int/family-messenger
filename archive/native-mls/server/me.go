package main

// Caller identity echo (#431 stage 1). The hande web app has no JWT of its
// own to read: the edge keeps the Access session in a cookie and injects
// Cf-Access-Jwt-Assertion on every same-origin /v2/* call, so the browser
// never sees the token's claims. GET /v2/me verifies that assertion exactly
// like every contract route and answers the verified subject, which the app
// writes into the `subject` field of its device registration JSON (iOS fills
// the same field from its own copy of the JWT). Like app-login the route
// exists only while caller authentication is on; without a verifier there is
// no subject, so it is 404.
//
// With a device store (#574) the answer also carries the chain's current
// `policy_revision` — the base_revision an approver signs against — and
// `devices`: every chain record bound to this subject (active and revoked,
// never a signing key), so a client can show "my devices", know whether it
// is a registrar, and tell a first device (nothing yet) from a new one.
// Without a store the body stays exactly {"subject": …}.

import (
	"encoding/json"
	"log"
	"net/http"
)

const mePath = "/v2/me"

type meDevice struct {
	DeviceID    string   `json:"device_id"`
	Actor       string   `json:"actor"`
	Fingerprint string   `json:"fingerprint"`
	Status      string   `json:"status"`
	Acceptance  string   `json:"acceptance"`
	Roles       []string `json:"roles"`
}

type meResponse struct {
	Subject        string     `json:"subject"`
	PolicyRevision *uint64    `json:"policy_revision,omitempty"`
	Devices        []meDevice `json:"devices,omitempty"`
}

// handleMe answers GET /v2/me with {"subject": <verified sub>[, policy_revision, devices]}.
func (s *relay) handleMe(w http.ResponseWriter, req *http.Request) {
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	c, ok := s.authenticate(w, req)
	if !ok {
		return
	}
	resp := meResponse{Subject: c.subject}
	if s.devices != nil {
		info, wire, err := s.devices.Read()
		if err != nil {
			log.Printf("me: read policy: %v", err)
			s.fail(w, http.StatusInternalServerError, apiError{Error: "device_policy_unavailable", Detail: "device policy chain unreadable; writes fail closed"})
			return
		}
		rev := info.Revision
		resp.PolicyRevision = &rev
		resp.Devices = []meDevice{}
		for _, d := range wire.Devices {
			if d.Subject != c.subject {
				continue
			}
			roles := d.Roles
			if roles == nil {
				roles = []string{}
			}
			resp.Devices = append(resp.Devices, meDevice{DeviceID: d.ID, Actor: d.Actor, Fingerprint: d.Fingerprint, Status: d.Status, Acceptance: d.Acceptance, Roles: roles})
		}
	}
	body, err := json.Marshal(resp)
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
