package access

import (
	"reflect"
)

// Activation is separate, explicit authority for one successor target. It never
// changes the first-device list or makes an old lease permanent. The server must
// also match the digest to its two verified, durable enrollment consents.
type Activation struct {
	Intent         string `json:"intent_id"`
	ApprovalSHA256 string `json:"approval_sha256"`
	Status         string `json:"status"`
}

func cloneActivations(c Config) ([]Activation, error) {
	if c.Activations == nil {
		return nil, nil
	}
	if c.Successors == nil || len(c.Activations) == 0 || len(c.Activations) > 16 {
		return nil, ErrConfig
	}
	out := append([]Activation{}, c.Activations...)
	seen := map[string]bool{}
	for _, a := range out {
		if seen[a.Intent] || !canonicalHex(a.ApprovalSHA256, 32, 32) || (a.Status != "active" && a.Status != "revoked") {
			return nil, ErrConfig
		}
		found := false
		for _, i := range c.Successors.Intents {
			if i.ID == a.Intent && i.Status == "accepted" {
				found = true
			}
		}
		if !found {
			return nil, ErrConfig
		}
		seen[a.Intent] = true
	}
	return out, nil
}
func activationForward(old, next Config) error {
	for _, a := range old.Activations {
		found := false
		for _, b := range next.Activations {
			if b.Intent == a.Intent {
				if b.ApprovalSHA256 != a.ApprovalSHA256 || (a.Status == "revoked" && b.Status != "revoked") {
					return ErrConfig
				}
				found = true
			}
		}
		if !found {
			return ErrConfig
		}
	}
	return nil
}
func activationTransition(old, next Config, now int64) error {
	if activationForward(old, next) != nil {
		return ErrConfig
	}
	if reflect.DeepEqual(old.Activations, next.Activations) {
		return nil
	}
	// Scope changes cannot carry identity, administrator, key or intent edits.
	a, b := old, next
	a.Activations = nil
	b.Activations = nil
	if !reflect.DeepEqual(a, b) {
		return ErrConfig
	}
	for _, n := range next.Activations {
		exists := false
		for _, p := range old.Activations {
			if n.Intent == p.Intent {
				exists = true
			}
		}
		if exists {
			continue
		}
		if n.Status != "active" {
			return ErrConfig
		}
		found := false
		for _, i := range old.Successors.Intents {
			if i.ID == n.Intent && administratorCurrent(old, i.Administrator) && (now == 0 || now < i.ExpiresAt) {
				found = true
			}
		}
		if !found {
			return ErrConfig
		}
	}
	return nil
}

// Called only within Grant.Run; current enrollment/admin generation is retained
// in g.successors even after intent expiry. A revoked policy never returns here.
func (g *Grant) ActivatedSuccessor(id string) (SuccessorIntent, string, error) {
	for _, a := range g.activations {
		if a.Intent == id && a.Status == "active" {
			for _, i := range g.successors {
				if i.ID == id {
					return i, a.ApprovalSHA256, nil
				}
			}
		}
	}
	return SuccessorIntent{}, "", ErrDenied
}
func (s *PolicyStore) CommitActivation(expected uint64, c Config) (PolicyInfo, error) {
	if c.Activations == nil {
		return PolicyInfo{}, ErrConfig
	}
	return s.commit(expected, c, 2)
}

func (g *Grant) ActivationRevoked(id string) bool {
	for _, a := range g.activations {
		if a.Intent == id && a.Status == "revoked" {
			return true
		}
	}
	return false
}
