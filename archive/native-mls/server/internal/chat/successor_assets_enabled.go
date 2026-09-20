//go:build synthetic_successor

package chat

import (
	"embed"
	"io/fs"
)

//go:embed successorassets/*
var successorEmbedded embed.FS

func init() {
	var err error
	compiledSuccessorAssets, err = fs.Sub(successorEmbedded, "successorassets")
	if err != nil {
		panic("compiled synthetic assets unavailable")
	}
}
