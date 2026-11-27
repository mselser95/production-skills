// Package notes serves per-tenant notes over HTTP.
package notes

import "sync"

// Note is a short text owned by one tenant.
type Note struct {
	ID     string `json:"id"`
	Tenant string `json:"-"`
	Body   string `json:"body"`
}

// Store keeps notes in memory.
type Store struct {
	mu    sync.Mutex
	notes map[string]Note
}

// NewStore returns an empty Store.
func NewStore() *Store { return &Store{notes: map[string]Note{}} }

// Put creates or replaces a note.
func (s *Store) Put(n Note) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.notes[n.ID] = n
}

// Get returns the note with the given id.
func (s *Store) Get(id string) (Note, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	n, ok := s.notes[id]
	return n, ok
}

// Delete removes the note with the given id and returns it.
func (s *Store) Delete(id string) (Note, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	n, ok := s.notes[id]
	delete(s.notes, id)
	return n, ok
}
