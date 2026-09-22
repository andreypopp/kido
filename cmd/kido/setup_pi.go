package main

import (
	"fmt"
	"os"
	"path/filepath"

	"kido/pi"
)

// setupPi installs the pi extensions into pi's user extensions directory,
// which pi discovers on startup. An existing file is backed up next to
// it. The symlink rule is applied per file, not per set.
func setupPi() error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	dir := filepath.Join(home, ".pi", "agent", "extensions")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	for _, ext := range pi.Extensions {
		if err := installPiExtension(dir, ext); err != nil {
			return err
		}
	}
	fmt.Println("restart pi to load them")
	return nil
}

func installPiExtension(dir string, ext pi.Extension) error {
	path := filepath.Join(dir, ext.Name)
	// Writing follows a symlink, so a link pointing at a checkout would
	// overwrite the source it was linked to.
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
	if err := os.WriteFile(path, ext.Data, 0o644); err != nil {
		return err
	}
	fmt.Printf("installed the kido extension in %s\n", path)
	return nil
}
