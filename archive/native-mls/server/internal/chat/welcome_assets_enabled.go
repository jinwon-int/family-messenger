//go:build synthetic_welcome

package chat

import (
	"embed"
	"io/fs"
)

//go:embed welcomeassets/*
var welcomeEmbedded embed.FS

func init() {
	var err error
	compiledWelcomeAssets, err = fs.Sub(welcomeEmbedded, "welcomeassets")
	if err != nil {
		panic("compiled synthetic assets unavailable")
	}
}
