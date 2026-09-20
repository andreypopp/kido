// Package pi carries the kido status extension for the pi coding agent.
// pi loads TypeScript from its extensions directory directly, so the
// extension ships as source and `kido setup-pi` writes it out.
package pi

import _ "embed"

// Extension is the contents of kido-status.ts.
//
//go:embed kido-status.ts
var Extension []byte

// ExtensionName is the file name pi loads it as.
const ExtensionName = "kido-status.ts"
