// Device policy v4 for the native E2EE track (#177 §3.1/§3.2). One file-based,
// signed-by-convention revision chain per relay data directory:
//
//	policy-%06d.json  — immutable record {revision, previous_sha256, policy_sha256, policy}
//	lock              — zero-size flock anchor, same conventions as the v1 auth policy
//
// v4 differs from the operational v1 device list in exactly the #177 §3.1 ways:
// the one-device-per-actor constraint is lifted (≤4 active per actor, ≤32 total,
// IDs and signing keys still globally unique) and an `approved_by` evidence object
// may be written once per device (at trusted-device enrollment, or at a
// device-signed revocation). Old binaries reject v4 structurally: the operational
// strict decoder does not allow `approved_by`/`trusted-device-fingerprint`, and its
// `config()` accepts versions 1–3 only (test in server/internal/access/policy_test.go).
//
// Storage conventions (0700 dir, 0600 single-link O_NOFOLLOW files, cross-process
// flock, fsync before rename, append-only sha256 chain over raw file bytes) mirror
// server/internal/access/policy.go. The native module deliberately does not import
// the operational module (decision E rule 1: the tracks stay separate).
package devicepolicy

import (
	"bytes"
	"crypto/ed25519"
	crand "crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	DevicePolicyVersion      = 4
	MaxDevicePolicyBytes     = 64 * 1024
	MaxDevicePolicyRevisions = 64
	MaxDevicesTotal          = 32
	MaxActivePerActor        = 4
	// MaxPendingPolicyFiles bounds the leftover staging files (interrupted
	// writeDevicePolicyRevision writes) a read tolerates before the
	// directory itself counts as corrupt (G-M7).
	MaxPendingPolicyFiles = 16

	AcceptanceOutOfBand = "out-of-band-fingerprint"    // E1 enroll-first (owner CLI, out-of-band ceremony)
	AcceptanceTrusted   = "trusted-device-fingerprint" // E2 add-device (same-actor active trusted device)

	StatusActive  = "active"
	StatusRevoked = "revoked"

	ApprovalActionAdd    = "approve-device"
	ApprovalActionRevoke = "revoke-device"
	approvalDomainPrefix = "family-mls-v2/"
)

var (
	ErrDevicePolicyState    = errors.New("native device policy unavailable; preserve state for inspection")
	ErrDevicePolicyConflict = errors.New("native device policy revision conflict")
	ErrDevicePolicyConfig   = errors.New("invalid native device policy")
	ErrDevicePolicyApproval = errors.New("device approval evidence rejected")
)

// DeviceApproval is the durable authorizing evidence written at most once per
// device: approver device plus the exact policy revision the approval authorizes
// (the revision that enrolled or revoked the device). A management declaration,
// not cryptographic proof that a human compared fingerprints (server/DEVICES.md).
type DeviceApproval struct {
	DeviceID string `json:"device_id"`
	Revision uint64 `json:"revision"`
}

// DeviceV4 is one public device record. ID, actor, subject, key, fingerprint,
// acceptance and approved_by are immutable once written; the only state change
// is active/1 → revoked/2 (never deleted, never reactivated, IDs never reused).
type DeviceV4 struct {
	ID          string          `json:"device_id"`
	Actor       string          `json:"actor"`
	Subject     string          `json:"subject"`
	SigningKey  string          `json:"signing_key"`
	Fingerprint string          `json:"fingerprint"`
	Status      string          `json:"status"`
	Revision    uint64          `json:"device_revision"`
	Acceptance  string          `json:"acceptance"`
	ApprovedBy  *DeviceApproval `json:"approved_by,omitempty"`
}

type PolicyWire4 struct {
	Version int        `json:"version"`
	Devices []DeviceV4 `json:"devices"`
}

type PolicyRecord4 struct {
	Revision     uint64      `json:"revision"`
	Previous     string      `json:"previous_sha256"`
	PolicySHA256 string      `json:"policy_sha256"`
	Policy       PolicyWire4 `json:"policy"`
}

type DevicePolicyInfo struct {
	Revision uint64 `json:"revision"`
	SHA256   string `json:"sha256"`
}

