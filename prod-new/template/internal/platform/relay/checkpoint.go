package relay

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// FileCheckpoints is a durable CheckpointStore backed by one small JSON file.
//
// Writes are atomic: the file is rewritten to a temporary path in the same
// directory and renamed over the target. rename(2) within a filesystem is
// atomic, so a crash mid-write leaves either the previous checkpoint or the
// new one and never a truncated file. A torn checkpoint would be read as a
// position of zero on the next boot, republishing the entire log — the
// failure this costs two extra syscalls to rule out.
//
// The directory is fsynced after the rename. Without that, the rename itself
// can be lost in a machine crash even though the data file was durable, which
// is the classic and invisible half of atomic-replace.
type FileCheckpoints struct {
	mu   sync.Mutex
	path string
	pos  map[string]int64
}

// OpenCheckpoints opens (creating if absent) the checkpoint file at path.
//
// A missing file is NOT an error: a service that has never relayed has every
// position at zero, which is exactly what an empty map yields. A file that
// exists but cannot be parsed IS an error — silently treating corruption as
// "start from zero" would republish all of history under the guise of a clean
// boot.
func OpenCheckpoints(path string) (*FileCheckpoints, error) {
	c := &FileCheckpoints{path: path, pos: map[string]int64{}}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return c, nil
		}
		return nil, fmt.Errorf("relay: reading checkpoints %s: %w", path, err)
	}
	if len(strings.TrimSpace(string(data))) == 0 {
		return c, nil
	}
	if err := json.Unmarshal(data, &c.pos); err != nil {
		return nil, fmt.Errorf("relay: checkpoints %s are corrupt (refusing to treat this as position zero, "+
			"which would republish the entire log): %w", path, err)
	}
	return c, nil
}

// Get returns the stored position for name, or 0 when it has none.
func (c *FileCheckpoints) Get(_ context.Context, name string) (int64, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.pos[name], nil
}

// Set durably records the position for name.
//
// It refuses to move a checkpoint BACKWARDS. A relay only ever advances, so a
// lower position means a caller bug or a stale in-memory view, and honouring
// it would silently republish everything in between.
func (c *FileCheckpoints) Set(_ context.Context, name string, position int64) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if cur, ok := c.pos[name]; ok && position < cur {
		return fmt.Errorf("relay: refusing to move checkpoint %q backwards from %d to %d", name, cur, position)
	}
	prev, had := c.pos[name]
	c.pos[name] = position
	if err := c.writeLocked(); err != nil {
		// Roll the in-memory view back so it never claims a durability the
		// disk does not have. A relay that believes it checkpointed will not
		// republish, and the events between here and the real position would
		// be lost on the next boot.
		if had {
			c.pos[name] = prev
		} else {
			delete(c.pos, name)
		}
		return err
	}
	return nil
}

func (c *FileCheckpoints) writeLocked() error {
	data, err := json.Marshal(c.pos)
	if err != nil {
		return fmt.Errorf("relay: encoding checkpoints: %w", err)
	}
	dir := filepath.Dir(c.path)
	tmp, err := os.CreateTemp(dir, ".checkpoints-*")
	if err != nil {
		return fmt.Errorf("relay: creating temp checkpoint in %s: %w", dir, err)
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }() // no-op once the rename succeeded

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("relay: writing temp checkpoint: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("relay: syncing temp checkpoint: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("relay: closing temp checkpoint: %w", err)
	}
	if err := os.Rename(tmpName, c.path); err != nil {
		return fmt.Errorf("relay: renaming checkpoint into place: %w", err)
	}
	// Fsync the DIRECTORY, not just the file. The rename is metadata; without
	// this it can be lost in a machine crash while the file contents were
	// already durable, leaving the old checkpoint in place with no sign that
	// anything went wrong.
	d, err := os.Open(dir)
	if err != nil {
		return fmt.Errorf("relay: opening dir to sync rename: %w", err)
	}
	defer func() { _ = d.Close() }()
	if err := d.Sync(); err != nil {
		return fmt.Errorf("relay: syncing dir after rename: %w", err)
	}
	return nil
}
