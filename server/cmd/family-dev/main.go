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
	synthetic := flag.Bool("synthetic-only", false, "acknowledge public test accounts and NO E2EE")
	authState := flag.String("auth-state", "", "explicit private signed synthetic auth state; no fixture fallback")
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
		handler, e = chat.NewAccessHandler(store, managed.Authority)
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
	fmt.Fprintln(os.Stderr, "SYNTHETIC ONLY;", mode, "; no E2EE; listening", listener.Addr())
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
