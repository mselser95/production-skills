# Failure-mode matrix — mselser95/production-skills

Auto-expanded on 2026-08-29 from the class checklists in `_shared/tier-policy.yaml`.
The denominator is not a judgement call: both declared capabilities are class
`source_of_truth`, whose checklist lists seven scenarios, so this matrix has
**fourteen rows and may not have thirteen**. A capability whose scenarios were
chosen by whoever wrote the matrix has a denominator equal to its own coverage,
which is how a matrix reports 100% forever.

**`blocked` is not a legal status here.** `tested`, `untested` and
`not-applicable` are the three, and the third is legal only with the PROPERTY
that produced it — not the word "N/A". A property can be checked against the
capability list by someone who disagrees with it; a conclusion can only be
trusted.

Every `tested` row below was run on 2026-08-29 and its observed output is
quoted. None was marked tested by reading the code.

---

## skill_distribution (class: source_of_truth)

`install.sh` copies the nine skills into `${CLAUDE_CONFIG_DIR}/skills` and writes
`prod-skills.manifest`. It is the only thing in this repo that writes outside it.

| # | scenario | status | evidence / property |
|---|---|---|---|
| 1 | deadlock | not-applicable | One process, no lock manager, and no two resources that could be acquired in different orders. A deadlock needs at least two holders; there is one. |
| 2 | serialization_conflict | not-applicable | Single writer, per `production.yaml` `semantics.consistency`: every mutation is a git commit or an `install.sh` run, each serialised by the human or hook that invoked it. With no interleaving there is nothing to serialise. |
| 3 | timeout | not-applicable | No operation crosses a process boundary. Every effect is a local file copy, whose failure arrives as an errno immediately — not as a call that stops answering. |
| 4 | commit_ok_response_lost | not-applicable | The caller and the effect are the same process. There is no acknowledgement in transit that could be lost after the write landed. |
| 5 | connection_dies_before_commit | **tested** | The crash-mid-copy state is "installed tree diverges from the manifest", because `install.sh:299` writes the manifest AFTER the copies. Simulated by truncating an installed file (hash `8b59e844…` → `58826798…`, 12343 → 200 bytes, **mutation confirmed by hash before reading the verdict**). `--verify` printed `TCB DRIFT — the installed skills no longer match the manifest: changed/added: prod-ops/SKILL.md` and exited **1**. |
| 6 | connection_dies_after_commit | **tested — the gate was BUILT for this row** | The window is: manifest written, `chmod -R a-w` incomplete. The result is a trusted set whose contents are right and whose permissions are wide open, and `--verify` could not see it — it compared hashes, never modes, so it printed `TCB verified` over a tree with no read-only guard left. Expanding this checklist is what surfaced it; no incident did. Fixed the same day by adding the mode check to `--verify` (exit **3**, `TCB WRITABLE`). Proven in both directions: `chmod u+w` on `prod-ops/SKILL.md` (mode confirmed `-rw-r--r--` before reading the verdict) → `TCB WRITABLE — 1 file(s) … writable: skills/prod-ops/SKILL.md`, rc 3; re-running `install.sh` → rc 0. And proven NOT to fire when nothing is wrong: a healthy install is rc 0, and a hand-edited `config.sh` — which every skill's docs tell you to edit — stays rc 0 because it is outside the trusted set by the same exclusion `hash_tree` uses. |
| 7 | restore_from_backup | **tested** | The repo is the durable state and git is its backup, so a restore is a clone. Ran it: `git clone` into a fresh dir → `install.sh` into a fresh `CLAUDE_CONFIG_DIR` → the resulting manifest is **byte-identical** to the working tree's, 308 of 308 files, `diff` empty. |

## template_vending (class: source_of_truth)

`prod-new` copies `prod-new/template/` verbatim into a new repository. The copy is
the product; drift between this tree and an instantiated repo is the failure mode.

| # | scenario | status | evidence / property |
|---|---|---|---|
| 8 | deadlock | not-applicable | Same property as row 1: one process, no lock manager. |
| 9 | serialization_conflict | not-applicable | Same property as row 2: single writer. |
| 10 | timeout | not-applicable | Same property as row 3: a scaffold is a local recursive copy, not a remote call. |
| 11 | commit_ok_response_lost | not-applicable | Same property as row 4: no acknowledgement leaves the process. |
| 12 | connection_dies_before_commit | **tested** | A scaffold interrupted before the provenance stamp leaves a repo with template files and no `.prod/template-provenance.yaml`. Ran `check-template-drift.sh --local` in exactly that state: `no .prod/template-provenance.yaml -- this repo records no scaffold provenance, so nothing here can be compared`, exit **2**. It does not report `none`; absent provenance is "the question cannot be answered", which is the correct third state. |
| 13 | connection_dies_after_commit | **tested** | The stamp exists but was written empty (interrupted between creating the file and filling it). Ran it with `files: []`: `records no files -- a comparison over an empty set is not a clean comparison`, exit **2**. The zero-inputs case is not a clean comparison, and the script says so. |
| 14 | restore_from_backup | **tested** | Same evidence as row 7 — the template travels inside this git repo, so its restore path IS the clone that was tested, with no separate procedure whose fidelity could differ. |

---

## Summary

**14 of 14 rows resolved. 0 `blocked`. 0 `untested`.**

- 6 `tested`, each with its observed output quoted above.
- 8 `not-applicable`, each naming the property rather than the conclusion.

**Row 6 is why this file exists.** Every other row confirmed something already
true; row 6 was a hole nobody knew about, and it was found by the denominator
rather than by an outage — the class checklist listed a scenario, the scenario
had no answer, and looking for one showed `--verify` printing `TCB verified`
over a trusted set with no read-only guard left on it. That is the whole
argument for a matrix whose row count is fixed by the capability's class instead
of by whoever was writing it: the seventh row is the one you would not have
thought of, which is exactly the one worth having.

Re-expand this matrix whenever a capability is added or its class changes. A
capability appended to `production.yaml` without its seven rows appearing here
is a silently shrinking denominator, and the coverage above would keep reading
100%.
