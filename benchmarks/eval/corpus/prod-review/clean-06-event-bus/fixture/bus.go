package events

import "sync"

// Event is one message published on a topic.
type Event struct {
	Topic   string
	Payload string
}

// Handler receives events for the topic it subscribed to.
type Handler func(Event)

type subscription struct {
	id uint64
	fn Handler
}

// Bus is an in-process publish/subscribe hub. The zero value is not usable;
// call New.
type Bus struct {
	mu   sync.Mutex
	next uint64
	subs map[string][]subscription
}

// New returns an empty Bus.
func New() *Bus {
	return &Bus{subs: make(map[string][]subscription)}
}

// Subscribe registers fn for topic and returns a function that removes it.
// The returned function is safe to call more than once.
func (b *Bus) Subscribe(topic string, fn Handler) (unsubscribe func()) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.next++
	id := b.next
	b.subs[topic] = append(b.subs[topic], subscription{id: id, fn: fn})
	return func() { b.remove(topic, id) }
}

func (b *Bus) remove(topic string, id uint64) {
	b.mu.Lock()
	defer b.mu.Unlock()
	cur := b.subs[topic]
	kept := make([]subscription, 0, len(cur))
	for _, s := range cur {
		if s.id != id {
			kept = append(kept, s)
		}
	}
	if len(kept) == 0 {
		delete(b.subs, topic)
		return
	}
	b.subs[topic] = kept
}

// Subscribers reports how many handlers are registered for topic.
func (b *Bus) Subscribers(topic string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.subs[topic])
}
