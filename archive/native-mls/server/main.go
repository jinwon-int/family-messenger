// native-mls v2 relay entrypoint (#177 §3.4). One process owns one SQLite
// file under -data-dir; the operational server's schema 12 database is never
// touched. Flags only allow positive overrides on top of the §3.4 retention
// defaults (see policy/defaultPolicy).
package main

import (
	"flag"
	"log"
	"net/http"
	"time"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:18921", "IPv4 loopback listen address (the operational dev server owns 18920)")
	dataDir := flag.String("data-dir", "", "directory that holds native-mls-v2.db (required)")
	roomBytesCap := flag.Int64("room-bytes-cap", 0, "override per-room event byte cap (bytes)")
	keyPackagesMax := flag.Int("key-packages-max", 0, "override live key packages per device")
	keyPackageTTL := flag.Int64("key-package-ttl-seconds", 0, "override key package TTL (seconds)")
	keepEpochs := flag.Int64("commit-welcome-keep-epochs", 0, "override commit/welcome epoch retention")
	appEventTTL := flag.Int64("app-event-ttl-seconds", 0, "override application event TTL (seconds)")
	flag.Parse()

	if *dataDir == "" {
		log.Fatal("-data-dir is required")
	}
	db, err := openStore(*dataDir)
	if err != nil {
		log.Fatalf("open store: %v", err)
	}
	defer db.Close()

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

	relay := &relay{db: db, policy: pol}
	srv := &http.Server{
		Addr:              *addr,
		Handler:           relay.routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("native-mls v2 relay listening on %s (data-dir %s)", *addr, *dataDir)
	log.Fatal(srv.ListenAndServe())
}
