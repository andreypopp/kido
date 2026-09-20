package main

import (
	"fmt"
	"os"
	"path/filepath"

	"kido/pi"
)

// setupPi installs the pi extension into pi's user extensions directory,
// which pi discovers on startup with no further configuration. An
// existing file is backed up next to it, the way setup-claude backs up
// settings.json.
func setupPi() error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	dir := filepath.Join(home, ".pi", "agent", "extensions")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	path := filepath.Join(dir, pi.ExtensionName)
	// Writing follows a symlink, so a link pointing at a checkout would
	// have this overwrite the source it was linked to. Leave it alone:
	// whoever linked it wants their own copy to be the live one.
	if fi, err := os.Lstat(path); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		target, err := os.Readlink(path)
		if err != nil {
			return err
		}
		fmt.Printf("%s is a symlink to %s, leaving it alone\n", path, target)
		return nil
	}
	if old, err := os.ReadFile(path); err == nil {
		if err := os.WriteFile(path+".bak", old, 0o644); err != nil {
			return err
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := os.WriteFile(path, pi.Extension, 0o644); err != nil {
		return err
	}
	fmt.Printf("installed the kido status extension in %s\n", path)
	fmt.Println("restart pi to load it")
	return nil
}
