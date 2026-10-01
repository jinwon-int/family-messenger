// native-mls v2 relay entrypoint (#177 §3.4). One process owns one SQLite
// file under -data-dir; the operational server's schema 12 database is never
// touched. Flags only allow positive overrides on top of the §3.4 retention
// defaults (see policy/defaultPolicy).
//
// Caller authentication (C1) is on by default: -access-mode required needs
// -access-issuer, -access-audience and -access-jwks (file path or https URL)
// plus -device-state, because every request is bound to the device-policy
// subject of the device it acts as. -access-mode disabled is local dev only
// and is announced loudly at startup.
package main

import (
	"flag"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/jinwon-int/family-messenger/archive/native-mls/server/internal/devicepolicy"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:18921", "IPv4 loopback listen address (the operational dev server owns 18920)")
	dataDir := flag.String("data-dir", "", "directory that holds native-mls-v2.db (required)")
	deviceState := flag.String("device-state", "", "native device policy chain directory (managed by cmd/native-devices); enables M3b membership enforcement — revoked or unknown devices get 403 on every POST. Required with -access-mode required")
	accessMode := flag.String("access-mode", accessModeRequired, "required: verify a CF Access JWT on every contract route and bind it to the device subject; disabled: local dev only, no caller authentication")
	accessIssuer := flag.String("access-issuer", "", "expected JWT iss (the CF Access team domain, e.g. https://<team>.cloudflareaccess.com)")
	accessAudience := flag.String("access-audience", "", "expected JWT aud (the CF Access application AUD tag)")
	accessJWKS := flag.String("access-jwks", "", "JWKS source: a local file path or an https URL (CF Access: <issuer>/cdn-cgi/access/certs)")
	roomBytesCap := flag.Int64("room-bytes-cap", 0, "override per-room event byte cap (bytes)")
	keyPackagesMax := flag.Int("key-packages-max", 0, "override live key packages per device")
	keyPackageTTL := flag.Int64("key-package-ttl-seconds", 0, "override key package TTL (seconds)")
	keepEpochs := flag.Int64("commit-welcome-keep-epochs", 0, "override commit/welcome epoch retention")
	appEventTTL := flag.Int64("app-event-ttl-seconds", 0, "override application event TTL (seconds)")
	resetRoomName := flag.String("reset-room", "", "OFFLINE operator recovery (review H3: squatted or mistaken room bootstrap): delete every relay row of this room from -data-dir and exit. Refuses while a relay holds the data dir; dry run unless -yes")
	resetYes := flag.Bool("yes", false, "with -reset-room: actually delete (default prints what would be deleted)")
	removedGrace := flag.Int64("removed-cursor-grace-seconds", 0, "override how long a member removed by commit keeps gating pruning before it reads its removal")
	flag.Parse()

	if *dataDir == "" {
		log.Fatal("-data-dir is required")
	}
	if *resetRoomName != "" {
		// Offline tool: no listener, no access configuration needed.
		os.Exit(runResetRoom(os.Stdout, *dataDir, *resetRoomName, *resetYes))
	}

	// C1: fail closed on the authentication configuration before touching
	// any state. Every flag of the required mode must be present.
	var access *accessVerifier
	switch *accessMode {
	case accessModeRequired:
		if *accessIssuer == "" || *accessAudience == "" || *accessJWKS == "" {
			log.Fatal("-access-mode required needs -access-issuer, -access-audience and -access-jwks (use -access-mode disabled only for local dev)")
		}
		if *deviceState == "" {
			log.Fatal("-access-mode required needs -device-state: callers are bound to device-policy subjects")
		}
		v, err := newAccessVerifier(*accessIssuer, *accessAudience, *accessJWKS)
		if err != nil {
			log.Fatalf("access verifier: %v", err)
		}
		access = v
	case accessModeDisabled:
		log.Printf("WARNING: -access-mode disabled: NO caller authentication, any client may act as any device. Local development only.")
	default:
		log.Fatalf("-access-mode must be %q or %q", accessModeRequired, accessModeDisabled)
	}

	db, err := openStore(*dataDir)
	if err != nil {
		log.Fatalf("open store: %v", err)
	}
	defer db.Close()

	// M3b: fail closed at startup — a -device-state that cannot be replayed
	// must stop the relay, not silently run unenforced.
	var devices *devicepolicy.DevicePolicyStore
	if *deviceState != "" {
		st, err := devicepolicy.OpenDevicePolicyStore(*deviceState)
		if err != nil {
			log.Fatalf("open device policy: %v", err)
		}
		info, _, err := st.Read()
		if err != nil {
			log.Fatalf("device policy chain unreadable (run cmd/native-devices -init first): %v", err)
		}
		log.Printf("device policy enforcement on (revision %d)", info.Revision)
		devices = st
	} else {
		log.Printf("WARNING: -device-state not set: membership enforcement is OFF, any device may POST")
	}

	pol := defaultPolicy()
	if *roomBytesCap > 0 {
		pol.RoomBytesCap = *roomBytesCap
	}
	if *keyPackagesMax > 0 {
		pol.KeyPackagesMaxPerDevice = *keyPackagesMax
	}
	if *keyPackageTTL > 0 {
		pol.KeyPackageTTLSeconds = *keyPackageTTL
	}
	if *keepEpochs > 0 {
		pol.CommitWelcomeKeepEpochs = *keepEpochs
	}
	if *appEventTTL > 0 {
		pol.AppEventTTLSeconds = *appEventTTL
	}
	if *removedGrace > 0 {
		pol.RemovedCursorGraceSeconds = *removedGrace
	}

	relay := &relay{db: db, policy: pol, devices: devices, access: access}
	srv := &http.Server{
		Addr:              *addr,
		Handler:           relay.routes(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	if access != nil {
		log.Printf("caller authentication on (issuer %s, jwks %s)", *accessIssuer, *accessJWKS)
	}
	log.Printf("native-mls v2 relay listening on %s (data-dir %s)", *addr, *dataDir)
	log.Fatal(srv.ListenAndServe())
}
