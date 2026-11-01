//go:build !darwin

package rusage

import "errors"

func Read(int) (Usage, error) {
	return Usage{}, errors.ErrUnsupported
}
