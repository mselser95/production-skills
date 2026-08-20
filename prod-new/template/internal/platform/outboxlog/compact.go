package outboxlog

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// CompactStats describes what a Compact did.
//
// Both a record count and a byte count, because they answer different
// questions and only one of them is the liability. The liability recorded as
// outbox-log-grows-without-compaction is about DISK -- the file growing with
// total lifetime effect volume rather than with the live set -- so bytes are
// the number that says whether it was paid. Records are what says whether the
// NEXT boot's replay got cheaper, which is the second half of the same entry
// ("boot cost grows with it, since store.OpenDurable replays the whole file").
type CompactStats struct {
	// RecordsBefore and RecordsAfter bracket the reclaimed transitions. Note
	// these are RECORDS, not entries: one entry contributes an intent record
	// plus however many outcome records it accumulated.
	RecordsBefore int
	RecordsAfter  int
	// EntriesBefore and EntriesAfter are distinct entry ids seen in the log.
	EntriesBefore int
	EntriesAfter  int
	// BytesBefore and BytesAfter are the file size around the rewrite.
	BytesBefore int64
	BytesAfter  int64
	// Rewritten is false when there was nothing to drop and the file was left
	// exactly as it was. Reported rather than treated as an error: "nothing
	// to reclaim" is the normal state of a young log and of every boot of a
	// service whose effects are all still in flight, and rewriting a file to
	// produce a byte-identical copy would spend an fsync and a rename to
	// achieve nothing while widening the window a crash can land in.
	Rewritten bool
}

// EntriesDropped is how many entries compaction removed from the log.
func (s CompactStats) EntriesDropped() int { return s.EntriesBefore - s.EntriesAfter }

// BytesReclaimed is how much disk compaction gave back. Never negative: a
// compaction that did not run reports zero rather than the difference between
// two reads of the same size.
func (s CompactStats) BytesReclaimed() int64 {
	if !s.Rewritten || s.BytesBefore < s.BytesAfter {
		return 0
	}
	return s.BytesBefore - s.BytesAfter
}

// isTerminal reports whether state ends an entry's life.
//
// StateFailed is deliberately NOT terminal, and getting this wrong is the one
// way compaction can lose an effect rather than merely disk. "failed" means a
// Publish call exhausted its attempt budget and the entry stays a Reconcile
// candidate -- it is "give up for now", not "give up".
// internal/adapter/out/store agrees: OpenDurable replays StateFailed as a
// pending entry and Reconcile picks it up on the next tick. Treating it as
// terminal here would delete, on the very next boot, precisely the entries
// whose delivery had been failing -- the ones most likely to be a real
// undelivered effect.
func isTerminal(state string) bool {
	return state == StateDelivered || state == StateDeadLettered
}

