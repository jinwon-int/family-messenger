//go:build synthetic_history

package chat

import (
	"embed"
	"io/fs"
)

//go:embed historyassets_v5/*
var historyEmbedded embed.FS

func init() {
	var err error
	compiledHistoryAssets, err = fs.Sub(historyEmbedded, "historyassets_v5")
	if err != nil {
		panic("compiled synthetic assets unavailable")
	}
}
