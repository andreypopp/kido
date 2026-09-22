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

// Extensions is the whole set, and setup-pi installs all of it. They are
// two files because they are two jobs: kido-status.ts reports this
// session's status and owns the inbox socket, and kido-agents.ts carries
// agent coordination - the tools, envelope dispatch, subagents. They find
// each other at load time through a slot they share in pi's process, not
// by path (see the seam note in kido-status.ts), so what matters is that
// both are installed, not where. Installing one alone is not an error:
// each degrades on its own.
var Extensions = []Extension{
	{Name: "kido-status.ts", Data: statusExtension},
	{Name: "kido-agents.ts", Data: agentsExtension},
}
