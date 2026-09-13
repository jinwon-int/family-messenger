// family-dev is a loopback-only synthetic-data prototype, not a production service.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log/slog"
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
		// Startup failures use the same JSON shape as every other record.
		newLogger(os.Stderr, slog.LevelError).Error("exit", "error", e.Error())
		os.Exit(1)
	}
}

// newLogger builds the JSON stderr logger. The timestamp key is "ts"; the
// remaining keys are slog's level/msg plus per-record attributes.
func newLogger(w io.Writer, level slog.Leveler) *slog.Logger {
	return slog.New(slog.NewJSONHandler(w, &slog.HandlerOptions{Level: level, ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
		if a.Key == slog.TimeKey {
			a.Key = "ts"
		}
		return a
	}}))
}

// applyConfigFile reads a JSON object whose keys are flag names and applies
// each string value to the flag that was not given on the command line, so
// flags always win. --synthetic-only is the operator's explicit acknowledgement
// and --config cannot nest; neither is accepted from a file.
func applyConfigFile(path string, fs *flag.FlagSet, given map[string]bool) error {
	f, e := os.Open(path)
	if e != nil {
		return e
	}
	defer f.Close()
	st, e := f.Stat()
	if e != nil {
		return e
	}
	if !st.Mode().IsRegular() || st.Size() > 64*1024 {
		return fmt.Errorf("config: %s must be a regular file under 64 KiB", path)
	}
	var raw map[string]json.RawMessage
	dec := json.NewDecoder(f)
	if e = dec.Decode(&raw); e != nil {
		return fmt.Errorf("config: %w", e)
	}
	if _, e = dec.Token(); e != io.EOF {
		return fmt.Errorf("config: trailing data after the JSON object")
	}
	for key, value := range raw {
		if key == "config" || key == "synthetic-only" || fs.Lookup(key) == nil {
			return fmt.Errorf("config: key %q is not accepted in a file", key)
		}
		if given[key] {
			continue
		}
		var text string
		if e = json.Unmarshal(value, &text); e != nil {
			return fmt.Errorf("config: %s must be a JSON string", key)
		}
		if e = fs.Set(key, text); e != nil {
			return fmt.Errorf("config: %s: %w", key, e)
		}
		given[key] = true
	}
	return nil
}

func run() error {
	dir := flag.String("state", "", "existing absolute mode-0700 directory for synthetic data")
	addr := flag.String("listen", "127.0.0.1:18920", "IPv4 loopback listen address")
	synthetic := flag.Bool("synthetic-only", false, "acknowledge synthetic test data only; not production-ready")
	authState := flag.String("auth-state", "", "explicit private signed synthetic auth state; no fixture fallback")
	admissionKeyPath := flag.String("admission-key", "", "private 32-byte Ed25519 admission seed file (0600); enables /v1/aggregate/* only when the signed policy pins the matching key")
	configPath := flag.String("config", "", "JSON object of flag-name keys (state, listen, auth-state, admission-key, log-level); command-line flags override it")
	logLevel := flag.String("log-level", "info", "log level for JSON records on stderr: debug, info, warn or error")
	// The --synthetic-*-ui flags (compiled MLS/custody/successor test UIs) were
	// removed with the native MLS freeze; see archive/native-mls/README.md.
	flag.Parse()
	given := map[string]bool{}
	flag.Visit(func(f *flag.Flag) { given[f.Name] = true })
	if !*synthetic || flag.NArg() != 0 {
		return fmt.Errorf("requires --synthetic-only and no positional arguments")
	}
	if *configPath != "" {
		if e := applyConfigFile(*configPath, flag.CommandLine, given); e != nil {
			return e
		}
	}
	var level slog.Level
	if e := level.UnmarshalText([]byte(*logLevel)); e != nil {
		return fmt.Errorf("--log-level: %w", e)
	}
	log := newLogger(os.Stderr, level)
	chat.SetLogger(log)
	host, port, e := net.SplitHostPort(*addr)
	if e != nil || host != "127.0.0.1" || port == "" {
		return fmt.Errorf("only 127.0.0.1 is supported")
	}
	var managed *access.Managed
	if given["auth-state"] {
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
		handler, e = chat.NewAccessHandler(store, managed.Authority, admission)
		if e != nil {
			return e
		}
	}
	handler = chat.Logged(handler)
	server := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 5 * time.Second, IdleTimeout: 15 * time.Second, MaxHeaderBytes: 8192, BaseContext: func(net.Listener) context.Context { return ctx }}
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	mode := "public test identities"
	var last access.PolicyInfo
	healthy := true
	if managed != nil {
		mode = "signed synthetic identities"
		last, healthy = managed.Status()
		log.Info("auth revision applied", "revision", last.Revision, "sha256", last.SHA256, "healthy", healthy)
	}
	cryptoMode := "legacy plaintext test UI"
	// The smoke tests locate the port by matching "listening <addr>" in the
	// message text; keep that phrase intact and only here.
	log.Info("SYNTHETIC ONLY; listening "+listener.Addr().String(), "mode", mode, "ui", cryptoMode, "addr", listener.Addr().String(), "log_level", level.String())
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
					log.Warn("auth policy unavailable; access suspended", "error", refreshErr.Error(), "revision", info.Revision)
				}
			} else if !healthy || info != last {
				log.Info("auth revision applied", "revision", info.Revision, "sha256", info.SHA256, "healthy", ok)
			}
			last, healthy = info, ok
		}
	}
	log.Info("shutting down")
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if e = server.Shutdown(shutdown); e != nil {
		server.Close()
		return e
	}
	return nil
}
