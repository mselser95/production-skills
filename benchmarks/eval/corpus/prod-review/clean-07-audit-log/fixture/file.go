package auditlog

import "os"

// OpenFile opens path for appending, creating it if needed.
func OpenFile(path string) (*Log, error) {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	return New(f), nil
}
