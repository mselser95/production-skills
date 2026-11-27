# py-seeded-03-hourly-counter (heldout) - local wall clock read where UTC is required
Change: `windows/labels.py` gains `current_label` and `recent_labels`, and `HourlyCounter` gains `recent_total`; each reads the clock when none is
injected, so callers can ask about the hour in progress without passing a timestamp.
Defect: `windows/labels.py:25-25` - the default clock is `datetime.now()`, a naive LOCAL time. `as_utc` takes a naive timestamp to be UTC, so on a
host whose zone is not UTC every label is shifted by the host's offset (Tokyo: the label is nine hours ahead) and `recent_total` reads
the wrong hours. A UTC host, CI included, hides it, and the existing tests never reach the default clock.
Tests: `python3 -m unittest discover -s tests -v` from the repo root (standard library only, Python >= 3.11); they pass before and after the change and never touch the changed code.
Pass: the output is a valid findings document, at least one `defect`-class finding of at most 12 lines on `windows/labels.py` overlaps lines 22-28 (the defect range +-3), at most 5 distinct `defect`-class (file, start line) pairs lie elsewhere, and the tree is unmodified. A wider `defect` that overlaps the window is neutral (no credit, not an FP); `missing_test`, `not_validated` and `note` findings, findings on production.yaml/.prod/ and `severity` never count either way. `verdict` must be `defects_found` exactly when a `defect` finding exists, else the document is invalid.
False positive looks like: complaining that `as_utc` accepts naive input, the `n < 1` check, or the list comprehension building labels
one hour at a time. Those are outside the defect range.
