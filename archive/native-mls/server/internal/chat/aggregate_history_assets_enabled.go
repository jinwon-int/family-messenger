//go:build synthetic_aggregate_history

package chat

import (
	"embed"
	"io/fs"
)

//go:embed aggregatehistoryassets/*
var aggregateHistoryEmbedded embed.FS

func init() {
	var err error
	compiledAggregateHistoryAssets, err = fs.Sub(aggregateHistoryEmbedded, "aggregatehistoryassets")
	if err != nil {
		panic("compiled synthetic assets unavailable")
	}
}
