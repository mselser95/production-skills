// Package idem remembers the response to an idempotency key for a limited time
// so a retried request gets the original answer.
package idem

import (
	"sync"
	"time"
)

type entry struct {
	val     []byte
	expires time.Time
}

// Cache maps idempotency keys to stored responses. The zero value is not
// usable; build one with New.
type Cache struct {
	mu      sync.Mutex
	now     func() time.Time
	ttl     time.Duration
	entries map[string]entry
}

// New returns a Cache whose entries live for ttl. now is the clock; nil means
// time.Now.
func New(ttl time.Duration, now func() time.Time) *Cache {
	if now == nil {
		now = time.Now
	}
	return &Cache{now: now, ttl: ttl, entries: map[string]entry{}}
}

// Put stores val under key for the cache's default ttl.
func (c *Cache) Put(key string, val []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries[key] = entry{val: val, expires: c.now().Add(c.ttl)}
}

// Get returns the stored response for key, or false if there is none or it has
// expired. An expired entry is dropped.
func (c *Cache) Get(key string) ([]byte, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.entries[key]
	if !ok {
		return nil, false
	}
	if !c.now().Before(e.expires) {
		delete(c.entries, key)
		return nil, false
	}
	return e.val, true
}

// Len reports how many entries are held, expired ones included.
func (c *Cache) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.entries)
}
