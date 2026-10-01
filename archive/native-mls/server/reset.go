package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// roomCounts is what -reset-room would delete (or deleted) for one room.
type roomCounts struct {
	Rooms, Events, KeyPackages, Members, Cursors int64
}

func (c roomCounts) total() int64 {
	return c.Rooms + c.Events + c.KeyPackages + c.Members + c.Cursors
}

// resetTables are every table keyed by room. mls_rooms goes last so a crash
// mid-way (impossible inside one transaction, but cheap to keep) never
// leaves rows without their room.
var resetTables = []string{"mls_events", "mls_keypackages", "mls_members", "mls_cursors", "mls_rooms"}

// resetRoom is the offline operator recovery for review H3: room names are
// first-come among authenticated devices, so a squatted name or a mistaken
// bootstrap commit is repaired by deleting that one room's rows. It takes the
// same exclusive data-dir lock as the relay (errStoreLocked while a relay
// runs), refuses to create a database that does not exist, counts first, and
// deletes in one transaction only when confirm is set. Clients that still
// hold MLS state for the room must start a new group: the relay forgets the
// room's order, epoch, members and cursors entirely.
func resetRoom(dataDir, room string, confirm bool) (roomCounts, error) {
	if room == "" {
		return roomCounts{}, errors.New("room name is required")
	}
	if _, err := os.Stat(filepath.Join(dataDir, storeFile)); err != nil {
		return roomCounts{}, fmt.Errorf("no relay database in %s: %w", dataDir, err)
	}
	st, err := openStore(dataDir)
	if err != nil {
		return roomCounts{}, err
	}
	defer st.Close()
	tx, err := st.Begin()
	if err != nil {
		return roomCounts{}, err
	}
	defer tx.Rollback()
	var c roomCounts
	dst := map[string]*int64{
		"mls_rooms": &c.Rooms, "mls_events": &c.Events, "mls_keypackages": &c.KeyPackages,
		"mls_members": &c.Members, "mls_cursors": &c.Cursors,
	}
	for _, table := range resetTables {
		if err := tx.QueryRow(`SELECT COUNT(*) FROM `+table+` WHERE room = ?`, room).Scan(dst[table]); err != nil {
			return roomCounts{}, fmt.Errorf("count %s: %w", table, err)
		}
	}
	if !confirm || c.total() == 0 {
		return c, nil
	}
	for _, table := range resetTables {
		if _, err := tx.Exec(`DELETE FROM `+table+` WHERE room = ?`, room); err != nil {
			return roomCounts{}, fmt.Errorf("delete %s: %w", table, err)
		}
	}
	return c, tx.Commit()
}

// runResetRoom is the -reset-room CLI: prints the plan, deletes only with
// -yes. Exit codes: 0 done (or nothing to delete), 1 error (including a live
// relay holding the lock), 2 dry run (re-run with -yes).
func runResetRoom(out io.Writer, dataDir, room string, confirm bool) int {
	c, err := resetRoom(dataDir, room, confirm)
	if err != nil {
		fmt.Fprintf(out, "reset-room %q: %v\n", room, err)
		return 1
	}
	fmt.Fprintf(out, "room %q: rooms=%d events=%d key_packages=%d members=%d cursors=%d\n",
		room, c.Rooms, c.Events, c.KeyPackages, c.Members, c.Cursors)
	switch {
	case c.total() == 0:
		fmt.Fprintln(out, "nothing to delete")
		return 0
	case !confirm:
		fmt.Fprintln(out, "dry run: nothing deleted; re-run with -yes to delete these rows (clients must start a new MLS group for this room)")
		return 2
	default:
		fmt.Fprintln(out, "deleted")
		return 0
	}
}