// proposalWire is the canonical approval payload (fixed field order = canonical
// byte encoding; the Rust facade must produce identical bytes). ApprovalMessage
// binds it to the action and the policy revision it authorizes.
type ApprovalPayloadWire struct {
	Action       string `json:"action"`
	DeviceID     string `json:"device_id"`
	Actor        string `json:"actor"`
	Subject      string `json:"subject"`
	SigningKey   string `json:"signing_key"`
	Fingerprint  string `json:"fingerprint"`
	Acceptance   string `json:"acceptance"`
	BaseRevision uint64 `json:"base_revision"`
}

func canonicalApprovalPayload(p ApprovalPayloadWire) ([]byte, error) {
	b, err := json.Marshal(p)
	if err != nil {
		return nil, err
	}
	return b, nil
}

// ApprovalMessage = "family-mls-v2/<action>\0" ‖ sha256(canonical payload) — the
// B6 domain-separated signing input; the signer never signs arbitrary bytes.
func ApprovalMessage(p ApprovalPayloadWire) ([]byte, error) {
	if p.Action != ApprovalActionAdd && p.Action != ApprovalActionRevoke {
		return nil, ErrDevicePolicyApproval
	}
	canonical, err := canonicalApprovalPayload(p)
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256(canonical)
	msg := make([]byte, 0, len(approvalDomainPrefix)+len(p.Action)+1+len(digest))
	msg = append(msg, approvalDomainPrefix...)
	msg = append(msg, p.Action...)
	msg = append(msg, 0x00)
	msg = append(msg, digest[:]...)
	return msg, nil
}

// ---- strict JSON (K6): unknown, duplicated and null fields are errors ----

func devicePolicyAllowedKey(k string) bool {
	switch k {
	case "version", "devices", "device_id", "actor", "subject", "signing_key",
		"fingerprint", "status", "device_revision", "acceptance", "approved_by",
		"revision", "previous_sha256", "policy_sha256", "policy":
		return true
	}
	return false
}

func strictDevicePolicy(data []byte, v any) error {
	if len(data) == 0 || len(data) > MaxDevicePolicyBytes {
		return ErrDevicePolicyConfig
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	var scan func(int) error
	scan = func(depth int) error {
		if depth > 8 {
			return ErrDevicePolicyConfig
		}
		tok, e := dec.Token()
		if e != nil || tok == nil {
			return ErrDevicePolicyConfig
		}
		if delim, ok := tok.(json.Delim); ok {
			switch delim {
			case '{':
				seen := map[string]bool{}
				for dec.More() {
					keyTok, e := dec.Token()
					if e != nil {
						return ErrDevicePolicyConfig
					}
					key, ok := keyTok.(string)
					if !ok || !devicePolicyAllowedKey(key) || seen[key] {
						return ErrDevicePolicyConfig
					}
					seen[key] = true
					if e = scan(depth + 1); e != nil {
						return e
					}
				}
				end, e := dec.Token()
				if e != nil || end != json.Delim('}') {
					return ErrDevicePolicyConfig
				}
			case '[':
				for dec.More() {
					if e := scan(depth + 1); e != nil {
						return e
					}
				}
				end, e := dec.Token()
				if e != nil || end != json.Delim(']') {
					return ErrDevicePolicyConfig
				}
			default:
				return ErrDevicePolicyConfig
			}
		}
		return nil
	}
	if e := scan(0); e != nil {
		return e
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return ErrDevicePolicyConfig
	}
	for k, val := range raw {
		if string(val) == "null" {
			return fmt.Errorf("field %q is null: %w", k, ErrDevicePolicyConfig)
		}
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return ErrDevicePolicyConfig
	}
	if _, err := dec.Token(); err != io.EOF {
		return ErrDevicePolicyConfig
	}
	return nil
}

func parseDevicePolicyRecord(data []byte) (PolicyRecord4, error) {
	var rec PolicyRecord4
	if err := strictDevicePolicy(data, &rec); err != nil {
		return PolicyRecord4{}, err
	}
	if rec.Policy.Version != DevicePolicyVersion {
		return PolicyRecord4{}, fmt.Errorf("unsupported policy version %d (want %d): %w", rec.Policy.Version, DevicePolicyVersion, ErrDevicePolicyConfig)
	}
	return rec, nil
}

// IsIdentifier reports whether s is a policy identifier: [A-Za-z0-9_-]{1,max}.
// The relay applies the same rule to device ids, Welcome targets and
// replicated member entries so no other spelling ever reaches the store.
func IsIdentifier(s string, max int) bool { return identifier(s, max) }

// IsSubject reports whether s is a valid caller-subject binding: the CF Access
// identity a device's requests must carry (DEVICES-V4 "subject"). Deliberately
// wider than IsIdentifier — a subject is only ever compared, never used as a
// name — it accepts the service-token `common_name` form (the Client-Id,
// `<id>.access`, carries a dot) and email-shaped `sub` values (`@`). The
// review-2 hygiene classes stay out: whitespace, `=`, control characters and
// other metacharacters are refused, and the length cap holds.
func IsSubject(s string, max int) bool {
	if len(s) < 1 || len(s) > max {
		return false
	}
	return strings.IndexFunc(s, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' ||
			r == '-' || r == '_' || r == '.' || r == '@')
	}) < 0
}

