package e2e

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func TestSpawnToolsIncludeNotifyParent(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, tools, want string
		noParent          bool
	}{
		{"add", "read,bash", "read,bash,notify_parent", false},
		{"present", "read,bash,notify_parent", "read,bash,notify_parent", false},
		{"default", "", "", false},
		{"no-parent", "read,bash", "read,bash", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := startPathPrefix(t, "alpha", piBinDir)
			parent, caller := "--no-parent", ""
			if !tc.noParent {
				h.liveParent("alpha", "root-e2e")
				parent = ""
				caller = "PI_SESSION_ID=root-e2e "
			}
			tools := ""
			if tc.tools != "" {
				tools = "--tools " + tc.tools
			}
			outFile := filepath.Join(h.dir, "spawn.out")
			h.sendLiteral(fmt.Sprintf("%s%s tool spawn_subagent %s --name tools-e2e --task-file %s %s -- pi > %s 2>&1",
				caller, kidoBin, parent, h.writeTaskFile("tools-e2e"), tools, outFile))
			h.sendKeys("Enter")
			fields := strings.Fields(strings.TrimSpace(h.waitFileNonEmpty(outFile)))
			if len(fields) != 3 {
				t.Fatalf("spawn printed %q, want window, pane and run ids", fields)
			}
			started := h.startCommand(fields[0])
			_, got, _ := strings.Cut(started, " --tools ")
			if got != tc.want {
				t.Errorf("child's tools = %q, want %q; command = %q", got, tc.want, started)
			}
		})
	}
}
