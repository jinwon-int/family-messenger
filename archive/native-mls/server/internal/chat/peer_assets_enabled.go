//go:build synthetic_peer

package chat

import (
	"embed"
	"io/fs"
)

//go:embed peerassets/*
var peerEmbedded embed.FS

func init() {
	var err error
	compiledPeerAssets, err = fs.Sub(peerEmbedded, "peerassets")
	if err != nil {
		panic("compiled synthetic assets unavailable")
	}
}
