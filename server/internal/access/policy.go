package access

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

var ErrPolicyState = errors.New("auth policy unavailable; preserve state for inspection")
var ErrPolicyConflict = errors.New("auth policy revision conflict")
var ErrPolicyUncertain = errors.New("auth policy write outcome uncertain; inspect retained state")

const MaxPolicyBytes = 64 * 1024
const MaxPolicyRevisions = 64

type publicKey struct {
	ID string `json:"kid"`
	N  string `json:"n"`
	E  int    `json:"e"`
}
type person struct {
	Subject string `json:"subject"`
	Actor   string `json:"actor"`
	Owner   bool   `json:"owner"`
}
type policyWire struct {
	Version       int         `json:"version"`
	Issuer        string      `json:"issuer"`
	Audience      string      `json:"audience"`
	Keys          []publicKey `json:"keys"`
	People        []person    `json:"people"`
	KeysFetchedAt int64       `json:"keys_fetched_at,omitempty"`
	KeysExpireAt  int64       `json:"keys_expire_at,omitempty"`
}
type policyRecord struct {
	Revision     uint64     `json:"revision"`
	Previous     string     `json:"previous_sha256"`
	PolicySHA256 string     `json:"policy_sha256"`
	Policy       policyWire `json:"policy"`
}

// Parse exact, unique JSON field names at every depth before struct decoding.
// Unknown/case-folded fields and null are errors, never zero-value privileges.
func strictPolicy(data []byte, v any) error {
	if len(data) == 0 || len(data) > MaxPolicyBytes {
		return ErrConfig
	}
	allowed := map[string]bool{}
	for _, k := range []string{"version", "issuer", "audience", "keys", "people", "kid", "n", "e", "subject", "actor", "owner", "revision", "previous_sha256", "policy_sha256", "policy", "keys_fetched_at", "keys_expire_at"} {
		allowed[k] = true
	}
	d := json.NewDecoder(bytes.NewReader(data))
	var scan func(int) error
	scan = func(depth int) error {
		if depth > 8 {
			return ErrConfig
		}
		tok, e := d.Token()
		if e != nil || tok == nil {
			return ErrConfig
		}
		if delim, ok := tok.(json.Delim); ok {
			switch delim {
			case '{':
				seen := map[string]bool{}
				for d.More() {
					key, e := d.Token()
					if e != nil {
						return ErrConfig
					}
					k, ok := key.(string)
					if !ok || !allowed[k] || seen[k] {
						return ErrConfig
					}
					seen[k] = true
					if e = scan(depth + 1); e != nil {
						return e
					}
				}
				end, e := d.Token()
				if e != nil || end != json.Delim('}') {
					return ErrConfig
				}
			case '[':
				for d.More() {
					if e := scan(depth + 1); e != nil {
						return e
					}
				}
				end, e := d.Token()
				if e != nil || end != json.Delim(']') {
					return ErrConfig
				}
			default:
				return ErrConfig
			}
		}
		return nil
	}
	if e := scan(0); e != nil {
		return e
	}
	if d.Decode(new(any)) != io.EOF {
		return ErrConfig
	}
	d = json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if d.Decode(v) != nil {
		return ErrConfig
	}
	return nil
}
func (w policyWire) config() (Config, error) {
	if w.Version != 1 || len(w.Keys) < 1 || len(w.Keys) > 16 || len(w.People) > 32 {
		return Config{}, ErrConfig
	}
	c := Config{Issuer: w.Issuer, Audience: w.Audience, Keys: make(map[string]*rsa.PublicKey), KeysFetchedAt: w.KeysFetchedAt, KeysExpireAt: w.KeysExpireAt}
	for _, k := range w.Keys {
		if _, ok := c.Keys[k.ID]; ok {
			return Config{}, ErrConfig
		}
		n, e := base64.RawURLEncoding.Strict().DecodeString(k.N)
		if e != nil || base64.RawURLEncoding.EncodeToString(n) != k.N || len(n) < 256 || len(n) > 512 || n[0] == 0 {
			return Config{}, ErrConfig
		}
		c.Keys[k.ID] = &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: k.E}
	}
	for _, p := range w.People {
		c.People = append(c.People, Enrollment{Subject: p.Subject, Actor: p.Actor, Owner: p.Owner})
	}
	out, _, e := clone(c)
	return out, e
}
func wire(c Config) (policyWire, error) {
	c, _, e := clone(c)
	if e != nil {
		return policyWire{}, e
	}
	w := policyWire{Version: 1, Issuer: c.Issuer, Audience: c.Audience, Keys: []publicKey{}, People: []person{}, KeysFetchedAt: c.KeysFetchedAt, KeysExpireAt: c.KeysExpireAt}
	ids := make([]string, 0, len(c.Keys))
	for id := range c.Keys {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		k := c.Keys[id]
		w.Keys = append(w.Keys, publicKey{id, base64.RawURLEncoding.EncodeToString(k.N.Bytes()), k.E})
	}
	for _, p := range c.People {
		w.People = append(w.People, person{p.Subject, p.Actor, p.Owner})
	}
	return w, nil
}
func ParsePolicy(data []byte) (Config, error) {
	var w policyWire
	if e := strictPolicy(data, &w); e != nil {
		return Config{}, e
	}
	return w.config()
}
func EncodePolicy(c Config) ([]byte, error) {
	w, e := wire(c)
	if e != nil {
		return nil, e
	}
	return json.Marshal(w)
}

