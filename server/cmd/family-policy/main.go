// family-policy stores explicit synthetic auth policies; key acquisition is opt-in.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/jinwon-int/family-messenger/server/internal/access"
)

func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}
func run() error {
	dir := flag.String("auth-state", "", "private auth state directory")
	input := flag.String("input", "", "private immutable candidate JSON file")
	expected := flag.Uint64("expected-revision", 0, "required current revision (0 initializes)")
	fetch := flag.Bool("fetch-keys", false, "fetch trusted issuer signing keys and commit with expected revision")
	inspect := flag.Bool("inspect", false, "print revision/hash only; no identities or keys")
	synthetic := flag.Bool("synthetic-only", false, "acknowledge synthetic account configuration only")
	flag.Parse()
	modes := 0
	for _, selected := range []bool{*inspect, *fetch, *input != ""} {
		if selected {
			modes++
		}
	}
	if !*synthetic || flag.NArg() != 0 || *dir == "" || modes != 1 {
		return fmt.Errorf("requires --synthetic-only --auth-state and one of --inspect, --input or --fetch-keys")
	}
	s, e := access.OpenPolicyStore(*dir)
	if e != nil {
		return e
	}
	var info access.PolicyInfo
	if *inspect {
		info, _, e = s.Read()
	} else if *fetch {
		info, e = s.AcquireKeys(context.Background(), *expected)
	} else {
		var c access.Config
		c, e = access.ReadCandidate(*input)
		if e == nil {
			info, e = s.Commit(*expected, c)
		}
	}
	if e != nil {
		return e
	}
	return json.NewEncoder(os.Stdout).Encode(info)
}
