//go:build synthetic_aggregate

package chat

import (
	"embed"
	"io/fs"
)

//go:embed aggregateassets/*
var aggregateEmbedded embed.FS

func init() {
	var err error
	compiledAggregateAssets, err = fs.Sub(aggregateEmbedded, "aggregateassets")
	if err != nil {
		panic("compiled synthetic assets unavailable")
	}
}
