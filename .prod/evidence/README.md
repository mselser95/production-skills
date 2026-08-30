# Evidence records

**Nothing in this directory is committed.** `.gitignore` excludes `*.json` here,
and that is the design rather than an oversight.

Dimension 11 asks for a per-commit evidence record produced by **CI on a clean
tree**. That record is uploaded as a workflow artifact (`evidence-<sha>`), where
its provenance is the run that produced it — a specific commit, a specific
runner, pinned tool versions. Find it on the run for the commit you care about.

A record generated locally by `make evidence` attests to whatever tools happened
to be installed on that machine, which is useful to the person who ran it and to
nobody else. Committing those would put a file that looks like an attestation
next to one that is.

Two properties the generator enforces, both worth knowing before reading any
record:

- **The filename is the attestation.** `<sha>.json` means "measured on exactly
  that commit". A dirty tree produces `dirty-<sha>-<timestamp>.json` and carries
  `tree_clean: false`, because a record named after a commit it was never
  measured on is worse than no record — that has happened here before, and the
  file claimed a PASS for a probe row that did not exist in that commit's tree.
- **Every gate carries its own evidence line**, not just a verdict. A record
  holding exit codes and nothing else is a boolean pretending to be an
  attestation.

Regenerate locally with `make evidence`.
