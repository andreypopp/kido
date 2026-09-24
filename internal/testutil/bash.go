package testutil

import (
	"os/exec"
	"sync"
	"testing"
)

// BashHasPS0 reports whether the bash at path is new enough for the PS0
// hook shell/bash/integration.bash is built on, by asking that bash its
// own version - the same question `kido ssh`'s bootstrap asks a remote's
// login shell before deciding to prime it.
func BashHasPS0(path string) bool {
	err := exec.Command(path, "-c",
		`((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4)))`).Run()
	return err == nil
}

// lookModernBash is BashHasPS0 of the bash on PATH, with the reason to
// skip when there is none. Every bash test asks, and the answer is a
// process, so it is taken once per test binary.
var lookModernBash = sync.OnceValues(func() (bash, skip string) {
	path, err := exec.LookPath("bash")
	if err != nil {
		return "", "no bash in PATH"
	}
	if !BashHasPS0(path) {
		return "", "the bash in PATH is older than 4.4, which PS0 needs"
	}
	return path, ""
})

// ModernBash returns a bash new enough for PS0, and skips the test when
// this host has none - macOS ships 3.2 as its own /bin/bash.
func ModernBash(t testing.TB) string {
	t.Helper()
	bash, skip := lookModernBash()
	if skip != "" {
		t.Skip(skip)
	}
	return bash
}
