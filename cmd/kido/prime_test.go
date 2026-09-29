package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestBashHasPS0 pins the version floor both sides of the priming
// decision read: 4.4 is where PS0 arrived, and Apple ships 3.2. Anything
// that does not parse is not primed, because a bash left in posix mode
// for the life of the session is a worse outcome than no markers.
func TestBashHasPS0(t *testing.T) {
	cases := map[string]bool{
		"5.2\n": true, "4.4\n": true, "4.4": true, "10.0\n": true,
		"4.3\n": false, "3.2\n": false, "\n": false, ".\n": false,
		"x.y\n": false, "": false,
	}
	for in, want := range cases {
		if got := bashHasPS0(in); got != want {
			t.Errorf("bashHasPS0(%q) = %v, want %v", in, got, want)
		}
	}
}

// TestLocalPrimeModeIgnoresUnknownShells: a login shell kido does not
// know by basename gets primePlain with neither gate consulted, so this
// is safe to check against paths that do not exist on disk.
func TestLocalPrimeModeIgnoresUnknownShells(t *testing.T) {
	for _, path := range []string{"/bin/sh", "/usr/bin/fish", "/bin/ksh"} {
		if got := localPrimeMode(path); got != primePlain {
			t.Errorf("localPrimeMode(%q) = %v, want primePlain", path, got)
		}
	}
}

// TestPrimeLocalWritesAThrowawayDirectory pins what each mode's priming
// hands the shell: a directory that is not the user's, holding the
// startup file and the integration, named by the one variable that shell
// reads.
func TestPrimeLocalWritesAThrowawayDirectory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("ZDOTDIR", "")
	os.Unsetenv("ZDOTDIR")

	t.Run("zsh", func(t *testing.T) {
		env, err := primeLocal(primeZsh, "")
		if err != nil {
			t.Fatal(err)
		}
		dir := valueOf(t, env, "ZDOTDIR")
		if dir == home {
			t.Fatal("ZDOTDIR is the user's home directory; kido must never write there")
		}
		for _, name := range []string{zshEnvFile, zshIntegrationFile} {
			if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
				t.Errorf("%s: %v", name, err)
			}
		}
		if has(env, "KIDO_ORIG_ZDOTDIR") {
			t.Error("a session with no ZDOTDIR of its own was given one to restore")
		}
	})

	t.Run("zsh with a ZDOTDIR of its own", func(t *testing.T) {
		dots := t.TempDir()
		t.Setenv("ZDOTDIR", dots)
		env, err := primeLocal(primeZsh, "")
		if err != nil {
			t.Fatal(err)
		}
		if got := valueOf(t, env, "ZDOTDIR"); got == dots {
			t.Error("ZDOTDIR was left pointing at the user's own dotfiles, so nothing is primed")
		}
		if got := valueOf(t, env, "KIDO_ORIG_ZDOTDIR"); got != dots {
			t.Errorf("KIDO_ORIG_ZDOTDIR = %q, want %q: the session would lose its dotfiles", got, dots)
		}
	})

	t.Run("bash", func(t *testing.T) {
		env, err := primeLocal(primeBash, "")
		if err != nil {
			t.Fatal(err)
		}
		envFile := valueOf(t, env, "ENV")
		if filepath.Base(envFile) != bashEnvFile {
			t.Errorf("ENV = %q, want a %s", envFile, bashEnvFile)
		}
		for _, name := range []string{bashEnvFile, bashIntegrationFile} {
			if _, err := os.Stat(filepath.Join(filepath.Dir(envFile), name)); err != nil {
				t.Errorf("%s: %v", name, err)
			}
		}
	})

	t.Run("plain", func(t *testing.T) {
		env, err := primeLocal(primePlain, "")
		if err != nil || env != nil {
			t.Errorf("primeLocal(primePlain) = %v, %v, want nothing at all", env, err)
		}
	})
}

// has reports whether env holds an assignment to name.
func has(env []string, name string) bool {
	for _, kv := range env {
		if strings.HasPrefix(kv, name+"=") {
			return true
		}
	}
	return false
}

// valueOf reads name out of an environment slice.
func valueOf(t *testing.T, env []string, name string) string {
	t.Helper()
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, name+"="); ok {
			return v
		}
	}
	t.Fatalf("environment %q names no %s", env, name)
	return ""
}

// TestLocalPrimeModeLeavesAFirstLoginAlone: a zsh with no dotfiles at
// all is about to be offered zsh-newuser-install, and a ZDOTDIR pointing
// at kido's directory would suppress it. The positive half is the same
// home with one .zshrc in it.
func TestLocalPrimeModeLeavesAFirstLoginAlone(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	os.Unsetenv("ZDOTDIR")
	zsh := filepath.Join(t.TempDir(), "zsh")
	if err := os.WriteFile(zsh, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	if got := localPrimeMode(zsh); got != primePlain {
		t.Errorf("localPrimeMode = %v for a zsh with no dotfiles, want it left alone", got)
	}
	if err := os.WriteFile(filepath.Join(home, ".zshrc"), []byte("\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := localPrimeMode(zsh); got != primeZsh {
		t.Errorf("localPrimeMode = %v for a zsh with dotfiles, want it primed", got)
	}
}

// TestLocalPrimeModeAsksBashItsVersion pins that the floor is read from
// the shell that is about to be run, not from the one kido is running
// under: a stand-in answering 3.2 is left alone and one answering 5.2 is
// primed, with nothing else about them different.
func TestLocalPrimeModeAsksBashItsVersion(t *testing.T) {
	for _, version := range []string{"3.2", "5.2"} {
		bash := filepath.Join(t.TempDir(), "bash")
		body := "#!/bin/sh\necho " + version + "\n"
		if err := os.WriteFile(bash, []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
		want := primeBash
		if version == "3.2" {
			want = primePlain
		}
		if got := localPrimeMode(bash); got != want {
			t.Errorf("localPrimeMode for a bash %s = %v, want %v", version, got, want)
		}
	}
}