func identifier(s string, max int) bool {
	if len(s) < 1 || len(s) > max {
		return false
	}
	return strings.IndexFunc(s, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_')
	}) < 0
}

func DecodeSigningKey(hexKey string) ([]byte, error) {
	raw, err := hex.DecodeString(hexKey)
	if err != nil || len(raw) != ed25519.SeedSize || hex.EncodeToString(raw) != hexKey {
		return nil, ErrDevicePolicyConfig
	}
	return raw, nil
}

// validateDeviceSet enforces the v4 invariants on a full device set.
func validateDeviceSet(devices []DeviceV4) error {
	if len(devices) > MaxDevicesTotal {
		return fmt.Errorf("too many devices: %d > %d: %w", len(devices), MaxDevicesTotal, ErrDevicePolicyConfig)
	}
	ids, keys := map[string]bool{}, map[string]bool{}
	activePerActor := map[string]int{}
	for _, d := range devices {
		key, err := DecodeSigningKey(d.SigningKey)
		if err != nil {
			return fmt.Errorf("device %q signing key: %w", d.ID, err)
		}
		sum := sha256.Sum256(key)
		if d.Fingerprint != hex.EncodeToString(sum[:]) {
			return fmt.Errorf("device %q fingerprint does not match its key: %w", d.ID, ErrDevicePolicyConfig)
		}
		if !identifier(d.ID, 64) || !identifier(d.Actor, 64) || !IsSubject(d.Subject, 128) {
			return fmt.Errorf("device %q has an invalid identifier: %w", d.ID, ErrDevicePolicyConfig)
		}
		if ids[d.ID] || keys[d.SigningKey] {
			return fmt.Errorf("device %q reuses an id or signing key: %w", d.ID, ErrDevicePolicyConfig)
		}
		ids[d.ID], keys[d.SigningKey] = true, true
		if d.Acceptance != AcceptanceOutOfBand && d.Acceptance != AcceptanceTrusted {
			return fmt.Errorf("device %q has an unknown acceptance %q: %w", d.ID, d.Acceptance, ErrDevicePolicyConfig)
		}
		switch {
		case d.Status == StatusActive && d.Revision == 1:
		case d.Status == StatusRevoked && d.Revision == 2:
		default:
			return fmt.Errorf("device %q has an invalid status/revision pair: %w", d.ID, ErrDevicePolicyConfig)
		}
		if d.ApprovedBy != nil {
			if d.ApprovedBy.DeviceID == d.ID {
				return fmt.Errorf("device %q approves itself: %w", d.ID, ErrDevicePolicyConfig)
			}
			if d.ApprovedBy.Revision < 1 {
				return fmt.Errorf("device %q has an invalid approved_by revision: %w", d.ID, ErrDevicePolicyConfig)
			}
		}
		if d.Acceptance == AcceptanceTrusted && d.ApprovedBy == nil {
			return fmt.Errorf("device %q is trusted-device enrolled but has no approved_by: %w", d.ID, ErrDevicePolicyConfig)
		}
		if d.Status == StatusActive {
			activePerActor[d.Actor]++
			if activePerActor[d.Actor] > MaxActivePerActor {
				return fmt.Errorf("actor %q exceeds %d active devices: %w", d.Actor, MaxActivePerActor, ErrDevicePolicyConfig)
			}
		}
	}
	// Every approved_by must reference an existing device of the same actor.
	byID := map[string]DeviceV4{}
	for _, d := range devices {
		byID[d.ID] = d
	}
	for _, d := range devices {
		if d.ApprovedBy == nil {
			continue
		}
		approver, ok := byID[d.ApprovedBy.DeviceID]
		if !ok || approver.Actor != d.Actor {
			return fmt.Errorf("device %q approved_by references a missing or cross-actor device: %w", d.ID, ErrDevicePolicyConfig)
		}
	}
	return nil
}

