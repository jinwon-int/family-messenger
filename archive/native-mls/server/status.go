package main

// status-v1 (family-messenger#560, `archive/native-mls/STATUS-V1.md`): an agent
// bot posts its live "⏳ Working — 10s | Bash: …" line as ordinary application
// events whose outer client_id is `status-<uuid>` (the file-v2 convention). The
// apps show the newest one per sender as a transient bubble and drop it when the
// reply arrives. For the relay a status event is stored, cursored and retained
// like any other — but it is **never pushed**: one APNs alert every five seconds
// for the whole length of a turn would wake every member's NSE for a line that
// is replaced moments later. Only the exact shape is exempt; a client_id that
// merely starts with `status-` without the uuid tail is treated as a normal
// message (an unknown prefix is text everywhere else too).

const statusClientIDPrefix = "status-"

// isStatusClientID reports whether id is `status-<uuid v4, lowercase hex>` —
// the same shape test the apps and the bot use (`^status-[a-f0-9-]{36}$`).
func isStatusClientID(id string) bool {
	if len(id) != len(statusClientIDPrefix)+36 || id[:len(statusClientIDPrefix)] != statusClientIDPrefix {
		return false
	}
	for _, b := range []byte(id[len(statusClientIDPrefix):]) {
		switch {
		case b >= '0' && b <= '9', b >= 'a' && b <= 'f', b == '-':
		default:
			return false
		}
	}
	return true
}
