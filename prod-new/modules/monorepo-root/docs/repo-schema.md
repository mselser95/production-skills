# repo.yaml schema (v2)

`repo.yaml` at the repository root is the one inventory of units. The root `Makefile`
(`scripts/monorepo-run.sh`) and `scripts/monorepo-settings-check.sh` read it through the
same parser (`scripts/monorepo_check.py`); `scripts/monorepo_check.py validate <file>` checks a file alone.

```yaml
version: v2                # the string v2
repo: { name: <kebab>, layout: monorepo }   # exactly these two keys
units:                     # a list; empty is allowed
  - { id: <kebab>, kind: service|app|package|database, language: <see below>, path: <see below> }
```

Each unit has exactly `id`, `kind`, `language`, `path`; `id` and `path` are unique.

| kind | language | path | the root delegates through |
|------|----------|------|----------------------------|
| service | go, rust, python | `services/<name>` | the unit's `Makefile` (`check-fast` and `verify` are mandatory, `test` optional) |
| app | ts | `apps/<name>` | `package.json` scripts (`test` mandatory; `check-fast`, `verify` optional) |
| package | ts | `packages/<name>` | the same |
| database | sql | `db` | the unit's `Makefile`, whichever of the targets it defines (none mandatory) |

The field names follow the root `production.yaml` v2 `units:` stanza (`id`, `database`), so that
stanza can be generated from this file. A unit lacks a target when make says so by EXIT STATUS: `make -C <unit> -q <target>` (output discarded) exits 0 (nothing
to do: `<target>: ;`, a name only in `.PHONY`, `<target>: other` where `other` has no recipe, a file named like the target
without `.PHONY`) or 2 (no rule, no Makefile, an error), or does not answer in time (service, database); only exit 1
(make would run something) counts as the target; or `package.json` has no such script (app, package). Whatever the
Makefile prints or silences (`-s`, `.SILENT`, `$(info)`, a `define` that imitates a rule data base) is never read. An
optional one is a `skip` line in the runner; a mandatory one above is refused by the settings check (`unit-target`) and
FAILs the runner before any unit target is run. A file named like the target beside a rule without `.PHONY` hides it, so
declare `.PHONY: <target>`. A Makefile that answers for a name nobody defines (a `%:` rule or `.DEFAULT:`) is refused:
targets cannot be verified. The inspection asks `make -C <unit> -q <target>` and, only if that answers 2, `make -C <unit> -n <target>` (exit status only; output discarded). First question: make parses the unit's Makefile (a parse-time `$(shell ...)` runs; an included file that has a rule may be remade, its recipe IN FULL, plain lines too). Under `-q` make executes the recipe lines marked `+` or containing `$(MAKE)` of the target and of its prerequisites, each recipe at most up to its first line that is neither (an upper bound: it stops at the first out-of-date prerequisite whose recipe starts with a plain line; a file target that a `+` line just created may be deleted again). Only when that answers 2 does it ask the SECOND question, `make -C <unit> -n <target>`, same scrubbed environment, output discarded: 0 = present, 2 = missing. Under `-n` make walks the WHOLE recipe, so every `+` / `$(MAKE)` line of the target and of all its out-of-date prerequisites runs (a sub-make in dry-run mode runs its `+` lines and not its plain lines). Apart from that remake, no plain recipe line runs under either question. GNU make 4 answers 1 where 3.81 answers 2 to `-q` for a recipe that starts with a `$(MAKE)` or `+` line, and the judgment is the same (`verify: $(MAKE) check-fast` is present on both); `verify: +false` differs (3.81: `-q` 2 and `-n` 2 = missing; 4.3: `-q` 1 = present) and on both the root `make verify` ends non-zero. What runs during the inspection was measured on GNU make 3.81 and 4.3. What a recipe does cannot be judged by a tool: a
`verify` of `@:` is a no-op its owner wrote on purpose (a review matter).
A directory `db/` must be listed (kind `database`) like `apps/*`, `packages/*` and `services/*`.