// Private directory handles anchor all state operations. Same-UID/root mutation
// outside this cooperating API is not a supported writer or a rollback witness.
func privateDir(path string) (*os.File, error) {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return nil, ErrPolicyState
	}
	for p := path; ; p = filepath.Dir(p) {
		st, e := os.Lstat(p)
		if e != nil || !st.IsDir() || st.Mode()&os.ModeSymlink != 0 {
			return nil, ErrPolicyState
		}
		uid := st.Sys().(*syscall.Stat_t).Uid
		if (uid != 0 && uid != uint32(os.Geteuid())) || (st.Mode().Perm()&0022 != 0 && !(uid == 0 && st.Mode()&os.ModeSticky != 0)) {
			return nil, ErrPolicyState
		}
		if p == path && (uid != uint32(os.Geteuid()) || st.Mode().Perm() != 0700) {
			return nil, ErrPolicyState
		}
		if p == "/" {
			break
		}
	}
	fd, e := syscall.Open(path, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if e != nil {
		return nil, ErrPolicyState
	}
	return os.NewFile(uintptr(fd), "auth directory"), nil
}
func privateFile(dir *os.File, name string, create bool) (*os.File, error) {
	flags := syscall.O_RDONLY | syscall.O_NONBLOCK | syscall.O_NOFOLLOW | syscall.O_CLOEXEC
	if create {
		flags = syscall.O_RDWR | syscall.O_CREAT | syscall.O_EXCL | syscall.O_NONBLOCK | syscall.O_NOFOLLOW | syscall.O_CLOEXEC
	}
	fd, e := syscall.Openat(int(dir.Fd()), name, flags, 0600)
	if e != nil {
		return nil, e
	}
	f := os.NewFile(uintptr(fd), "auth file")
	if create {
		if e = f.Chmod(0600); e != nil {
			f.Close()
			return nil, e
		}
	}
	st, e := f.Stat()
	if e != nil {
		f.Close()
		return nil, ErrPolicyState
	}
	raw := st.Sys().(*syscall.Stat_t)
	if !st.Mode().IsRegular() || st.Mode().Perm() != 0600 || raw.Uid != uint32(os.Geteuid()) || raw.Nlink != 1 {
		f.Close()
		return nil, ErrPolicyState
	}
	return f, nil
}
func readFile(dir *os.File, name string) ([]byte, error) {
	f, e := privateFile(dir, name, false)
	if e != nil {
		return nil, ErrPolicyState
	}
	defer f.Close()
	b, e := io.ReadAll(io.LimitReader(f, MaxPolicyBytes+1))
	if e != nil || len(b) > MaxPolicyBytes {
		return nil, ErrPolicyState
	}
	return b, nil
}

