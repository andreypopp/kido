// Package pi carries the kido extensions for the pi coding agent. pi
// loads TypeScript from its extensions directory directly, so they ship
// as source and `kido setup-pi` writes them out.
package pi

import _ "embed"

//go:embed kido-status.ts
var statusExtension []byte

//go:embed kido-agents.ts
var agentsExtension []byte

// Extension is one file pi loads, under the name pi will see it by.
type Extension struct {
	Name string
	Data []byte
}

// Extensions is the whole set, and setup-pi installs all of it. The two
// find each other through a slot on globalThis, not by path, so what
// matters is that both are installed, not where; either alone degrades
// (docs/design.md, "Two extensions, and the seam between them").
var Extensions = []Extension{
	{Name: "kido-status.ts", Data: statusExtension},
	{Name: "kido-agents.ts", Data: agentsExtension},
}
