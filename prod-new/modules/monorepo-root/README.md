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
Makefile, a syntax error). Exit 0 is reported missing: `verify: ;`, a name only in `.PHONY`, `verify: other` where
`other` has no recipe, and a target whose name is also a FILE in the unit directory without `.PHONY` ("up to date";
the message adds the hint `.PHONY: <target>`). Exit 2, any other status, a signal or a timeout is missing too, and the
message carries the exit status. Prerequisite-only targets (`verify: check-fast lint`, the shape of the service
modules), pattern rules, static pattern rules, included files and double-colon rules are answered by make itself.
One more question per unit asks for a random name no unit can define (`__monorepo_probe_<16 hex>`): an answer of 0 or 1
means the unit answers for ANY name (a `%:` rule or `.DEFAULT:`), and the unit is refused (`unit-target`, "answers for
any target name ... targets cannot be verified") by the check and by the runner, whatever its targets are: an explicit
rule cannot be told apart from a catch-all by exit status. Answers are cached per (unit, target) within one run. For an
app or package the function reads `package.json` `scripts`. A unit that lacks a mandatory target makes the runner
FAIL before any unit target is run, and `make check-fast` / `make verify` stop at the settings check first. The inspection is `make -C <unit> -q <target>`: make parses the unit's Makefile (a parse-time `$(shell ...)` runs, and an included file that has a rule may be remade) and, as GNU make does in question mode, executes the recipe lines marked `+` or containing `$(MAKE)` of the target and of its prerequisites, each recipe at most up to its first line that is neither; no other recipe line runs (measured on GNU make 3.81).
The runner runs each unit with stdin from `/dev/null`, reads the whole unit list before running any, refuses a
unit path that is a symlink or resolves outside the repository, announces how many units it will run and
asserts it ran that many.

## Limits

The inspection is `make -C <unit> -q <target>`: make parses the unit's Makefile (a parse-time `$(shell ...)` runs, and an included file that has a rule may be remade) and, as GNU make does in question mode, executes the recipe lines marked `+` or containing `$(MAKE)` of the target and of its prerequisites, each recipe at most up to its first line that is neither; no other recipe line runs (measured on GNU make 3.81). Under `-q` a recipe whose first line is `+`/`$(MAKE)` answers with
that sub-make's status. The root does not sandbox make: the units are the repository's own code and are trusted to the
degree `make check-fast` trusts them. No unit TARGET RECIPE is run for `check-fast`, `verify` or `test` when a mandatory
target is missing.

Scope boundary: the root can tell that make WOULD run something for a target; it cannot tell what a recipe does. A unit
whose `verify` recipe is `@:` or `@true`, or whose Makefile defines the rule only under a condition on `MAKEFLAGS` /
`MAKECMDGOALS`, has an owner who wrote a no-op on purpose; that is a review matter, not something this check claims to
catch.

Install scripts: `strictDepBuilds` and `onlyBuiltDependencies: []` govern DEPENDENCIES only. A workspace package's own
`preinstall` / `postinstall` / `prepare` scripts are the repository's own code and DO run on a plain `pnpm install`.
This module's root Makefile and root `package.json` have no install target (they only delegate to `monorepo-run.sh`);
a human or CI that installs should pass `--ignore-scripts` (`pnpm install --frozen-lockfile --ignore-scripts`), as the
live selftest does for its network installs.
Not proven: GNU make 4.x on a real Linux host (the execution facts above were measured on 3.81 only; GNU documents that lines marked `+` or containing `$(MAKE)` run even under `-q`).

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
