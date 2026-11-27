package catalog

import (
	"errors"
	"sort"
)

// DefaultLimit is the page size used when the caller passes none.
const DefaultLimit = 50

// ErrDuplicate is returned when an item ID is already present.
var ErrDuplicate = errors.New("duplicate item id")

// Item is one catalog entry.
type Item struct {
	ID   string
	Name string
}

// Catalog holds items sorted by ID.
type Catalog struct {
	items []Item
}

// Add inserts an item, keeping the catalog sorted by ID.
func (c *Catalog) Add(it Item) error {
	i := sort.Search(len(c.items), func(i int) bool { return c.items[i].ID >= it.ID })
	if i < len(c.items) && c.items[i].ID == it.ID {
		return ErrDuplicate
	}
	c.items = append(c.items, Item{})
	copy(c.items[i+1:], c.items[i:])
	c.items[i] = it
	return nil
}

// List returns up to limit items starting at offset.
func (c *Catalog) List(offset, limit int) []Item {
	if limit <= 0 {
		limit = DefaultLimit
	}
	if offset < 0 || offset >= len(c.items) {
		return nil
	}
	end := offset + limit
	if end > len(c.items) {
		end = len(c.items)
	}
	return append([]Item(nil), c.items[offset:end]...)
}
