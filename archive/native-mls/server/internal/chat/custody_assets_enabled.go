//go:build synthetic_custody

package chat

import (
	"embed"
	"io/fs"
)

//go:embed custodyassets/*
var custodyEmbedded embed.FS

func init() {
	var err error
	compiledCustodyAssets, err = fs.Sub(custodyEmbedded, "custodyassets")
	if err != nil {
		panic("compiled synthetic assets unavailable")
	}
}
