package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// blockKinds are the marked blocks the setup commands keep. The placement
// tests below run over both, because where a block lands in a file is the
// same problem whatever is in it.
var blockKinds = []struct {
	name       string
	begin, end string
	block      func(source string) string
	other      string // a plausible second path, for the rewrite cases
}{
	{
		name:  "zsh",
		begin: zshrcBegin,
		end:   zshrcEnd,
		block: zshrcBlock,
		other: "/opt/homebrew/share/kido/shell/zsh/integration.zsh",
	},
	{
		name:  "tmux",
		begin: tmuxConfBegin,
		end:   tmuxConfEnd,
		block: func(source string) string {
			b, err := tmuxConfBlock(source)
			if err != nil {
				panic(err)
			}
			return b
		},
		other: "/opt/homebrew/share/kido/kido-side.tmux",
	},
}

// TestSetMarkedBlock covers the config edit for every marker set: a
// missing file, one without the block, one that already has it at the same
// path (left alone), one that has it at a different path (rewritten in
// place rather than duplicated), one where the block sits in the middle of
// the file, and one that does not end in a newline.
func TestSetMarkedBlock(t *testing.T) {
	for _, k := range blockKinds {
		t.Run(k.name, func(t *testing.T) {
			path := "/home/u/.local/share/kido/shipped"
			block := k.block
			cases := []struct {
				name   string
				rc     string
				want   string
				action string
			}{
				{
					name:   "no file",
					rc:     "",
					want:   block(path),
					action: "added",
				},
				{
					name:   "existing rc",
					rc:     "set -g mouse on\n",
					want:   "set -g mouse on\n\n" + block(path),
					action: "added",
				},
				{
					name:   "no trailing newline",
					rc:     "set -g mouse on",
					want:   "set -g mouse on\n\n" + block(path),
					action: "added",
				},
				{
					name:   "same path",
					rc:     "set -g mouse on\n\n" + block(path),
					want:   "set -g mouse on\n\n" + block(path),
					action: "unchanged",
				},
				{
					name:   "other path",
					rc:     "set -g mouse on\n\n" + block(k.other),
					want:   "set -g mouse on\n\n" + block(path),
					action: "updated",
				},
				{
					name:   "block in the middle",
					rc:     "before\n" + block("/old/shipped") + "after\n",
					want:   "before\n" + block(path) + "after\n",
					action: "updated",
				},
			}
			for _, c := range cases {
				t.Run(c.name, func(t *testing.T) {
					out, action, err := setMarkedBlock([]byte(c.rc), k.begin, k.end, block(path))
					if err != nil {
						t.Fatal(err)
					}
					if action != c.action {
						t.Errorf("action = %q, want %q", action, c.action)
					}
					if string(out) != c.want {
						t.Errorf("rc =\n%q\nwant\n%q", out, c.want)
					}
					if n := strings.Count(string(out), k.begin); n != 1 {
						t.Errorf("%d begin markers, want 1", n)
					}
				})
			}
		})
	}
}

// TestSetMarkedBlockBroken checks that a half-edited block is an error
// rather than a guess: kido would otherwise have to decide where somebody
// else's hand-edit ends.
func TestSetMarkedBlockBroken(t *testing.T) {
	for _, k := range blockKinds {
		t.Run(k.name, func(t *testing.T) {
			for _, rc := range []string{
				k.begin + "\nsource /x\n",
				"source /x\n" + k.end + "\n",
				k.end + "\nsource /x\n" + k.begin + "\n",
			} {
				if _, _, err := setMarkedBlock([]byte(rc), k.begin, k.end, k.block("/x")); err == nil {
					t.Errorf("setMarkedBlock(%q) = nil error, want one", rc)
				}
			}
		})
	}
}

// shipped are the files kido installs under share/kido, by the relative
// path findShared is asked for.
var shipped = []string{"shell/zsh/integration.zsh", "kido-side.tmux"}

