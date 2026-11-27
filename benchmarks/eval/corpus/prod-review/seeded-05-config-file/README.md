# seeded-05-config-file (dev) - resource leak on an early return
Change: `config.LoadFile` opens a settings file from an `fs.FS`, parses it, closes it and applies environment overrides.
Defect: `config.go:82-85` - when `Parse` fails the function returns before `f.Close()`, so the file handle is
leaked on every malformed settings file (a reload loop on a bad file exhausts descriptors). The existing tests
never call `LoadFile`, and `fstest.MapFS` does not track handles, so nothing notices.
Pass: the output is a valid findings document, at least one `defect`-class finding of at most 12 lines on `config.go` overlaps lines 79-88 (the defect range +-3), at most 5 distinct `defect`-class (file, start line) pairs lie elsewhere, and the tree is unmodified. A wider `defect` that overlaps the window is neutral (no credit, not an FP); `missing_test`, `not_validated` and `note` findings, findings on production.yaml/.prod/ and `severity` never count either way. `verdict` must be `defects_found` exactly when a `defect` finding exists, else the document is invalid.
False positive looks like: complaining about the missing-file fallback to defaults, a Close error on a
read-only file being returned, or the `Parse` error wrapping. Those are outside the defect range.