func immutableDeviceFieldsDiffer(a, b DeviceV4) bool {
	return a.ID != b.ID || a.Actor != b.Actor || a.Subject != b.Subject ||
		a.SigningKey != b.SigningKey || a.Fingerprint != b.Fingerprint || a.Acceptance != b.Acceptance
}

// deviceTransitionV4 validates old → next. The only permitted changes are
// appending new active devices (E1/E2) and active→revoked tombstones (E3/E4);
// every other field, including approved_by once written, is immutable. Writing
// approved_by at revocation time is allowed only on that tombstone transition.
func deviceTransitionV4(old, next []DeviceV4, nextRevision uint64) error {
	prev := make(map[string]DeviceV4, len(old))
	for _, d := range old {
		prev[d.ID] = d
	}
	seen := map[string]bool{}
	for _, n := range next {
		if seen[n.ID] {
			return fmt.Errorf("device %q duplicated in transition: %w", n.ID, ErrDevicePolicyConfig)
		}
		seen[n.ID] = true
		o, existed := prev[n.ID]
		if !existed {
			if n.Status != StatusActive || n.Revision != 1 {
				return fmt.Errorf("new device %q must be active/1: %w", n.ID, ErrDevicePolicyConfig)
			}
			if n.Acceptance == AcceptanceOutOfBand {
				if n.ApprovedBy != nil {
					return fmt.Errorf("device %q is out-of-band enrolled and must not carry approved_by: %w", n.ID, ErrDevicePolicyConfig)
				}
				if countActive(old, n.Actor) != 0 {
					return fmt.Errorf("actor %q still has active devices; enroll-first applies only to the first device (use add-device): %w", n.Actor, ErrDevicePolicyConfig)
				}
			}
			// Trusted enrollment evidence is checked against the active set at
			// apply time (verifyAndApplyApproval) and bound to nextRevision here.
			if n.ApprovedBy != nil && n.ApprovedBy.Revision != nextRevision {
				return fmt.Errorf("device %q approved_by revision %d does not bind revision %d: %w", n.ID, n.ApprovedBy.Revision, nextRevision, ErrDevicePolicyConfig)
			}
			continue
		}
		if immutableDeviceFieldsDiffer(o, n) {
			return fmt.Errorf("device %q changed immutable fields: %w", n.ID, ErrDevicePolicyConfig)
		}
		if !approvalEqual(o.ApprovedBy, n.ApprovedBy) {
			// approved_by may be written exactly once, and only on the
			// active→revoked transition (device-signed revocation evidence).
			if !(o.Status == StatusActive && n.Status == StatusRevoked && o.ApprovedBy == nil && n.ApprovedBy != nil && n.ApprovedBy.Revision == nextRevision) {
				return fmt.Errorf("device %q changed approved_by outside a first-time device-signed revocation: %w", n.ID, ErrDevicePolicyConfig)
			}
		}
		if o.Status == n.Status && o.Revision == n.Revision {
			continue
		}
		if !(o.Status == StatusActive && o.Revision == 1 && n.Status == StatusRevoked && n.Revision == 2) {
			return fmt.Errorf("device %q has an invalid transition %s/%d → %s/%d: %w", n.ID, o.Status, o.Revision, n.Status, n.Revision, ErrDevicePolicyConfig)
		}
	}
	for _, d := range old {
		if !seen[d.ID] {
			return fmt.Errorf("device %q deleted from the policy: %w", d.ID, ErrDevicePolicyConfig)
		}
	}
	return nil
}