// ReadCandidate reads a private proposal, never a live policy revision in place.
func ReadCandidate(path string) (Config, error) {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return Config{}, ErrPolicyState
	}
	dir, e := privateDir(filepath.Dir(path))
	if e != nil {
		return Config{}, e
	}
	defer dir.Close()
	b, e := readFile(dir, filepath.Base(path))
	if e != nil {
		return Config{}, e
	}
	return ParsePolicy(b)
}

type PolicyStore struct {
	dir   string
	mu    sync.Mutex
	fault func(string) error
}
type PolicyInfo struct {
	Revision uint64 `json:"revision"`
	SHA256   string `json:"sha256"`
}

func OpenPolicyStore(dir string) (*PolicyStore, error) {
	d, e := privateDir(dir)
	if e != nil {
		return nil, e
	}
	d.Close()
	return &PolicyStore{dir: dir}, nil
}

// Every managed read/update happens under the same cross-process lock. A missing
// lock in an existing directory may be created; no policy or unknown file is reset.
func (s *PolicyStore) locked(fn func(*os.File) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, e := privateDir(s.dir)
	if e != nil {
		return e
	}
	defer d.Close()
	lock, e := privateFile(d, "lock", true)
	if errors.Is(e, syscall.EEXIST) {
		lock, e = privateFile(d, "lock", false)
	}
	if e != nil {
		return ErrPolicyState
	}
	defer lock.Close()
	st, err := lock.Stat()
	if err != nil || st.Size() != 0 {
		return ErrPolicyState
	}
	until := time.Now().Add(2 * time.Second)
	for {
		e = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if e == nil {
			break
		}
		if e != syscall.EWOULDBLOCK || time.Now().After(until) {
			return ErrPolicyState
		}
		time.Sleep(10 * time.Millisecond)
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	return fn(d)
}
func revisionName(n uint64) string { return fmt.Sprintf("policy-%06d.json", n) }
func records(d *os.File) (info PolicyInfo, c Config, err error) {
	var observed uint64
	defer func() {
		if err != nil && observed > info.Revision {
			info.Revision = observed
		}
	}()
	entries, e := d.ReadDir(MaxPolicyRevisions + 2)
	if e != nil && e != io.EOF {
		return PolicyInfo{}, Config{}, ErrPolicyState
	}
	if len(entries) > MaxPolicyRevisions+1 {
		return PolicyInfo{}, Config{}, ErrPolicyState
	}
	names := []string{}
	for _, ent := range entries {
		if ent.Name() == "lock" {
			continue
		}
		names = append(names, ent.Name())
	}
	sort.Strings(names)
	for _, name := range names {
		if len(name) == 18 && strings.HasPrefix(name, "policy-") && strings.HasSuffix(name, ".json") {
			n, e := strconv.ParseUint(name[7:13], 10, 64)
			if e == nil && name == revisionName(n) && n > observed {
				observed = n
			}
		}
	}
	for i, name := range names {
		rev := uint64(i + 1)
		if name != revisionName(rev) {
			return info, Config{}, ErrPolicyState
		}
		// Return the observed revision even on malformed contents, to prevent a live
		// manager from automatically accepting an older revision after an error.
		info.Revision = rev
		b, e := readFile(d, name)
		if e != nil {
			return info, Config{}, e
		}
		var rec policyRecord
		if strictPolicy(b, &rec) != nil || rec.Revision != rev || rec.Previous != info.SHA256 {
			return info, Config{}, ErrPolicyState
		}
		encoded, _ := json.Marshal(rec.Policy)
		checksum := sha256.Sum256(encoded)
		if rec.PolicySHA256 != hex.EncodeToString(checksum[:]) {
			return info, Config{}, ErrPolicyState
		}
		c, e = rec.Policy.config()
		if e != nil {
			return info, Config{}, ErrPolicyState
		}
		h := sha256.Sum256(b)
		info.SHA256 = hex.EncodeToString(h[:])
	}
	return info, c, nil
}
func (s *PolicyStore) Read() (PolicyInfo, Config, error) {
	var info PolicyInfo
	var c Config
	e := s.locked(func(d *os.File) error {
		var e error
		info, c, e = records(d)
		if e == nil && info.Revision == 0 {
			return ErrPolicyState
		}
		return e
	})
	return info, c, e
}

// Commit adds a new immutable revision with compare-and-swap. Uncertain writes
// are never retried automatically; pending files and older revisions are retained.
func (s *PolicyStore) Commit(expected uint64, c Config) (PolicyInfo, error) {
	w, e := wire(c)
	if e != nil {
		return PolicyInfo{}, e
	}
	var out PolicyInfo
	e = s.locked(func(d *os.File) error {
		old, _, e := records(d)
		if e != nil {
			return e
		}
		if old.Revision != expected {
			return ErrPolicyConflict
		}
		if old.Revision >= MaxPolicyRevisions {
			return ErrPolicyState
		}
		next := old.Revision + 1
		encoded, _ := json.Marshal(w)
		checksum := sha256.Sum256(encoded)
		data, e := json.Marshal(policyRecord{Revision: next, Previous: old.SHA256, PolicySHA256: hex.EncodeToString(checksum[:]), Policy: w})
		if e != nil || len(data)+1 > MaxPolicyBytes {
			return ErrConfig
		}
		data = append(data, '\n')
		var nonce [16]byte
		if _, e = rand.Read(nonce[:]); e != nil {
			return e
		}
		pending := "pending-" + hex.EncodeToString(nonce[:])
		f, e := privateFile(d, pending, true)
		if e != nil {
			return ErrPolicyState
		}
		defer f.Close()
		if _, e = f.Write(data); e != nil {
			return ErrPolicyUncertain
		}
		if e = f.Sync(); e != nil {
			return ErrPolicyUncertain
		}
		if s.fault != nil {
			if e = s.fault("file-synced"); e != nil {
				return ErrPolicyUncertain
			}
		}
		if e = f.Close(); e != nil {
			return ErrPolicyUncertain
		}
		// Cooperative writers hold this exclusive lock and target the next unused
		// name. We never rename over a prior policy revision.
		target := revisionName(next)
		if existing, e := privateFile(d, target, false); e == nil {
			existing.Close()
			return ErrPolicyUncertain
		} else if !errors.Is(e, syscall.ENOENT) {
			return ErrPolicyUncertain
		}
		if e = syscall.Renameat(int(d.Fd()), pending, int(d.Fd()), target); e != nil {
			return ErrPolicyUncertain
		}
		if s.fault != nil {
			if e = s.fault("renamed"); e != nil {
				return ErrPolicyUncertain
			}
		}
		if e = d.Sync(); e != nil {
			return ErrPolicyUncertain
		}
		h := sha256.Sum256(data)
		out = PolicyInfo{next, hex.EncodeToString(h[:])}
		return nil
	})
	return out, e
}

type Managed struct {
	mu        sync.Mutex
	store     *PolicyStore
	Authority *Authority
	info      PolicyInfo
	floor     uint64
	healthy   bool
	closed    bool
}

func OpenManaged(dir string) (*Managed, error) {
	s, e := OpenPolicyStore(dir)
	if e != nil {
		return nil, e
	}
	m := &Managed{store: s, Authority: &Authority{disabled: true}}
	if e = m.Refresh(); e != nil {
		return nil, e
	}
	return m, nil
}
func (m *Managed) Refresh() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return ErrPolicyState
	}
	e := m.store.locked(func(d *os.File) error {
		info, c, e := records(d)
		if info.Revision > m.floor {
			m.floor = info.Revision
		}
		if e != nil || info.Revision == 0 {
			return ErrPolicyState
		}
		if info.Revision < m.info.Revision {
			return ErrPolicyState
		}
		if m.healthy && info == m.info {
			return nil
		}
		if m.info.Revision != 0 && info.Revision <= m.info.Revision {
			return ErrPolicyState
		}
		if e = m.Authority.Replace(c); e != nil {
			return e
		}
		m.info = info
		m.healthy = true
		return nil
	})
	if e != nil {
		m.healthy = false
		m.Authority.Suspend()
		if m.floor > m.info.Revision {
			m.info.Revision = m.floor
		}
		return ErrPolicyState
	}
	return nil
}
func (m *Managed) Status() (PolicyInfo, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.info, m.healthy
}
func (m *Managed) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.closed = true
	m.healthy = false
	m.Authority.Suspend()
}
