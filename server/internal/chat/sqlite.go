package chat

import "net/url"

func sqliteURI(path string) string {
	u := url.URL{Scheme: "file", Path: path}
	return u.String() + "?_journal_mode=DELETE&_synchronous=FULL&_foreign_keys=on&_busy_timeout=5000&_secure_delete=on"
}