func countActive(devices []DeviceV4, actor string) int {
	n := 0
	for _, d := range devices {
		if d.Actor == actor && d.Status == StatusActive {
			n++
		}
	}
	return n
}

func approvalEqual(a, b *DeviceApproval) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

// VerifyApproval checks device-signed E2/E3 evidence against the pre-transition
// state: the approver must be an existing ACTIVE device of the same actor with
// the given signing key, and the Ed25519 signature must verify over the
// domain-separated canonical payload bound to the revision being created.
func VerifyApproval(old []DeviceV4, action string, payload ApprovalPayloadWire, approverKeyHex, signatureHex string, baseRevision uint64) (string, error) {
	if action != ApprovalActionAdd && action != ApprovalActionRevoke {
		return "", ErrDevicePolicyApproval
	}
	if payload.Action != action || payload.BaseRevision != baseRevision || baseRevision < 1 {
		return "", ErrDevicePolicyApproval
	}
	key, err := DecodeSigningKey(approverKeyHex)
	if err != nil {
		return "", fmt.Errorf("approver key: %w", err)
	}
	var approver *DeviceV4
	for i := range old {
		if old[i].SigningKey == approverKeyHex {
			approver = &old[i]
			break
		}
	}
	if approver == nil || approver.Status != StatusActive {
		return "", fmt.Errorf("approver device is not active: %w", ErrDevicePolicyApproval)
	}
	if approver.Actor != payload.Actor || approver.ID == payload.DeviceID {
		return "", fmt.Errorf("approver must be a different device of the same actor: %w", ErrDevicePolicyApproval)
	}
	sig, err := hex.DecodeString(signatureHex)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return "", fmt.Errorf("approval signature: %w", ErrDevicePolicyApproval)
	}
	msg, err := ApprovalMessage(payload)
	if err != nil {
		return "", err
	}
	if !ed25519.Verify(key, msg, sig) {
		return "", ErrDevicePolicyApproval
	}
	return approver.ID, nil
}

// ---- storage: same file-safety kernel as the v1 auth policy ----

func devicePrivateDir(path string) (*os.File, error) {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return nil, ErrDevicePolicyState
	}
	for p := path; ; p = filepath.Dir(p) {
		st, e := os.Lstat(p)
		if e != nil || !st.IsDir() || st.Mode()&os.ModeSymlink != 0 {
			return nil, ErrDevicePolicyState
		}
		uid := st.Sys().(*syscall.Stat_t).Uid
		if (uid != 0 && uid != uint32(os.Geteuid())) || (st.Mode().Perm()&0022 != 0 && !(uid == 0 && st.Mode()&os.ModeSticky != 0)) {
			return nil, ErrDevicePolicyState
		}
		if p == path && (uid != uint32(os.Geteuid()) || st.Mode().Perm() != 0700) {
			return nil, ErrDevicePolicyState
		}
		if p == "/" {
			break
		}
	}
	fd, e := syscall.Open(path, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if e != nil {
		return nil, ErrDevicePolicyState
	}
	return os.NewFile(uintptr(fd), "native device policy directory"), nil
}

func devicePrivateFile(dir *os.File, name string, create bool) (*os.File, error) {
	flags := syscall.O_RDONLY | syscall.O_NONBLOCK | syscall.O_NOFOLLOW | syscall.O_CLOEXEC
	if create {
		flags = syscall.O_RDWR | syscall.O_CREAT | syscall.O_EXCL | syscall.O_NONBLOCK | syscall.O_NOFOLLOW | syscall.O_CLOEXEC
	}
	fd, e := syscall.Openat(int(dir.Fd()), name, flags, 0600)
	if e != nil {
		return nil, e
	}
	f := os.NewFile(uintptr(fd), "native device policy file")
	if create {
		if e = f.Chmod(0600); e != nil {
			f.Close()
			return nil, e
		}
	}
	st, e := f.Stat()
	if e != nil {
		f.Close()
		return nil, ErrDevicePolicyState
	}
	raw := st.Sys().(*syscall.Stat_t)
	if !st.Mode().IsRegular() || st.Mode().Perm() != 0600 || raw.Uid != uint32(os.Geteuid()) || raw.Nlink != 1 {
		f.Close()
		return nil, ErrDevicePolicyState
	}
	return f, nil
}

