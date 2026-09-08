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
	flag.Parse()
	if !*synthetic || flag.NArg() != 0 {
		return fmt.Errorf("requires --synthetic-only and no positional arguments")
	}
	host, port, e := net.SplitHostPort(*addr)
	if e != nil || host != "127.0.0.1" || port == "" {
		return fmt.Errorf("only 127.0.0.1 is supported")
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
	server := &http.Server{Handler: chat.NewHandler(store), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 5 * time.Second, IdleTimeout: 15 * time.Second, MaxHeaderBytes: 8192, BaseContext: func(net.Listener) context.Context { return ctx }}
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	fmt.Fprintln(os.Stderr, "SYNTHETIC ONLY; public test identities; no E2EE; listening", listener.Addr())
	select {
	case e = <-done:
		if e == http.ErrServerClosed {
			return nil
		}
		return e
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if e = server.Shutdown(shutdown); e != nil {
		server.Close()
		return e
	}
	return nil
}
