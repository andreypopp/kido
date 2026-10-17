package e2e

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func TestSpawnToolsIncludeNotifyParent(t *testing.T) {
	t.Parallel()
	h := startPathPrefix(t, "alpha", piBinDir)
	h.liveParent("alpha", "root-e2e")
	for i, tc := range []struct {
		name, tools, want string
		noParent          bool
	}{
		{"add", "read,bash", "read,bash,notify_parent", false},
		{"present", "read,bash,notify_parent", "read,bash,notify_parent", false},
		{"default", "", "", false},
		{"no-parent", "read,bash", "read,bash", true},
	} {
		parent, caller := "", "PI_SESSION_ID=root-e2e "
		if tc.noParent {
			parent, caller = "--no-parent", ""
		}
		tools := ""
		if tc.tools != "" {
			tools = "--tools " + tc.tools
		}
		name := fmt.Sprintf("tools-%d", i)
		outFile := filepath.Join(h.dir, name+".out")
		h.sendLiteral(fmt.Sprintf("%s%s tool spawn_subagent %s --name %s --task-file %s %s -- pi > %s 2>&1",
			caller, kidoBin, parent, name, h.writeTaskFile(name), tools, outFile))
		h.sendKeys("Enter")
		fields := strings.Fields(strings.TrimSpace(h.waitFileNonEmpty(outFile)))
		if len(fields) != 3 {
			t.Fatalf("%s: spawn printed %q, want window, pane and run ids", tc.name, fields)
		}
		started := h.startCommand(fields[0])
		_, got, _ := strings.Cut(started, " --tools ")
		if got != tc.want {
			t.Errorf("%s: child's tools = %q, want %q; command = %q", tc.name, got, tc.want, started)
		}
	}
}
