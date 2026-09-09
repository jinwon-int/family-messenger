//go:build synthetic_history

package chat

import (
	"embed"
	"io/fs"
)

//go:embed historyassets/*
var historyEmbedded embed.FS

func init() {
	var err error
	compiledHistoryAssets, err = fs.Sub(historyEmbedded, "historyassets")
	if err != nil {
		panic("compiled synthetic assets unavailable")
	}
}
