package e2eenv

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func UnsetHooks() error {
	for _, kv := range os.Environ() {
		key, _, _ := strings.Cut(kv, "=")
		if key == "ZDOTDIR" || key == "ENV" || key == "BASH_ENV" || key == "PROMPT_COMMAND" || strings.HasPrefix(key, "KIDO_ORIG_") || strings.HasPrefix(key, "BASH_FUNC_") {
			if err := os.Unsetenv(key); err != nil {
				return err
			}
		}
	}
	return nil
}

func Private() (home string, err error) {
	if home, err = os.MkdirTemp("/tmp", "kido-e2e-home-"); err != nil {
		return "", err
	}
	defer func() {
		if err != nil {
			os.RemoveAll(home)
			home = ""
		}
	}()
	goenv, err := exec.Command("go", "env", "-json", "GOCACHE", "GOPATH").Output()
	if err != nil {
		return
	}
	var caches map[string]string
	if err = json.Unmarshal(goenv, &caches); err != nil {
		return
	}
	for key, value := range caches {
		if err = os.Setenv(key, value); err != nil {
			return
		}
	}
	for _, key := range []string{"HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME"} {
		if err = os.Setenv(key, filepath.Join(home, key)); err != nil {
			return
		}
		if err = os.MkdirAll(os.Getenv(key), 0700); err != nil {
			return
		}
	}
	err = os.WriteFile(filepath.Join(os.Getenv("HOME"), ".zshrc"), nil, 0600)
	return
}