func readDevicePolicyFile(dir *os.File, name string) ([]byte, error) {
	f, e := devicePrivateFile(dir, name, false)
	if e != nil {
		return nil, ErrDevicePolicyState
	}
	defer f.Close()
	b, e := io.ReadAll(io.LimitReader(f, MaxDevicePolicyBytes+1))
	if e != nil || len(b) > MaxDevicePolicyBytes {
		return nil, ErrDevicePolicyState
	}
	return b, nil
}

func devicePolicyRevisionName(n uint64) string { return fmt.Sprintf("policy-%06d.json", n) }

// DevicePolicyStore manages one revision chain directory.
type DevicePolicyStore struct {
	dir string
	mu  sync.Mutex
}

func OpenDevicePolicyStore(dir string) (*DevicePolicyStore, error) {
	d, e := devicePrivateDir(dir)
	if e != nil {
		return nil, e
	}
	d.Close()
	return &DevicePolicyStore{dir: dir}, nil
}

// ReadCandidate mirrors the operational policy CLI's input convention: the
// candidate/evidence file must be a private (0600, single-link, symlink-free)
// regular file inside an equally safe directory, read whole. The caller owns
// the candidate schema and its strict decoding.
func ReadCandidate(path string) ([]byte, error) {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return nil, ErrDevicePolicyState
	}
	dir, e := devicePrivateDir(filepath.Dir(path))
	if e != nil {
		return nil, e
	}
	defer dir.Close()
	return readDevicePolicyFile(dir, filepath.Base(path))
}

