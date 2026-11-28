# monorepo-root

The part of a greenfield monorepo that no single service or app owns: the root files two modules
would otherwise collide on. Layout `monorepo` only (in `single` its root files would collide with the
service's own `Makefile`). The manifest cannot express a layout, so `--layout single` still assembles it;
`scripts/monorepo-settings-check.sh` then fails first when there is no `pnpm-workspace.yaml` + `repo.yaml` pair.
Not placed in the assembled repo (`exclude`): this README.

## What it owns (placed at the repository root)

| File | What it is |
|------|------------|
| `package.json` | private; `packageManager: pnpm@10.34.3`, `engines` (node `>=24 <27`, pnpm `>=10.34.3 <13`); scripts only delegate to `make` |
| `pnpm-workspace.yaml` | workspace globs `apps/*` and `packages/*`; the ONE `catalog:` (every version is written here); install policy (below) |
| `.nvmrc` | `26`, inside `engines.node` |
| `tsconfig.base.json` | the strict TypeScript base every TS unit extends; this module is its only owner |
| `Makefile` | `check-fast`, `verify`, `test`, `settings-check`: `settings-check` runs first and is a prerequisite of `check-fast` and `verify` (a red check stops before any unit target is run); the runner then runs the same-named target in every unit of `repo.yaml`, one line per unit, stops at the first failure; no unit logic |
| `repo.yaml`, `docs/repo-schema.md` | the unit inventory and its schema |
| `scripts/monorepo-settings-check.sh`, `scripts/monorepo_check.py`, `scripts/monorepo-run.sh` | the settings gate, the one `repo.yaml` reader, the Makefile's runner |
| `.gitignore`, `.editorconfig` | `.gitignore` merges by `union-lines` (`root_merge`), so a service that declares the same glob composes |

Workspace settings (keys checked against the option table of pnpm 10.34.3): `catalogMode: strict`,
`engineStrict`, `strictPeerDependencies`, `strictDepBuilds`, `onlyBuiltDependencies: []`,
`blockExoticSubdeps`, `minimumReleaseAge: 10080`, `trustPolicy: no-downgrade`. No `.npmrc` anywhere:
nothing needs it, and the check refuses the file by name. Moving to pnpm 11/12 renames
`onlyBuiltDependencies` to `allowBuilds`; change it and the pin together. The effect of `trustPolicy` and
`blockExoticSubdeps` is set, not demonstrated here.

## What the settings check enforces (`make settings-check`, exit 1, `file:line: rule message`)

The pinned pnpm's `catalogMode: strict` does not refuse a range at install time, so the check is the enforcement.
For the workspace file, file names and `package.json` keys it is a set of ALLOW-lists, not a list of known-bad
constructs; dependency specs are an allow-list too (only the three spec forms below); the remaining value rules
(`packageManager`, `engines`, `minimumReleaseAge`, the exact values of the settings) are exact-match checks:

- `pnpm-workspace.yaml` (rule `root-settings`): the top-level keys are only `packages`, `catalog`, `catalogs`,
  `catalogMode`, `engineStrict`, `strictPeerDependencies`, `strictDepBuilds`, `onlyBuiltDependencies`,
  `blockExoticSubdeps`, `minimumReleaseAge`, `trustPolicy`; any other key (`overrides`, `packageExtensions`,
  `minimumReleaseAgeExclude`, `registry`, an unknown one) is refused at its own line. Each setting has its exact
  value (`minimumReleaseAge` an integer >= 1440). `onlyBuiltDependencies` is a block list of plain package names
  (no `*`, no glob), each with a `# reason: <why>` comment on its own line. `packages` holds only `apps/*` and
  `packages/*`. A duplicate key is refused. `catalog-spec`: every catalog entry is an exact version.
- Files refused by existence anywhere in the repository (only `node_modules/` and `.git/` are not walked; `dist/`,
  `coverage/` and `target/` are): `.npmrc`, `.pnpmfile.*` / `pnpmfile.*`, `package.yaml`, `package.json5`,
  a nested `pnpm-workspace.yaml` (rule `supply-override`); `package-lock.json`, `npm-shrinkwrap.json`, `yarn.lock`,
  `bun.lock`, `bun.lockb`, `deno.lock`, a nested `pnpm-lock.yaml` (rule `second-lockfile`).
- A workspace with at least one `package.json` under `apps/*` or `packages/*` and no root `pnpm-lock.yaml` (rule
  `lockfile-missing`): run `make lock` and commit the result.
- `package.json` keys (rule `pkg-key`), an ALLOW-list per manifest. Root: `name`, `private`, `packageManager`,
  `engines`, `scripts` (what the shipped root has) and the four dependency fields. Workspace package: `name`,
  `version`, `private`, `type`, `description`, `license`, `main`, `module`, `types`, `exports`, `files`,
  `sideEffects`, `scripts`, `engines`, `packageManager`, `bin`, `repository`, `keywords`, `author`,
  `peerDependenciesMeta` (only `{name: {optional: true|false}}`) and the four dependency fields (the
  design-system packages' manifests need the first set; the rest is plain npm metadata with no resolution
  effect). Any other key (`devEngines`, `workspaces`, `dependenciesMeta`, `publishConfig`, `config`, `imports`,
  an unknown one) is refused at its own line; `resolutions`, `overrides`, `pnpm`, `bundledDependencies`,
  `bundleDependencies` are refused with the more specific rule `supply-override`. `devEngines.runtime` is real:
  pnpm 10.34.3 writes `node@runtime:<version>` into the lockfile and downloads it from nodejs.org, outside the
  catalog and `engines.node`. Every value in `dependencies`,
  `devDependencies`, `peerDependencies`, `optionalDependencies` is exactly `catalog:`, `catalog:<name>` (the entry
  must exist: `catalog-missing`) or `workspace:*`, nothing else (`non-catalog-dep`). `catalog:` is valid in
  `peerDependencies` (checked with a scratch install). `packageManager` is `pnpm@X.Y.Z`, optionally with
  `+sha512.<hex>`, and the same string wherever a package states one; a package's `engines` keys are `node` and
  `pnpm` only and equal the root's; the root `engines` equal the shipped values exactly (`pm-engines`). `nvmrc`:
  `.nvmrc` inside `engines.node`.
- `stray-package-json`: a `package.json` anywhere but the root and the workspace packages (`apps/*`, `packages/*`;
  `node_modules/` is not walked) is refused: a service that needs JS tooling becomes a workspace package on purpose.
  `tracked-node-modules`: a file under `node_modules/` that git tracks is refused (`git ls-files`, asked only when the root has a
  `.git`; a tree that is not a git repository cannot tell a committed `node_modules/` from an install, so it gets no finding).
- `repo.yaml` (`repo-yaml`, `unit-path`), `unit-unlisted` (a directory under `apps/`, `packages/`,
  `services/`, or `db/`, that is not in `repo.yaml`), `unit-target` (a unit lacks a mandatory target, or its
  Makefile answers for any target name).

## Mandatory and optional unit targets

| kind | mandatory | optional (a missing one is a `skip` line) |
|------|-----------|-------------------------------------------|
| service | `check-fast`, `verify` | `test` |
| app, package | `test` | `check-fast`, `verify` |
| database | none | `check-fast`, `verify`, `test` |

One function decides "this unit has target T", used by the check and by `scripts/monorepo-run.sh`: for a service
or database it asks make for its VERDICT and reads the EXIT STATUS, never anything make prints. For each unit and
target: `env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEOVERRIDES -u GNUMAKEFLAGS -u MAKEFILES make -C <unit> -q -- <target>`
with stdout and stderr discarded (the caller's make flags are scrubbed, so a root `make -n`, `-i`, `-k`, `-B` or `-s`
does not change the answer; a call that takes over 20 s is unanswered). GNU make's question mode answers 1 when it
would run something for the target (PRESENT), 0 when it has nothing to do, 2 on an error (no rule for the target, no
Makefile, a syntax error). A 0 is not yet an answer: it means either that make has nothing to run for the target or that
the target is merely up to date (its outputs are fresh), and a verdict about whether a unit HAS a target must not depend on
build state. So an answer of 0 asks a SECOND question, the same command with `-B` added (`make -q -B`, `--always-make`: every
file is considered out of date; same scrubbed environment, output discarded). `-q -B` 1 means make has work for the target
when nothing is up to date, so the rule graph is real: PRESENT, except when a file or directory named like the target
sits beside the Makefile and the rule is not `.PHONY` (the real run would say "up to date" and run nothing: missing, with the hint
`.PHONY: <target>`). `-q -B` 0 means there is nothing to run even with everything out of date: missing. A recipe whose first
line is marked `+` or contains `$(MAKE)` (e.g. `verify:` whose first line is `$(MAKE) check-fast`) is executed by question mode,
and the exit status then varies by version and by build state; when the last question asked answers 2, a THIRD question is asked,
the same command with `-n` in place of `-q` (same scrubbed environment, output discarded): `-n` exit 0 means make has a rule
graph for the target and can plan it, so it is PRESENT; `-n` exit 2 (no rule, a missing prerequisite, a syntax error, no
Makefile, or a `+` / `$(MAKE)` line that fails already under `make -n`) means missing. Missing also covers: `verify: ;`, a name only in `.PHONY`, `verify: other` where
`other` has no recipe, and a target whose name is also a FILE in the unit directory without `.PHONY` ("up to date";
the message adds the hint `.PHONY: <target>`). Any other status, a signal or a timeout (of any question) is missing too, and the
message carries the exit status (`make -q: 2, make -n: 2` for the pair). The `-B` question is asked only when `-q` answered 0, never for
a unit whose targets answer 1 (the three shipped service modules). Prerequisite-only targets (`verify: check-fast lint`, the shape of the service
modules), pattern rules, static pattern rules, included files and double-colon rules are answered by make itself.
One more question per unit asks for a random name no unit can define (`__monorepo_probe_<16 hex>`) and goes through the
same `-q` and `-n` steps, never `-B` (a catch-all whose recipe starts with `$(MAKE)` answers `-q` 2 and `-n` 0 on 3.81, `-q` 1 on 4.3; for every ordinary unit the probe
answers 2 and 2, so each unit costs one extra `make -n` for the probe name, never for a real target): a `-q` answer of 0
or 1, or of 2 followed by `-n` 0, means the unit answers for ANY name (a `%:` rule or `.DEFAULT:`), and the unit is refused (`unit-target`, "answers for
any target name ... targets cannot be verified") by the check and by the runner, whatever its targets are: an explicit
rule cannot be told apart from a catch-all by exit status. Answers are cached per (unit, target) within one run. Every question runs in its own session (process group): when it times out, or when it returns with anything left in
its group (a `+` line that backgrounded a job), the whole group is killed with SIGKILL and reaped, on every path out, including a TERM, HUP or INT sent to the checker or to the runner (the checker's handler kills every live question group, removes its private temp dir and exits 128+n; the runner forwards the signal to its child and exits 128+n). The
random-name probe is asked FIRST for each unit, with a 5 s limit (the other questions get 20 s), so a unit that answers
for any name, or hangs on one (a forwarding `%: ; +$(MAKE) $@`), is refused as a catch-all before any other question is
asked of it. Test hooks, not settings: `MONOREPO_QUESTION_TIMEOUT=<seconds>` lowers both limits (a timeout case costs 2 s),
`MONOREPO_QUESTION_LOG=<file>` appends one line per question actually asked. For an
app or package the function reads `package.json` `scripts`. A unit that lacks a mandatory target makes the runner
FAIL before any unit target is run, and `make check-fast` / `make verify` stop at the settings check first. The inspection asks `make -C <unit> -q <target>`; only if that answers 0 does it ask `make -C <unit> -q -B <target>` (the same question with every file considered out of date, so the verdict does not depend on whether the unit's outputs are fresh, and with every makefile make read named by `-o` (--assume-old: no makefile is remade and no rule is added to the unit's rule base; GNU make 3.81 remakes an included makefile that has a rule under -B and answers 1 for it, 4.3 does not; the names come from one list pass, asked first: `make -C <unit> -q -f <unit makefile> -f <list makefile> <random name>`, whose module-owned makefile writes `$(MAKEFILE_LIST)` into a file in the private temp dir by a parse-time `$(shell printf ...)`, the exit status of the pass is not used, and a list that is empty or names something that is not a file beside the unit leaves the unit unanswerable: fail closed); only if the last question asked answered 2 does it ask `make -C <unit> -n <target>` (exit status only; output discarded). Verdict: -q 1 = present; -q 0 and -q -B 1 = present (the target was only up to date), unless a file or directory named like the target sits beside the Makefile and the rule is not `.PHONY` (the real run says up to date: idle, with a `.PHONY` hint); -q -B 0 = idle (nothing to run even with everything out of date); an answer of 2 asks -n: 0 = present, 2 = missing. First question: make parses the unit's Makefile (a parse-time `$(shell ...)` runs; an included file that has a rule may be remade, its recipe IN FULL, plain lines too). Under `-q` make executes the recipe lines marked `+` or containing `$(MAKE)` of the target and of its prerequisites, each recipe at most up to its first line that is neither (an upper bound: it stops at the first out-of-date prerequisite whose recipe starts with a plain line; a file target that a `+` line just created may be deleted again). The `-B` question executes the same classes of lines, passed on to sub-makes in question mode as well, but MORE of them, since nothing counts as up to date: the `+` / `$(MAKE)` lines of prerequisites and sub-make targets that were up to date run too, and no makefile is remade (-o). Under `-n` make walks the WHOLE recipe, so every `+` / `$(MAKE)` line of the target and of all its out-of-date prerequisites runs (a sub-make in dry-run mode runs its `+` lines and not its plain lines). Apart from that remake under the first question, the list pass and -n, no plain recipe line runs under any question; the list pass asks for a name no unit has, so it executes the unit's parse-time `$(shell ...)`, the remake of included makefiles (as the first question does) and the module's one printf that writes the makefile names, nothing else. On GNU make 3.81 and 4.3 the judgment is the same, and the same before and after a real run, for every shape measured (an included makefile that has a rule, with no rule that runs anything for the target, is idle, and so is verify: gen.mk with gen.mk such an included makefile; the same unit with verify: build or a $(MAKE) build line is present), except a recipe made only of `+` / `$(MAKE)` lines that run nothing (`verify:` with `+true`, `+@echo ok`, or `$(MAKE) check-fast` with `check-fast: ;`): 3.81 answers 1 to `-q` (present), 4.3 answers 0 to `-q` and to `-q -B` (idle, fail-closed: such a recipe verifies nothing); `verify: +false` differs too (3.81: `-q` 2 and `-n` 2 = missing; 4.3: `-q` 1 = present) and on both the root `make verify` ends non-zero. What runs during the inspection was measured on GNU make 3.81 and 4.3.
The runner runs each unit with stdin from `/dev/null`, reads the whole unit list before running any, refuses a
unit path that is a symlink or resolves outside the repository, announces how many units it will run and
asserts it ran that many.

## Limits

The inspection asks `make -C <unit> -q <target>`; only if that answers 0 does it ask `make -C <unit> -q -B <target>` (the same question with every file considered out of date, so the verdict does not depend on whether the unit's outputs are fresh, and with every makefile make read named by `-o` (--assume-old: no makefile is remade and no rule is added to the unit's rule base; GNU make 3.81 remakes an included makefile that has a rule under -B and answers 1 for it, 4.3 does not; the names come from one list pass, asked first: `make -C <unit> -q -f <unit makefile> -f <list makefile> <random name>`, whose module-owned makefile writes `$(MAKEFILE_LIST)` into a file in the private temp dir by a parse-time `$(shell printf ...)`, the exit status of the pass is not used, and a list that is empty or names something that is not a file beside the unit leaves the unit unanswerable: fail closed); only if the last question asked answered 2 does it ask `make -C <unit> -n <target>` (exit status only; output discarded). Verdict: -q 1 = present; -q 0 and -q -B 1 = present (the target was only up to date), unless a file or directory named like the target sits beside the Makefile and the rule is not `.PHONY` (the real run says up to date: idle, with a `.PHONY` hint); -q -B 0 = idle (nothing to run even with everything out of date); an answer of 2 asks -n: 0 = present, 2 = missing. First question: make parses the unit's Makefile (a parse-time `$(shell ...)` runs; an included file that has a rule may be remade, its recipe IN FULL, plain lines too). Under `-q` make executes the recipe lines marked `+` or containing `$(MAKE)` of the target and of its prerequisites, each recipe at most up to its first line that is neither (an upper bound: it stops at the first out-of-date prerequisite whose recipe starts with a plain line; a file target that a `+` line just created may be deleted again). The `-B` question executes the same classes of lines, passed on to sub-makes in question mode as well, but MORE of them, since nothing counts as up to date: the `+` / `$(MAKE)` lines of prerequisites and sub-make targets that were up to date run too, and no makefile is remade (-o). Under `-n` make walks the WHOLE recipe, so every `+` / `$(MAKE)` line of the target and of all its out-of-date prerequisites runs (a sub-make in dry-run mode runs its `+` lines and not its plain lines). Apart from that remake under the first question, the list pass and -n, no plain recipe line runs under any question; the list pass asks for a name no unit has, so it executes the unit's parse-time `$(shell ...)`, the remake of included makefiles (as the first question does) and the module's one printf that writes the makefile names, nothing else. On GNU make 3.81 and 4.3 the judgment is the same, and the same before and after a real run, for every shape measured (an included makefile that has a rule, with no rule that runs anything for the target, is idle, and so is verify: gen.mk with gen.mk such an included makefile; the same unit with verify: build or a $(MAKE) build line is present), except a recipe made only of `+` / `$(MAKE)` lines that run nothing (`verify:` with `+true`, `+@echo ok`, or `$(MAKE) check-fast` with `check-fast: ;`): 3.81 answers 1 to `-q` (present), 4.3 answers 0 to `-q` and to `-q -B` (idle, fail-closed: such a recipe verifies nothing); `verify: +false` differs too (3.81: `-q` 2 and `-n` 2 = missing; 4.3: `-q` 1 = present) and on both the root `make verify` ends non-zero. What runs during the inspection was measured on GNU make 3.81 and 4.3. The root does not sandbox make: the units are the repository's own code and are trusted to the
degree `make check-fast` trusts them. No unit TARGET RECIPE is run for `check-fast`, `verify` or `test` when a mandatory
target is missing.

Scope boundary: the root can tell that make WOULD run something for a target; it cannot tell what a recipe does. A unit
whose `verify` recipe is `@:` or `@true`, or whose Makefile defines the rule only under a condition on `MAKEFLAGS` /
`MAKECMDGOALS`, has an owner who wrote a no-op on purpose; that is a review matter, not something this check claims to
catch. One boundary of the same class: the inspection sees a unit as plain `make <target>` would, without the caller's
command-line variables (the scrub removes `MAKEFLAGS`, so `make verify MODE=fast` at the root reaches the inspection as an
environment variable at most, which a `MODE := strict` assignment in the unit overrides, while the real run gets it as a
command-line override); a conditional on such a variable that selects an empty recipe is not seen.

Install scripts: `strictDepBuilds` and `onlyBuiltDependencies: []` govern DEPENDENCIES only. A workspace package's own
`preinstall` / `postinstall` / `prepare` scripts are the repository's own code and DO run on a plain `pnpm install`.
This module's root Makefile and root `package.json` have no install target (they only delegate to `monorepo-run.sh`);
a human or CI that installs should pass `--ignore-scripts` (`pnpm install --frozen-lockfile --ignore-scripts`), as the
live selftest does for its network installs.
Measured on GNU make 3.81 (macOS) and 4.3 (Debian bookworm): the judgments above, except one known divergence of 4.3: a recipe whose `+` / `$(MAKE)` first lines SUCCEED with nothing to do (`verify:` with `+true`, or `$(MAKE) check-fast` where `check-fast: ;`) answers `-q` 0 there, so it is judged idle = missing (RED, fail closed), where 3.81 judges it present. Not proven: other GNU make versions. Limits of the `-B` look, which names the makefiles it read with `-o`: an included makefile that is a PREREQUISITE of the target counts as old, so `verify: gen.mk` (with `gen.mk` an included makefile that has a rule) is idle; and a makefile rule whose recipe leaves its prerequisite NEWER than the makefile (`Makefile:: Makefile.in` with `@true`, `Makefile.in` newer) never converges: 3.81 answers 2 to every question (missing) and 4.3 loops on the `-B` look until its timeout (fail closed), so such a unit is RED even with a real `verify`. The list pass and the `-B` look run only for a target whose first answer was 0; the three shipped service modules never reach them.

## Adding a unit

Create its directory (`services/<name>`, `apps/<name>`, `packages/<name>`, or `db`) and add one entry
to `repo.yaml`. Nothing else in this module changes. The unit brings its own `Makefile` (service) or
`package.json` scripts (app, package) and takes dependency versions from the catalog.

## The lockfile

No `pnpm-lock.yaml` is shipped: a lockfile names the design system's scope (`@<scope>/tokens`), so a
pre-generated one would be wrong for every scope but one. The lockfile is GENERATED, once, when a
repository is scaffolded: run `make lock` (`pnpm install --lockfile-only --ignore-scripts`; needs the registry;
catalog versions are at least 7 days old at that moment) and commit the result. `make lock-check`
(`pnpm install --frozen-lockfile --lockfile-only --ignore-scripts --offline`) fails when the lockfile is missing
or no longer matches the workspace manifests; measured, it needs neither network nor a package store (a cold
cache is enough), because a frozen install resolves nothing. It is a separate target, NOT a prerequisite of
`verify`: a fresh scaffold has no lockfile until `make lock`, and a repository of Go, Rust or Python units may
have no pnpm. The settings check refuses any lockfile other than the root one (`second-lockfile`) and reports
a workspace with JS packages and no root `pnpm-lock.yaml` (`lockfile-missing`), so a fresh scaffold is RED on
`check-fast` until `make lock` has run and its result is committed.

## Not here

A CI workflow, at the repository root, that calls each unit's workflow (a unit's own `.github/workflows/` under `services/<id>/` is not read by GitHub), a CI workflow that runs `pnpm install --frozen-lockfile` (the settings check itself runs in `make check-fast` and `make verify`), the
root `production.yaml` v2 `units:` stanza (a later step generates it from `repo.yaml`), the tools a unit
uses (eslint, vitest config), Docker.

Tested by `scripts/tests/monorepo-root-selftest.sh` (needs python3 with PyYAML). The default run is hermetic
(no pnpm, no network) and is what CI runs; `MONOREPO_LIVE=1`, set by a human with pnpm 10.34.3 and the registry,
adds the live pnpm cases.