// TestFindShared checks the one layout kido looks in: the file under
// <prefix>/share/kido next to <prefix>/bin/kido, found through a symlinked
// binary the way a Homebrew install is, and a clear failure when a prefix
// has nothing in it.
func TestFindShared(t *testing.T) {
	for _, rel := range shipped {
		t.Run(rel, func(t *testing.T) {
			prefix := t.TempDir()
			file := filepath.Join(prefix, "share", "kido", filepath.FromSlash(rel))
			for _, dir := range []string{filepath.Dir(file), filepath.Join(prefix, "bin")} {
				if err := os.MkdirAll(dir, 0o755); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.WriteFile(file, []byte("# shipped\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			exe := filepath.Join(prefix, "bin", "kido")
			if err := os.WriteFile(exe, nil, 0o755); err != nil {
				t.Fatal(err)
			}

			got, err := findShared(exe, rel)
			if err != nil {
				t.Fatal(err)
			}
			// The path is returned as spelled, not resolved: it is what
			// goes into the config, and the unresolved spelling is the
			// stable one.
			if got != file {
				t.Errorf("findShared = %q, want %q", got, file)
			}

			// The same binary reached through a symlink in a prefix with
			// no share of its own: nothing is found beside the link, so
			// the resolved location is the fallback that answers.
			link := filepath.Join(t.TempDir(), "kido")
			if err := os.Symlink(exe, link); err != nil {
				t.Fatal(err)
			}
			resolved, err := filepath.EvalSymlinks(file)
			if err != nil {
				t.Fatal(err)
			}
			if got, err := findShared(link, rel); err != nil || got != resolved {
				t.Errorf("findShared(symlink) = %q, %v; want %q, nil", got, err, resolved)
			}

			// A prefix with nothing in it fails, naming the path.
			bare := filepath.Join(t.TempDir(), "bin")
			if err := os.MkdirAll(bare, 0o755); err != nil {
				t.Fatal(err)
			}
			_, err = findShared(filepath.Join(bare, "kido"), rel)
			if err == nil {
				t.Fatal("findShared in an empty prefix = nil error, want one")
			}
			want := filepath.Join(filepath.Dir(bare), "share", "kido", filepath.FromSlash(rel))
			if !strings.Contains(err.Error(), want) {
				t.Errorf("error %q does not name the path %q it looked at", err, want)
			}
		})
	}
}

// TestFindSharedPrefersUnresolved pins the ordering that keeps the config
// line working across a Homebrew upgrade: bin/kido and share/kido are both
// symlinks into a versioned directory, and only the unresolved spelling
// survives brew repointing them.
func TestFindSharedPrefersUnresolved(t *testing.T) {
	root := t.TempDir()
	versioned := filepath.Join(root, "Cellar", "kido", "1.0.0")
	dir := filepath.Join(versioned, "share", "kido", "shell", "zsh")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(versioned, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(versioned, "bin", "kido"), nil, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, rel := range shipped {
		p := filepath.Join(versioned, "share", "kido", filepath.FromSlash(rel))
		if err := os.WriteFile(p, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// The stable prefix: bin/kido and share/kido both link into the
	// versioned directory, the way brew links a formula.
	if err := os.MkdirAll(filepath.Join(root, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(versioned, "bin", "kido"), filepath.Join(root, "bin", "kido")); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "share"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(versioned, "share", "kido"), filepath.Join(root, "share", "kido")); err != nil {
		t.Fatal(err)
	}

	for _, rel := range shipped {
		got, err := findShared(filepath.Join(root, "bin", "kido"), rel)
		if err != nil {
			t.Fatal(err)
		}
		want := filepath.Join(root, "share", "kido", filepath.FromSlash(rel))
		if got != want {
			t.Errorf("findShared = %q, want the version-stable %q", got, want)
		}
	}
}

// A Homebrew-shaped install: bin/kido and share/kido are symlinks the
// package manager repoints on upgrade, and the versioned directory they
// point at is what `brew cleanup` later deletes. invokedPath has to keep
// the prefix spelling, so findShared resolves through the symlinks that
// survive.
func TestInvokedPathKeepsThePrefixSpelling(t *testing.T) {
	root := t.TempDir()
	versioned := filepath.Join(root, "Cellar", "kido", "HEAD-abc1234")
	if err := os.MkdirAll(filepath.Join(versioned, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(versioned, "share", "kido", "shell", "zsh", "integration.zsh")
	if err := os.MkdirAll(filepath.Dir(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(script, []byte("# integration\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	realBin := filepath.Join(versioned, "bin", "kido")
	if err := os.WriteFile(realBin, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	prefix := filepath.Join(root, "prefix")
	if err := os.MkdirAll(filepath.Join(prefix, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	prefixBin := filepath.Join(prefix, "bin", "kido")
	if err := os.Symlink(realBin, prefixBin); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(prefix, "share"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(versioned, "share", "kido"), filepath.Join(prefix, "share", "kido")); err != nil {
		t.Fatal(err)
	}

	got, err := invokedPath(prefixBin)
	if err != nil {
		t.Fatal(err)
	}
	if got != prefixBin {
		t.Fatalf("invokedPath = %q, want the unresolved %q", got, prefixBin)
	}

	// The whole point: what lands in ~/.zshrc goes through the prefix,
	// not the versioned directory a cleanup removes.
	found, err := findShared(got, "shell/zsh/integration.zsh")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(found, "Cellar") {
		t.Errorf("findShared = %q, want a path that avoids the versioned directory", found)
	}
}

// argv[0] with no separator is a PATH lookup, and that must not resolve
// symlinks either.
func TestInvokedPathLooksUpABareName(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "real-kido")
	if err := os.WriteFile(target, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "kido-under-test")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)

	got, err := invokedPath("kido-under-test")
	if err != nil {
		t.Fatal(err)
	}
	if got != link {
		t.Errorf("invokedPath = %q, want the unresolved %q", got, link)
	}
}

// Nothing usable in argv[0] falls back to os.Executable rather than
// failing: the test binary's own path.
func TestInvokedPathFallsBackToExecutable(t *testing.T) {
	want, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	got, err := invokedPath("")
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Errorf("invokedPath = %q, want %q", got, want)
	}
}

// runRCBlock runs one generated rc block through the shell at sh, and
// returns what it wrote to stdout and to stderr. The block is the whole
// program: a shell that cannot parse it fails the run.
func runRCBlock(t *testing.T, sh, block string) (out, errs string) {
	t.Helper()
	var o, e strings.Builder
	cmd := exec.Command(sh, "-c", block)
	cmd.Stdout, cmd.Stderr = &o, &e
	if err := cmd.Run(); err != nil {
		t.Fatalf("%s: %v (stderr %q)", sh, err, e.String())
	}
	return o.String(), e.String()
}

// rcBlockRuns is what every generated rc block promises, checked against
// the real shell that reads it: it parses, it sources a script that is
// there and says nothing else, and a missing one produces kido's own
// message on stderr - naming the file and the setup command that writes
// it - rather than the shell's error, which is the whole point of the
// guard. print is a line of that shell printing "sourced", and setup the
// subcommand the message must name. It returns the script it wrote, for
// a caller with more to ask of the same block.
func rcBlockRuns(t *testing.T, shell string, block func(source string) string, print, setup string) string {
	t.Helper()
	sh, err := exec.LookPath(shell)
	if err != nil {
		t.Skipf("no %s in PATH", shell)
	}
	dir := t.TempDir()
	script := filepath.Join(dir, "integration."+shell)
	if err := os.WriteFile(script, []byte(print), 0o644); err != nil {
		t.Fatal(err)
	}

	out, errs := runRCBlock(t, sh, block(script))
	if strings.TrimSpace(out) != "sourced" {
		t.Errorf("stdout = %q, want the script to have been sourced", out)
	}
	if errs != "" {
		t.Errorf("stderr = %q, want nothing", errs)
	}

	missing := filepath.Join(dir, "gone."+shell)
	out, errs = runRCBlock(t, sh, block(missing))
	if out != "" {
		t.Errorf("stdout = %q, want nothing", out)
	}
	if !strings.Contains(errs, missing) || !strings.Contains(errs, setup) {
		t.Errorf("stderr = %q, want it to name %q and how to fix it", errs, missing)
	}
	return script
}