func (s *DevicePolicyStore) locked(fn func(*os.File) error) error {
	// G-M7: acquire the cross-process flock WITHOUT holding the in-process
	// mutex — a manager commit that keeps the lock for a moment must not
	// serialize every other caller of this store behind one ≤2s poll loop;
	// the waiters poll concurrently and proceed together when it frees. The
	// mutex stays exactly where it matters: fn runs exclusive in-process,
	// and its caller releases the flock only after the mutex (the defers run
	// in reverse), so a flock holder never waits on the mutex.
	d, e := devicePrivateDir(s.dir)
	if e != nil {
		return e
	}
	defer d.Close()
	lock, e := devicePrivateFile(d, "lock", true)
	if errors.Is(e, syscall.EEXIST) {
		lock, e = devicePrivateFile(d, "lock", false)
	}
	if e != nil {
		return ErrDevicePolicyState
	}
	defer lock.Close()
	st, err := lock.Stat()
	if err != nil || st.Size() != 0 {
		return ErrDevicePolicyState
	}
	until := time.Now().Add(2 * time.Second)
	for {
		e = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if e == nil {
			break
		}
		if e != syscall.EWOULDBLOCK || time.Now().After(until) {
			return ErrDevicePolicyState
		}
		time.Sleep(10 * time.Millisecond)
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	s.mu.Lock()
	defer s.mu.Unlock()
	return fn(d)
}

// records replays the whole chain, strictest first failure wins. A malformed
// chain reports the observed (highest) revision so a live manager never
// silently accepts an older state after an error.
func devicePolicyRecords(d *os.File) (DevicePolicyInfo, PolicyWire4, error) {
	var info DevicePolicyInfo
	var current PolicyWire4
	var observed uint64
	defer func() {
		if observed > info.Revision {
			info.Revision = observed
		}
	}()
	entries, e := d.ReadDir(MaxDevicePolicyRevisions + MaxPendingPolicyFiles + 2)
	if e != nil && e != io.EOF {
		return info, current, ErrDevicePolicyState
	}
	if len(entries) > MaxDevicePolicyRevisions+MaxPendingPolicyFiles+1 {
		return info, current, ErrDevicePolicyState
	}
	names := []string{}
	pending := 0
	for _, ent := range entries {
		// "lock" is the flock anchor. A "pending-<hex>" file is a staging
		// artifact of an interrupted writeDevicePolicyRevision (crash between
		// its creation and the renameat into the chain): it is not a chain
		// link, so a leftover one must not fail the replay (G-M7 — it used to
		// turn every required-mode read, GET included, into a 500). The
		// committed revisions alone decide the state; the pending file is
		// retained for inspection, never retried automatically. An
		// established chain with revision 0 (interrupted very first write)
		// still fails closed below, and a flood of staging files stays a
		// fail-closed anomaly.
		if ent.Name() == "lock" {
			continue
		}
		if strings.HasPrefix(ent.Name(), "pending-") {
			pending++
			if pending > MaxPendingPolicyFiles {
				return info, current, ErrDevicePolicyState
			}
			continue
		}
		names = append(names, ent.Name())
	}
	if len(names) > MaxDevicePolicyRevisions+1 {
		return info, current, ErrDevicePolicyState
	}
	sort.Strings(names)
	for _, name := range names {
		if len(name) == 18 && strings.HasPrefix(name, "policy-") && strings.HasSuffix(name, ".json") {
			if n, e := strconv.ParseUint(name[7:13], 10, 64); e == nil && name == devicePolicyRevisionName(n) && n > observed {
				observed = n
			}
		}
	}
	for i, name := range names {
		rev := uint64(i + 1)
		if name != devicePolicyRevisionName(rev) {
			return info, current, ErrDevicePolicyState
		}
		info.Revision = rev
		b, e := readDevicePolicyFile(d, name)
		if e != nil {
			return info, current, e
		}
		rec, e := parseDevicePolicyRecord(b)
		if e != nil || rec.Revision != rev || rec.Previous != info.SHA256 {
			return info, current, ErrDevicePolicyState
		}
		encoded, _ := json.Marshal(rec.Policy)
		sum := sha256.Sum256(encoded)
		if rec.PolicySHA256 != hex.EncodeToString(sum[:]) {
			return info, current, ErrDevicePolicyState
		}
		if e := validateDeviceSet(rec.Policy.Devices); e != nil {
			return info, current, ErrDevicePolicyState
		}
		if rev > 1 {
			if e := deviceTransitionV4(current.Devices, rec.Policy.Devices, rev); e != nil {
				return info, current, ErrDevicePolicyState
			}
		}
		current = rec.Policy
		h := sha256.Sum256(b)
		info.SHA256 = hex.EncodeToString(h[:])
	}
	return info, current, nil
}

// Read validates and returns the current chain state.
func (s *DevicePolicyStore) Read() (DevicePolicyInfo, PolicyWire4, error) {
	var info DevicePolicyInfo
	var policy PolicyWire4
	e := s.locked(func(d *os.File) error {
		var e error
		info, policy, e = devicePolicyRecords(d)
		if e == nil && info.Revision == 0 {
			return ErrDevicePolicyState
		}
		return e
	})
	return info, policy, e
}

// Init creates the genesis revision (empty device set) in an empty directory.
// Init creates the genesis revision (empty device set) in an empty directory.
// The flock anchor created by locked() is not directory content.
func (s *DevicePolicyStore) Init() (DevicePolicyInfo, error) {
	var out DevicePolicyInfo
	e := s.locked(func(d *os.File) error {
		entries, e := d.ReadDir(MaxDevicePolicyRevisions + 2)
		if e != nil && e != io.EOF {
			return ErrDevicePolicyState
		}
		for _, ent := range entries {
			if ent.Name() != "lock" {
				return ErrDevicePolicyConflict
			}
		}
		genesis := PolicyWire4{Version: DevicePolicyVersion, Devices: []DeviceV4{}}
		return writeDevicePolicyRevision(d, 1, "", genesis, &out)
	})
	return out, e
}

// Commit appends one immutable revision with CAS. An exact byte-equal replay of
// the immediately preceding outcome returns the existing revision (K4); a
// different current revision is a conflict. Uncertain writes are never retried
// automatically — pending files and prior revisions are retained for inspection.
func (s *DevicePolicyStore) Commit(expected uint64, next PolicyWire4) (DevicePolicyInfo, error) {
	if next.Version != DevicePolicyVersion {
		return DevicePolicyInfo{}, ErrDevicePolicyConfig
	}
	if err := validateDeviceSet(next.Devices); err != nil {
		return DevicePolicyInfo{}, err
	}
	var out DevicePolicyInfo
	e := s.locked(func(d *os.File) error {
		old, previous, e := devicePolicyRecords(d)
		if e != nil {
			return e
		}
		if old.Revision == expected+1 && expected < MaxDevicePolicyRevisions &&
			approvalEqualPolicy(previous, next) {
			out = old // exact replay of the immediately preceding outcome
			return nil
		}
		if old.Revision != expected {
			return fmt.Errorf("current revision %d != expected %d: %w", old.Revision, expected, ErrDevicePolicyConflict)
		}
		if e := deviceTransitionV4(previous.Devices, next.Devices, expected+1); e != nil {
			return e
		}
		if old.Revision >= MaxDevicePolicyRevisions {
			return fmt.Errorf("policy revision space exhausted at %d (compaction not implemented): %w", MaxDevicePolicyRevisions, ErrDevicePolicyState)
		}
		return writeDevicePolicyRevision(d, expected+1, old.SHA256, next, &out)
	})
	return out, e
}

func approvalEqualPolicy(a, b PolicyWire4) bool {
	ab, err1 := json.Marshal(a)
	bb, err2 := json.Marshal(b)
	return err1 == nil && err2 == nil && bytes.Equal(ab, bb)
}

// randRead fills b with cryptographically random bytes (v1 policy uses the same
// source for pending-file nonces).
func randRead(b []byte) (int, error) {
	return crand.Read(b)
}

// writeDevicePolicyRevision mirrors the v1 write path: pending file → fsync →
// close → target must not exist → renameat → directory fsync. The chain link is
// the sha256 of the raw file bytes (including the trailing newline).
func writeDevicePolicyRevision(d *os.File, revision uint64, previousSHA string, policy PolicyWire4, out *DevicePolicyInfo) error {
	encodedPolicy, _ := json.Marshal(policy)
	sum := sha256.Sum256(encodedPolicy)
	data, e := json.Marshal(PolicyRecord4{
		Revision:     revision,
		Previous:     previousSHA,
		PolicySHA256: hex.EncodeToString(sum[:]),
		Policy:       policy,
	})
	if e != nil || len(data)+1 > MaxDevicePolicyBytes {
		return ErrDevicePolicyConfig
	}
	data = append(data, '\n')
	var nonce [16]byte
	if _, e := randRead(nonce[:]); e != nil {
		return e
	}
	pending := "pending-" + hex.EncodeToString(nonce[:])
	f, e := devicePrivateFile(d, pending, true)
	if e != nil {
		return ErrDevicePolicyState
	}
	defer f.Close()
	if _, e = f.Write(data); e != nil {
		return ErrDevicePolicyState
	}
	if e = f.Sync(); e != nil {
		return ErrDevicePolicyState
	}
	if e = f.Close(); e != nil {
		return ErrDevicePolicyState
	}
	target := devicePolicyRevisionName(revision)
	if existing, e := devicePrivateFile(d, target, false); e == nil {
		existing.Close()
		return ErrDevicePolicyState
	} else if !errors.Is(e, syscall.ENOENT) {
		return ErrDevicePolicyState
	}
	if e = syscall.Renameat(int(d.Fd()), pending, int(d.Fd()), target); e != nil {
		return ErrDevicePolicyState
	}
	if e = d.Sync(); e != nil {
		return ErrDevicePolicyState
	}
	h := sha256.Sum256(data)
	*out = DevicePolicyInfo{Revision: revision, SHA256: hex.EncodeToString(h[:])}
	return nil
}
