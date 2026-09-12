//go:build synthetic_confirmation

package chat

import (
	"embed"
	"io/fs"
)

//go:embed confirmationassets/*
var confirmationEmbedded embed.FS

func init() {
	var err error
	compiledConfirmationAssets, err = fs.Sub(confirmationEmbedded, "confirmationassets")
	if err != nil {
		panic("compiled synthetic assets unavailable")
	}
}
