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
	successor := flag.Bool("successor-policy", false, "explicit version-2 public intent/retirement management; never activates a candidate")
	activation := flag.Bool("activation-policy", false, "explicit persistent target enrollment authority; requires paired server consent digest")
	flag.Parse()
	modes := 0
	for _, selected := range []bool{*inspect, *fetch, *input != ""} {
		if selected {
			modes++
		}
	}
	if !*synthetic || flag.NArg() != 0 || *dir == "" || modes != 1 || ((*successor || *activation) && *input == "") || (*successor && *activation) {
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
			if *activation {
				info, e = s.CommitActivation(*expected, c)
			} else if *successor {
				info, e = s.CommitSuccessor(*expected, c)
			} else {
				info, e = s.Commit(*expected, c)
			}
		}
	}
	if e != nil {
		return e
	}
	return json.NewEncoder(os.Stdout).Encode(info)
}
