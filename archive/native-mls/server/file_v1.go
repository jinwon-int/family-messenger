package main

// file-v1 retirement (family-messenger#499 decision 6, step ①): file-v1 put
// the whole attachment inside one MLS application message whose outer
// client_id is `file-v1-<uuid>` (≤ 5 MiB per event, `RELAY-APP.md`
// 「첨부」). Every current sender uses file-v2 (`FILE-V2.md`, blob store), so
// from fileV1RetireAt the relay refuses NEW file-v1 posts with 410
// `file_v1_retired`. Rows already stored are untouched: GET /events, /watch,
// retention and pruning treat them exactly as before, so every device keeps
// reading the v1 photos and files it already has.
//
// Scope, deliberately narrow:
//   - kind=application only. Commits and welcomes never carry this prefix
//     (their client_ids are `<device>-<random>`, the bot's
//     `<own>-welcome-<seq>` / `<own>-<op>-<ms>`), and refusing a commit could
//     wedge a room's epoch chain.
//   - The PREFIX `file-v1-`, not only the strict `^file-v1-[a-f0-9-]{36}$`
//     shape the apps display as an attachment: host-core before #366 3f
//     treated any `file-v1-` prefix as an attachment, so an old build can
//     still render a non-canonical variant as a file. No current client
//     sends any `file-v1-…` id for a text message, so the prefix costs nothing
//     and closes the variants.
//   - Checked after authentication and device binding, before storeEvent:
//     a refused post creates no room, writes no row, moves no CAS pointer,
//     counts against no byte cap and pushes nothing.
//   - A byte-equal retry of a v1 row stored before the cutoff is refused 410
//     as well, not answered 200 duplicate: the check runs before the K4
//     replay lookup, and a sender that sees 410 must stop retrying either
//     way. The stored row stays readable.
//
// The cutoff is an absolute instant, so merging or deploying the binary
// earlier does not activate the refusal early. -file-v1-retire-at overrides
// it (RFC 3339, or "off" for the legacy relay-app acceptance smoke, which
// still exercises the v1 path end to end).

import (
	"fmt"
	"strings"
	"time"
)

const fileV1ClientIDPrefix = "file-v1-"

// fileV1RetireAt = 2026-12-03 00:00:00 KST (= 2026-12-02 15:00:00 UTC).
var fileV1RetireAt = time.Date(2026, time.December, 3, 0, 0, 0, 0, time.FixedZone("KST", 9*60*60))

// clock is the relay's notion of "now" for time-gated contract rules; tests
// pin relay.now.
func (s *relay) clock() time.Time {
	if s.now != nil {
		return s.now()
	}
	return time.Now()
}

// fileV1Retired reports whether a POST /events with this kind and outer
// client_id must be refused 410 file_v1_retired at the current clock.
func (s *relay) fileV1Retired(kind, clientID string) bool {
	at := s.policy.FileV1RetireAtUnix
	return at > 0 && kind == "application" &&
		strings.HasPrefix(clientID, fileV1ClientIDPrefix) && s.clock().Unix() >= at
}

// parseFileV1RetireAt parses the -file-v1-retire-at flag: an RFC 3339
// instant, or "off" (0 = never refuse).
func parseFileV1RetireAt(v string) (int64, error) {
	if v == "off" {
		return 0, nil
	}
	t, err := time.Parse(time.RFC3339, v)
	if err != nil {
		return 0, fmt.Errorf("-file-v1-retire-at: want an RFC 3339 time or \"off\": %w", err)
	}
	if t.Unix() <= 0 {
		return 0, fmt.Errorf("-file-v1-retire-at: %q is not after the Unix epoch", v)
	}
	return t.Unix(), nil
}
