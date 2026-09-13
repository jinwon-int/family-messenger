//go:build synthetic_candidate

package chat

import (
	"embed"
	"io/fs"
)

//go:embed candidateassets/*
var candidateEmbedded embed.FS

func init() {
	var err error
	compiledCandidateAssets, err = fs.Sub(candidateEmbedded, "candidateassets")
	if err != nil {
		panic("compiled synthetic assets unavailable")
	}
}
