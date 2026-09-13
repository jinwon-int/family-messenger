//go:build synthetic_vault

package chat

import (
	"embed"
	"io/fs"
)

//go:embed vaultassets/*
var vaultEmbedded embed.FS

func init() {
	var err error
	compiledVaultAssets, err = fs.Sub(vaultEmbedded, "vaultassets")
	if err != nil {
		panic("compiled synthetic assets unavailable")
	}
}
