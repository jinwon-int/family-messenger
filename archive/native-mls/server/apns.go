package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

// APNs sender (#275 L2 ②, CONTRACTS §2.3): token-based provider auth with an
// Apple .p8 key (ES256 JWT, kid = key id, iss = team id), HTTP/2 to
// /3/device/<hex token>. Standard library only — no new module dependency.
// The key, team id and key id come from flags; the key file lives outside the
// repository and must not be group/world readable (same rule as -device-state).

const (
	apnsDefaultHost = "https://api.push.apple.com"
	// Apple refuses provider tokens older than one hour and throttles ones
	// refreshed more often than every 20 minutes; 50 minutes sits inside both.
	apnsTokenLifetime = 50 * time.Minute
	apnsSendTimeout   = 10 * time.Second
	apnsMaxReplyBytes = 4 << 10
)

type apnsSender struct {
	client *http.Client
	host   string
	teamID string
	keyID  string
	key    *ecdsa.PrivateKey
	now    func() time.Time

	mu     sync.Mutex
	token  string
	issued time.Time
}

// loadAPNsKey reads an Apple .p8 key: PEM "PRIVATE KEY" holding PKCS#8 P-256.
func loadAPNsKey(path string) (*ecdsa.PrivateKey, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("apns key: %w", err)
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("apns key: not a regular file")
	}
	if info.Mode().Perm()&0o077 != 0 {
		return nil, fmt.Errorf("apns key: mode %04o is group/world accessible; chmod 600", info.Mode().Perm())
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("apns key: %w", err)
	}
	return parseAPNsKey(raw)
}

func parseAPNsKey(raw []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(raw)
	if block == nil || block.Type != "PRIVATE KEY" {
		return nil, errors.New("apns key: expected a PEM PRIVATE KEY (.p8)")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("apns key: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, errors.New("apns key: expected an ECDSA P-256 key")
	}
	return key, nil
}

func validAPNsHost(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host == "" || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.User != nil {
		return fmt.Errorf("apns host %q: want https://host[:port]", raw)
	}
	return nil
}

func newAPNsSender(host, teamID, keyID string, key *ecdsa.PrivateKey, client *http.Client) (*apnsSender, error) {
	if err := validAPNsHost(host); err != nil {
		return nil, err
	}
	if !validAPNsID(teamID) || !validAPNsID(keyID) {
		return nil, errors.New("apns: -apns-team-id and -apns-key-id must be 10 uppercase letters/digits")
	}
	if client == nil {
		client = &http.Client{
			Timeout: apnsSendTimeout,
			Transport: &http.Transport{
				ForceAttemptHTTP2:   true,
				TLSHandshakeTimeout: apnsSendTimeout,
				MaxIdleConns:        4,
				IdleConnTimeout:     5 * time.Minute,
			},
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		}
	}
	return &apnsSender{client: client, host: strings.TrimSuffix(host, "/"), teamID: teamID, keyID: keyID, key: key, now: time.Now}, nil
}

// validAPNsID: Apple team ids and key ids are 10 characters [A-Z0-9].
func validAPNsID(s string) bool {
	if len(s) != 10 {
		return false
	}
	for _, r := range s {
		if (r < 'A' || r > 'Z') && (r < '0' || r > '9') {
			return false
		}
	}
	return true
}

func apnsB64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// providerToken returns the cached ES256 JWT, minting a new one when it is
// older than apnsTokenLifetime or was invalidated by an ExpiredProviderToken.
func (a *apnsSender) providerToken() (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := a.now()
	if a.token != "" && now.Sub(a.issued) < apnsTokenLifetime {
		return a.token, nil
	}
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": a.keyID})
	claims, _ := json.Marshal(map[string]any{"iss": a.teamID, "iat": now.Unix()})
	signing := apnsB64(header) + "." + apnsB64(claims)
	digest := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, a.key, digest[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	a.token, a.issued = signing+"."+apnsB64(sig), now
	return a.token, nil
}

func (a *apnsSender) invalidateToken() {
	a.mu.Lock()
	a.token = ""
	a.mu.Unlock()
}

// apnsResult is one delivery attempt: HTTP status and Apple's reason string
// (empty on 200). err is a transport failure (no status).
type apnsResult struct {
	status int
	reason string
	err    error
}

// gone reports whether Apple says the token will never work again: 410
// Unregistered, or 400 BadDeviceToken / DeviceTokenNotForTopic.
func (r apnsResult) gone() bool {
	if r.status == http.StatusGone {
		return true
	}
	return r.status == http.StatusBadRequest && (r.reason == "BadDeviceToken" || r.reason == "DeviceTokenNotForTopic")
}

// send posts one alert push. The body never carries plaintext, ciphertext or
// the sender — only the room and seq the device should fetch (§2.3).
func (a *apnsSender) send(ctx context.Context, token []byte, topic string, payload []byte) apnsResult {
	jwt, err := a.providerToken()
	if err != nil {
		return apnsResult{err: err}
	}
	ctx, cancel := context.WithTimeout(ctx, apnsSendTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.host+"/3/device/"+hex.EncodeToString(token), bytes.NewReader(payload))
	if err != nil {
		return apnsResult{err: err}
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", topic)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")
	req.Header.Set("content-type", "application/json")
	resp, err := a.client.Do(req)
	if err != nil {
		return apnsResult{err: err}
	}
	defer resp.Body.Close()
	res := apnsResult{status: resp.StatusCode}
	if resp.StatusCode != http.StatusOK {
		var reply struct {
			Reason string `json:"reason"`
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, apnsMaxReplyBytes))
		if json.Unmarshal(body, &reply) == nil {
			res.reason = reply.Reason
		}
		if resp.StatusCode == http.StatusForbidden && (res.reason == "ExpiredProviderToken" || res.reason == "InvalidProviderToken") {
			a.invalidateToken()
		}
	} else {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, apnsMaxReplyBytes))
	}
	return res
}

// pushPayload is the §2.3 body, keys in this exact order:
// {"aps":{"mutable-content":1,"alert":{"loc-key":"NEW_MESSAGE"},"thread-id":"<room>"},"room":"<room>","seq":N}
type pushPayload struct {
	APS  pushAPS `json:"aps"`
	Room string  `json:"room"`
	Seq  int64   `json:"seq"`
}

type pushAPS struct {
	MutableContent int       `json:"mutable-content"`
	Alert          pushAlert `json:"alert"`
	ThreadID       string    `json:"thread-id"`
}

type pushAlert struct {
	LocKey string `json:"loc-key"`
}

func newPushPayload(room string, seq int64) []byte {
	b, _ := json.Marshal(pushPayload{APS: pushAPS{MutableContent: 1, Alert: pushAlert{LocKey: "NEW_MESSAGE"}, ThreadID: room}, Room: room, Seq: seq})
	return b
}
