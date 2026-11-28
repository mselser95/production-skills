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
  Makefile has a catch-all rule).

## Mandatory and optional unit targets

| kind | mandatory | optional (a missing one is a `skip` line) |
|------|-----------|-------------------------------------------|
| service | `check-fast`, `verify` | `test` |
| app, package | `test` | `check-fast`, `verify` |
| database | none | `check-fast`, `verify`, `test` |

One function decides "this unit has target T", used by the check and by `scripts/monorepo-run.sh`: for a service
or database it asks make for its own verdict, `make -C <unit> -n <T>` with stdout and stderr captured. T is present
only when make exits 0, does not say `Nothing to be done for T` or `T is up to date` (GNU make 3.81 and 4.x
wordings; the `make[N]:` form of a sub-make counts as noise, so a recipe that forwards with `$(MAKE)` is a recipe),
and prints at least one line that is not a `make: Entering/Leaving directory` notice. So a name only in `.PHONY`
(with or without a `$(info)` banner) and an empty recipe are not targets. A target whose name is also a FILE in the
unit directory, with no prerequisites and no `.PHONY`, makes make say "is up to date": it is reported missing, and
the fix is `.PHONY: <target>`. A catch-all rule (`%:` or `.DEFAULT:`) answers any name, so a mandatory target could
not be told from a forwarded one: a unit whose Makefile answers a random probe name is refused (`unit-target`,
`catch-all rule: targets cannot be verified`), by the check and by the runner. For an app or package the function
reads `package.json` `scripts`. A unit that lacks a mandatory target makes the runner FAIL before any unit target is
run, and `make check-fast` / `make verify` stop at the settings check first. A target that exists but does nothing
(`verify: ; true`) cannot be judged by a tool and counts as present.
The runner runs each unit with stdin from `/dev/null`, reads the whole unit list before running any, refuses a
unit path that is a symlink or resolves outside the repository, announces how many units it will run and
asserts it ran that many.

## Limits

The check inspects units by asking make (`make -n`). That evaluates the unit Makefile: a parse-time `$(shell ...)`,
a `+`-prefixed recipe line or a `$(MAKE)` line can still execute code. The root does not sandbox make. What it
guarantees is narrower and true: no unit TARGET RECIPE is run for `check-fast`, `verify` or `test` when a mandatory
target is missing. The units are the repository's own code and are trusted to the same degree `make check-fast`
trusts them. Not proven: GNU make 4.x on a real Linux host (its wordings are asserted with a fake `make`).

## Adding a unit

Create its directory (`services/<name>`, `apps/<name>`, `packages/<name>`, or `db`) and add one entry
to `repo.yaml`. Nothing else in this module changes. The unit brings its own `Makefile` (service) or
`package.json` scripts (app, package) and takes dependency versions from the catalog.

## The lockfile

`pnpm-lock.yaml` is placed at the root (one file, generated with `pnpm install --lockfile-only --ignore-scripts` from the assembled monorepo-root + design-system workspace; importers are `packages/*`, so service ids do not matter). Catalog versions are at least 7 days old when it is generated. It names `@ds-scope/*`, so it matches only `--slot SCOPE=ds-scope`.

## Not here

A CI workflow, at the repository root, that calls each unit's workflow (a unit's own `.github/workflows/` under `services/<id>/` is not read by GitHub), a CI workflow that runs `pnpm install --frozen-lockfile` (the settings check itself runs in `make check-fast` and `make verify`), the
root `production.yaml` v2 `units:` stanza (a later step generates it from `repo.yaml`), the tools a unit
uses (eslint, vitest config), Docker.

Tested by `scripts/tests/monorepo-root-selftest.sh` (needs python3 with PyYAML). The default run is hermetic
(no pnpm, no network) and is what CI runs; `MONOREPO_LIVE=1`, set by a human with pnpm 10.34.3 and the registry,
adds the live pnpm cases.
