//go:build synthetic_mls

package chat

import (
	"embed"
	"io/fs"
)

//go:embed mlsassets/*
var encryptedEmbedded embed.FS

func init() {
	var err error
	compiledEncryptedAssets, err = fs.Sub(encryptedEmbedded, "mlsassets")
	if err != nil {
		panic("compiled synthetic assets unavailable")
	}
}
