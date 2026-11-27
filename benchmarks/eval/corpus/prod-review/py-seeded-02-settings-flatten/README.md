# py-seeded-02-settings-flatten (dev) - mutable default argument shared between calls
Change: `settings/sources.py` gains `from_toml`, which parses a TOML document with `tomllib` and flattens its tables into the dotted keys the
environment layer uses (`flatten`, `_leaf`).
Defect: `settings/sources.py:33-38` - `flatten` takes its accumulator as `out: dict[str, str] = {}`. The default dict is created once, so
every call that does not pass `out` (every call from `from_toml`) writes into the same dict and returns it: the second document's result
also carries the first one's keys, and a later call mutates the dict an earlier caller still holds. The existing tests never call the
new functions, and a single call looks right.
Tests: `python3 -m unittest discover -s tests -v` from the repo root (standard library only, Python >= 3.11); they pass before and after the change and never touch the changed code.
Pass: the output is a valid findings document, at least one `defect`-class finding of at most 12 lines on `settings/sources.py` overlaps lines 30-41 (the defect range +-3), at most 5 distinct `defect`-class (file, start line) pairs lie elsewhere, and the tree is unmodified. A wider `defect` that overlaps the window is neutral (no credit, not an FP); `missing_test`, `not_validated` and `note` findings, findings on production.yaml/.prod/ and `severity` never count either way. `verdict` must be `defects_found` exactly when a `defect` finding exists, else the document is invalid.
False positive looks like: complaining that TOML dates or lists become Python `str` text, the lower-case boolean spelling, a dotted key
in the source document colliding with a table, or the missing size limit on the document. Those are outside the defect range.
