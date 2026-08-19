package app

import (
	"strconv"

	"github.com/<OWNER>/<SERVICE>/internal/domain"
)

// This file exists because journaling an effect is NOT atomic with committing
// the state change that produced it.
//
// process() appends the event to the durable log, commits the state, releases
// the lock, and only THEN journals the effects. Those are two separate durable
// writes with no transaction between them, so a crash in that window leaves an
// event that replays correctly and an effect that is gone forever -- because
// RebuildFrom folds `state, _ = domain.Apply(...)` and discards effects.
//
// The classic outbox closes this by writing its row in the SAME transaction as
// the state change. With no database there is no transaction, but there is
// something better available: domain.Apply is PURE and TOTAL, so the effects of
// an event are DERIVABLE from the event. The outbox therefore does not need to
// be written atomically -- it needs to be RECONSTRUCTIBLE. At boot the
// composition root re-derives every effect from the event log and journals the
// ones the outbox does not already know about, which closes the window with a
// single durable write on the hot path.
//
// That reconstruction only works if a re-derived effect can be recognised as
// the SAME effect the first attempt would have journaled. Hence a derived
// identity rather than a random id.

// NeedsDelivery reports whether an effect leaves this process.
//
// It is a named function, not an inline type switch, precisely because two
// places must agree about it forever: process() when it journals effects, and
// the boot-time reconstruction when it re-derives them. If those two ever
// disagreed about which effects count, the indices below would shift and every
// identity after the divergence would name a different effect -- recovering by
// delivering the wrong things, which is worse than not recovering.
func NeedsDelivery(effect domain.Effect) bool {
	switch effect.(type) {
	case domain.EffectDeposited, domain.EffectWithdrawn:
		return true
	default:
		return false
	}
}

// DeliverableEffects filters effects down to the ones NeedsDelivery accepts,
// preserving order. The position of an effect in THIS slice is the index its
// identity carries.
func DeliverableEffects(effects []domain.Effect) []domain.Effect {
	out := make([]domain.Effect, 0, len(effects))
	for _, e := range effects {
		if NeedsDelivery(e) {
			out = append(out, e)
		}
	}
	return out
}

// EffectIdentity is the deterministic name of one deliverable effect:
// the event that produced it, plus its index among that event's deliverable
// effects.
//
// Both halves are exact rather than approximate. The event id is unique by the
// ledger's own idempotency guarantee -- domain.Apply admits a given id once --
// and the index is reproducible because Apply is pure, so replaying the same
// event against the same prior state yields the same effects in the same
// order. Together they name an effect stably across a restart, which is what
// lets the boot-time reconstruction tell "never journaled" from "already
// journaled" without storing the effects themselves.
//
// Indexing over DELIVERABLE effects only is deliberate. Indexing over all
// effects would renumber every existing identity the day someone adds an
// internal-only rejection Effect to the domain -- a change with no delivery
// semantics at all would silently invalidate every recorded identity.
//
// The rendering appends "#<index>" and is parsed from the RIGHT, so an event
// id that itself contains "#" is unambiguous.
func EffectIdentity(eventID string, index int) string {
	return eventID + "#" + strconv.Itoa(index)
}