// Compact rewrites the log keeping only the entries that are still LIVE:
// every record of an entry whose last transition is an intent or a failure,
// and nothing at all of an entry that reached a terminal record and that
// retain declines to keep.
//
// WHY THIS EXISTS. Without it the log is append-only forever, so it grows
// with total lifetime effect volume instead of with the pending set, and
// store.OpenDurable's boot replay grows with it -- reading the entire
// delivery history of the service to reconstruct a working set that is
// usually empty. That is registries/contract-debt.yaml's
// outbox-log-grows-without-compaction, and this function is its retirement.
//
// CRASH SAFETY is write-new-then-rename, exactly as
// internal/platform/eventlog.Compact does it, and for the same reason: a
// crash must leave either the old complete file or the new complete file and
// never a truncated one. Truncate-and-rewrite in place would put a window in
// the middle of the operation where the log holds neither, and the log is the
// only record of effects that have been committed to domain state but not yet
// delivered. Four steps make the guarantee real, and each one has a distinct
// failure it prevents:
//
//  1. the tmp file's own fsync BEFORE the rename -- renaming unsynced content
//     over the only copy of history is how compaction turns a crash into data
//     loss;
//  2. the rename itself, atomic within a filesystem;
//  3. the DIRECTORY fsync after it -- a rename is not durable until its
//     directory entry is, and skipping it leaves a compaction that
//     half-worked;
//  4. REOPENING the file handle -- after the rename the old descriptor points
//     at an unlinked inode, so every later Append would write, fsync, and
//     vanish.
//
// RETAIN is the guard that makes dropping a terminal entry SAFE, and it is
// not optional in a service whose outbox is rebuilt from an event log.
// cmd/<SERVICE> rebuilds the outbox at boot as a projection of the event log
// plus a delivery watermark, and THIS LOG IS THAT WATERMARK: an identity
// present here, in any state, delivered included, is treated as already
// handled (see store.Outbox.KnowsIdentity, which OpenDurable populates from
// exactly these records). Dropping a delivered entry whose effect the event
// log can still re-derive would therefore make the next boot read that
// identity as unknown and re-journal it -- REPUBLISHING AN ALREADY-DELIVERED
// EFFECT ON EVERY BOOT. That is not a cleanup; it is a data-integrity
// regression that a literal reading of "keep only what has no terminal
// record" walks straight into.
//
// retain is therefore called with BOTH keys an entry has: its entry id and
// its idempotency key. The idempotency key is the one the boot rebuild
// matches on (store.JournalDerived mints a fresh entry id and stores the
// caller's identity as the key), so a caller that knows what its event log
// can re-derive answers on the key; the entry id is passed because it is what
// the log itself is organised by and a caller with a different watermark may
// key on it. Returning true keeps the entry so the watermark survives as long
// as anything can consult it.
//
// A nil retain means NOTHING can re-derive these entries, which is true for a
// standalone log and for every test in this package, and false in the
// composition root of a service with an event log.
func (l *Log) Compact(retain func(entryID, idempotencyKey string) bool) (CompactStats, error) {
	l.mu.Lock()
	defer l.mu.Unlock()

	var stats CompactStats
	if fi, err := os.Stat(l.path); err == nil {
		stats.BytesBefore = fi.Size()
	}
	stats.BytesAfter = stats.BytesBefore

	// Read through Replay, which decodes and VALIDATES every record. A read
	// error must abort: returning "no records" here would rewrite the log as
	// empty, which is the single most destructive thing this package can do
	// and is reachable by the most ordinary of causes.
	records, err := Replay(l.path)
	if err != nil {
		return stats, err
	}
	stats.RecordsBefore = len(records)
	stats.RecordsAfter = len(records)

	// Last transition wins, which is the same rule Rebuild applies when it
	// folds these records back into snapshots. It matters for Requeue: an
	// operator returning a dead-lettered entry to the pending set appends a
	// fresh intent record for the SAME id, so the id's last state is "intent"
	// and the entry is live again. A rule that asked "did this entry ever
	// have a terminal record" instead would delete exactly the entry a human
	// just asked to retry.
	final := make(map[string]string, len(records))
	// The idempotency key is carried on the intent record and repeated on the
	// outcomes; keep the last non-empty one, mirroring Rebuild.
	keys := make(map[string]string, len(records))
	order := make([]string, 0, len(records))
	for _, rec := range records {
		if _, seen := final[rec.EntryID]; !seen {
			order = append(order, rec.EntryID)
		}
		final[rec.EntryID] = rec.State
		if rec.IdempotencyKey != "" {
			keys[rec.EntryID] = rec.IdempotencyKey
		}
	}
	stats.EntriesBefore = len(final)
	stats.EntriesAfter = len(final)

	drop := make(map[string]struct{}, len(final))
	for _, id := range order {
		if !isTerminal(final[id]) {
			continue
		}
		if retain != nil && retain(id, keys[id]) {
			continue
		}
		drop[id] = struct{}{}
	}
	if len(drop) == 0 {
		return stats, nil
	}

	// Every record of a dropped entry goes, intent included. Dropping the
	// terminal record alone would leave an intent that replays as PENDING and
	// gets delivered a second time; dropping the intent alone would leave a
	// terminal record for an entry Rebuild has never seen, which it refuses
	// to start on -- deliberately, since guessing which effect it referred to
	// is worse. Consistency here is what keeps both of those unreachable.
	kept := make([]Record, 0, len(records))
	for _, rec := range records {
		if _, gone := drop[rec.EntryID]; gone {
			continue
		}
		kept = append(kept, rec)
	}

	// Build the replacement beside the log, then swap it in. Every failure
	// from here to the rename shares ONE cleanup -- remove the half-built
	// replacement and return, leaving the original file untouched and
	// authoritative.
	tmp := l.path + ".compact"
	if err := writeReplacement(tmp, kept); err != nil {
		_ = os.Remove(tmp)
		return stats, err
	}
	if err := os.Rename(tmp, l.path); err != nil {
		_ = os.Remove(tmp)
		return stats, fmt.Errorf("outboxlog: compact rename: %w", err)
	}
	// fsync the DIRECTORY so the rename itself is durable. Without it a crash
	// can lose the rename even though both files were synced. That failure is
	// benign here -- the pre-compaction log is complete and correct, and the
	// reclaim simply did not happen -- which is precisely why it must not be
	// skipped: the alternative orderings are not benign, and a reader who
	// sees this omitted cannot tell which discipline was intended.
	if dir, err := os.Open(filepath.Dir(l.path)); err == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}

	// The old descriptor now points at an unlinked inode. Appends through it
	// would succeed, fsync, and vanish -- a silent loss of exactly the
	// journaled intents this package exists to keep. Reopen against the new
	// file. A log that was already CLOSED stays closed: resurrecting a handle
	// the owner released would let a post-Close Append succeed.
	if l.file != nil {
		_ = l.file.Close()
		reopened, err := os.OpenFile(l.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			l.file = nil
			return stats, fmt.Errorf("outboxlog: compact reopen %s: %w", l.path, err)
		}
		l.file = reopened
	}

	stats.RecordsAfter = len(kept)
	stats.EntriesAfter = stats.EntriesBefore - len(drop)
	stats.Rewritten = true
	if fi, err := os.Stat(l.path); err == nil {
		stats.BytesAfter = fi.Size()
	}
	return stats, nil
}

// writeReplacement writes kept to tmp and puts it on stable storage.
//
// The Sync before the caller's rename is the load-bearing line: renaming a
// file whose contents are still only in the page cache OVER the only copy of
// history means a crash after the rename leaves a log that is neither the old
// one nor the new one. The rename is what makes compaction atomic; the fsync
// is what makes the thing being renamed real.
//
// Close's error is reported rather than deferred-and-ignored: on a
// delayed-allocation filesystem the write error can surface only here, and
// swallowing it would rename a replacement that was never fully written.
func writeReplacement(tmp string, kept []Record) error {
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("outboxlog: compact open %s: %w", tmp, err)
	}
	for _, rec := range kept {
		line, err := json.Marshal(rec)
		if err != nil {
			_ = f.Close()
			return fmt.Errorf("outboxlog: compact marshal: %w", err)
		}
		if _, err := f.Write(append(line, '\n')); err != nil {
			_ = f.Close()
			return fmt.Errorf("outboxlog: compact write: %w", err)
		}
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return fmt.Errorf("outboxlog: compact sync: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("outboxlog: compact close: %w", err)
	}
	return nil
}
