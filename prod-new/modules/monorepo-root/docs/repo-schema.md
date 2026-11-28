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
stanza can be generated from this file. A unit lacks a target when make says so by EXIT STATUS, whatever the unit's build state: `make -C <unit> -q <target>` (output discarded) exits 1
(make would run something: the target) or 0 (nothing out of date); on 0 a second look, `make -C <unit> -q -B <target>` (every file considered out of date),
decides: 1 = the target (it was only up to date), 0 = missing (nothing to run even then: `<target>: ;`, a name only in `.PHONY`, `<target>: other` where
`other` has no recipe; a file named like the target without `.PHONY` is missing too); exit 2 (no rule, no Makefile, an error) asks `make -n`, or the unit
does not answer in time (service, database); or `package.json` has no such script (app, package). Whatever the
Makefile prints or silences (`-s`, `.SILENT`, `$(info)`, a `define` that imitates a rule data base) is never read. An
optional one is a `skip` line in the runner; a mandatory one above is refused by the settings check (`unit-target`) and
FAILs the runner before any unit target is run. A file named like the target beside a rule without `.PHONY` hides it, so
declare `.PHONY: <target>`. A Makefile that answers for a name nobody defines (a `%:` rule or `.DEFAULT:`) is refused:
targets cannot be verified. The inspection asks `make -C <unit> -q <target>`; only if that answers 0 does it ask `make -C <unit> -q -B <target>` (the same question with every file considered out of date, so the verdict does not depend on whether the unit's outputs are fresh); only if the last question asked answered 2 does it ask `make -C <unit> -n <target>` (exit status only; output discarded). Verdict: -q 1 = present; -q 0 and -q -B 1 = present (the target was only up to date), unless a file or directory named like the target sits beside the Makefile and the rule is not `.PHONY` (the real run says up to date: idle, with a `.PHONY` hint); -q -B 0 = idle (nothing to run even with everything out of date); an answer of 2 asks -n: 0 = present, 2 = missing. First question: make parses the unit's Makefile (a parse-time `$(shell ...)` runs; an included file that has a rule may be remade, its recipe IN FULL, plain lines too). Under `-q` make executes the recipe lines marked `+` or containing `$(MAKE)` of the target and of its prerequisites, each recipe at most up to its first line that is neither (an upper bound: it stops at the first out-of-date prerequisite whose recipe starts with a plain line; a file target that a `+` line just created may be deleted again). The `-B` question executes the same classes of lines, passed on to sub-makes in question mode as well, but MORE of them, since nothing counts as up to date: the `+` / `$(MAKE)` lines of prerequisites and sub-make targets that were up to date run too, and an included file that has a rule is remade every time, its recipe IN FULL. Under `-n` make walks the WHOLE recipe, so every `+` / `$(MAKE)` line of the target and of all its out-of-date prerequisites runs (a sub-make in dry-run mode runs its `+` lines and not its plain lines). Apart from that remake, no plain recipe line runs under any question. On GNU make 3.81 and 4.3 the judgment is the same, and the same before and after a real run, for every shape measured, except a recipe made only of `+` / `$(MAKE)` lines that run nothing (`verify:` with `+true`, `+@echo ok`, or `$(MAKE) check-fast` with `check-fast: ;`): 3.81 answers 1 to `-q` (present), 4.3 answers 0 to `-q` and to `-q -B` (idle, fail-closed: such a recipe verifies nothing); `verify: +false` differs too (3.81: `-q` 2 and `-n` 2 = missing; 4.3: `-q` 1 = present) and on both the root `make verify` ends non-zero. What runs during the inspection was measured on GNU make 3.81 and 4.3. What a recipe does cannot be judged by a tool: a
`verify` of `@:` is a no-op its owner wrote on purpose (a review matter).
A directory `db/` must be listed (kind `database`) like `apps/*`, `packages/*` and `services/*`.
