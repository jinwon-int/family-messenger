// family-dev is a loopback-only synthetic-data prototype, not a production service.
package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jinwon-int/family-messenger/server/internal/access"
	"github.com/jinwon-int/family-messenger/server/internal/chat"
)

func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}
func run() error {
	dir := flag.String("state", "", "existing absolute mode-0700 directory for synthetic data")
	addr := flag.String("listen", "127.0.0.1:18920", "IPv4 loopback listen address")
	synthetic := flag.Bool("synthetic-only", false, "acknowledge synthetic test data only; not production-ready")
	authState := flag.String("auth-state", "", "explicit private signed synthetic auth state; no fixture fallback")
	admissionKeyPath := flag.String("admission-key", "", "private 32-byte Ed25519 admission seed file (0600); enables /v1/aggregate/* only when the signed policy pins the matching key")
	encryptedUI := flag.Bool("synthetic-mls-ui", false, "enable compiled encrypted test UI; requires signed auth-state and synthetic_mls build")
	vaultUI := flag.Bool("synthetic-vault-ui", false, "enable compiled synthetic custody UI; requires signed auth-state and synthetic_vault build")
	historyUI := flag.Bool("synthetic-history-ui", false, "enable compiled synthetic read-only recovery UI; requires signed auth-state and synthetic_history build")
	aggregateUI := flag.Bool("synthetic-aggregate-ui", false, "enable compiled synthetic two-room custody UI; requires signed auth-state and synthetic_aggregate build")
	aggregateHistoryUI := flag.Bool("synthetic-aggregate-history-ui", false, "enable compiled synthetic two-room history and custody UI; requires signed auth-state and synthetic_aggregate_history build")
	flag.Parse()
	authSelected := false
	flag.Visit(func(f *flag.Flag) {
		if f.Name == "auth-state" {
			authSelected = true
		}
	})
	if !*synthetic || flag.NArg() != 0 {
		return fmt.Errorf("requires --synthetic-only and no positional arguments")
	}
	host, port, e := net.SplitHostPort(*addr)
	if e != nil || host != "127.0.0.1" || port == "" {
		return fmt.Errorf("only 127.0.0.1 is supported")
	}
	selectedUI := 0
	for _, selected := range []bool{*encryptedUI, *vaultUI, *historyUI, *aggregateUI, *aggregateHistoryUI} {
		if selected {
			selectedUI++
		}
	}
	if selectedUI > 1 {
		return fmt.Errorf("select only one encrypted UI mode")
	}
	var bundle *chat.EncryptedAssets
	if selectedUI == 1 {
		if !authSelected || *authState == "" {
			return fmt.Errorf("encrypted UI requires explicit signed auth-state")
		}
		if *aggregateHistoryUI {
			bundle, e = chat.LoadAggregateHistoryAssets()
		} else if *aggregateUI {
			bundle, e = chat.LoadAggregateAssets()
		} else if *historyUI {
			bundle, e = chat.LoadHistoryAssets()
		} else if *vaultUI {
			bundle, e = chat.LoadVaultAssets()
		} else {
			bundle, e = chat.LoadEncryptedAssets()
		}
		if e != nil {
			return e
		}
	}
	var managed *access.Managed
	if authSelected {
		if *authState == "" {
			return fmt.Errorf("selected auth-state cannot be empty")
		}
		managed, e = access.OpenManaged(*authState)
		if e != nil {
			return e
		}
		defer managed.Close()
	}
	store, e := chat.Open(*dir)
	if e != nil {
		return e
	}
	defer store.Close()
	listener, e := net.Listen("tcp4", *addr)
	if e != nil {
		return e
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	handler := chat.NewHandler(store)
	if managed != nil {
		var admission *chat.AdmissionAuthority
		if *admissionKeyPath != "" {
			key, keyErr := chat.LoadAdmissionSeed(*admissionKeyPath)
			if keyErr != nil {
				return keyErr
			}
			admission = &chat.AdmissionAuthority{Key: key}
		}
		if selectedUI == 1 {
			handler, e = chat.NewEncryptedAccessHandler(store, managed.Authority, bundle, admission)
		} else {
			handler, e = chat.NewAccessHandler(store, managed.Authority, admission)
		}
		if e != nil {
			return e
		}
	}
	server := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 5 * time.Second, IdleTimeout: 15 * time.Second, MaxHeaderBytes: 8192, BaseContext: func(net.Listener) context.Context { return ctx }}
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	mode := "public test identities"
	var last access.PolicyInfo
	healthy := true
	if managed != nil {
		mode = "signed synthetic identities"
		last, _ = managed.Status()
		fmt.Fprintln(os.Stderr, "auth revision applied", last.Revision)
	}
	cryptoMode := "legacy plaintext test UI"
	if selectedUI == 1 {
		cryptoMode = "compiled encrypted test UI /encrypted/; no human key protection"
	}
	if *vaultUI {
		cryptoMode = "compiled synthetic custody UI /vault/; human recovery not qualified"
	}
	if *historyUI {
		cryptoMode = "compiled read-only synthetic history UI /history/; no active device recovery"
	}
	if *aggregateHistoryUI {
		bundle, e = chat.LoadAggregateHistoryAssets()
	} else if *aggregateUI {
		cryptoMode = "compiled synthetic two-room custody UI /aggregate/; human recovery not qualified"
	}
	fmt.Fprintln(os.Stderr, "SYNTHETIC ONLY;", mode, ";", cryptoMode, "; listening", listener.Addr())
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
loop:
	for {
		select {
		case e = <-done:
			if e == http.ErrServerClosed {
				return nil
			}
			return e
		case <-ctx.Done():
			break loop
		case <-tick.C:
			if managed == nil {
				continue
			}
			refreshErr := managed.Refresh()
			info, ok := managed.Status()
			if refreshErr != nil {
				if healthy {
					fmt.Fprintln(os.Stderr, "auth policy unavailable; access suspended")
				}
			} else if !healthy || info != last {
				fmt.Fprintln(os.Stderr, "auth revision applied", info.Revision)
			}
			last, healthy = info, ok
		}
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if e = server.Shutdown(shutdown); e != nil {
		server.Close()
		return e
	}
	return nil
}
