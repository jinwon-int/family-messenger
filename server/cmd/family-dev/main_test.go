package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testFlags() (*flag.FlagSet, map[string]*string) {
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	values := map[string]*string{
		"state":         fs.String("state", "", ""),
		"listen":        fs.String("listen", "127.0.0.1:18920", ""),
		"auth-state":    fs.String("auth-state", "", ""),
		"admission-key": fs.String("admission-key", "", ""),
		"log-level":     fs.String("log-level", "info", ""),
		"config":        fs.String("config", "", ""),
	}
	fs.Bool("synthetic-only", false, "")
	return fs, values
}

func writeConfig(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.json")
	if e := os.WriteFile(path, []byte(body), 0600); e != nil {
		t.Fatal(e)
	}
	return path
}

func TestConfigFileFillsOnlyFlagsNotGivenOnCommandLine(t *testing.T) {
	fs, values := testFlags()
	if e := fs.Parse([]string{"--listen", "127.0.0.1:1", "--synthetic-only"}); e != nil {
		t.Fatal(e)
	}
	given := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { given[f.Name] = true })
	path := writeConfig(t, `{"state":"/srv/state","listen":"127.0.0.1:2","log-level":"debug","auth-state":"/srv/auth"}`)
	if e := applyConfigFile(path, fs, given); e != nil {
		t.Fatal(e)
	}
	if *values["listen"] != "127.0.0.1:1" {
		t.Fatalf("command-line flag must win, got %q", *values["listen"])
	}
	if *values["state"] != "/srv/state" || *values["log-level"] != "debug" || *values["auth-state"] != "/srv/auth" {
		t.Fatalf("file values not applied: %q %q %q", *values["state"], *values["log-level"], *values["auth-state"])
	}
	if !given["auth-state"] || !given["state"] || given["admission-key"] {
		t.Fatalf("given must reflect file-selected keys: %v", given)
	}
}

func TestConfigFileRejectsUnknownGateAndNonStringKeys(t *testing.T) {
	cases := map[string]string{
		"unknown key":         `{"listen":"127.0.0.1:1","port":"1"}`,
		"synthetic-only gate": `{"synthetic-only":"true"}`,
		"nested config":       `{"config":"/etc/other.json"}`,
		"non-string value":    `{"listen":18920}`,
		"trailing data":       `{"listen":"127.0.0.1:1"} {}`,
		"not an object":       `["listen"]`,
	}
	for name, body := range cases {
		fs, _ := testFlags()
		if e := applyConfigFile(writeConfig(t, body), fs, map[string]bool{}); e == nil {
			t.Fatalf("%s must be rejected", name)
		}
	}
	fs, _ := testFlags()
	if e := applyConfigFile(t.TempDir(), fs, map[string]bool{}); e == nil {
		t.Fatal("a directory must be rejected")
	}
}

func TestLoggerWritesJSONWithTimestampKey(t *testing.T) {
	var buf bytes.Buffer
	log := newLogger(&buf, slog.LevelInfo)
	log.Debug("hidden")
	log.Info("SYNTHETIC ONLY; listening 127.0.0.1:1", "addr", "127.0.0.1:1")
	var record map[string]any
	if e := json.Unmarshal(buf.Bytes(), &record); e != nil {
		t.Fatalf("%v: %s", e, buf.String())
	}
	if record["ts"] == nil || record["level"] != "INFO" || record["addr"] != "127.0.0.1:1" || !strings.Contains(record["msg"].(string), "listening 127.0.0.1:1") {
		t.Fatalf("unexpected record: %s", buf.String())
	}
	if strings.Count(buf.String(), "\n") != 1 {
		t.Fatalf("debug record must be filtered at info: %s", buf.String())
	}
}
