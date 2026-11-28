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
| `Makefile` | `check-fast`, `verify`, `test`, `settings-check`: `settings-check` runs first and is a prerequisite of `check-fast` and `verify` (a red check stops before any unit runs); the runner then runs the same-named target in every unit of `repo.yaml`, one line per unit, stops at the first failure; no unit logic |
| `repo.yaml`, `docs/repo-schema.md` | the unit inventory and its schema |
| `scripts/monorepo-settings-check.sh`, `scripts/monorepo_check.py`, `scripts/monorepo-run.sh` | the static gate, the one `repo.yaml` reader, the Makefile's runner |
| `.gitignore`, `.editorconfig` | `.gitignore` merges by `union-lines` (`root_merge`), so a service that declares the same glob composes |

Workspace settings (keys checked against the option table of pnpm 10.34.3): `catalogMode: strict`,
`engineStrict`, `strictPeerDependencies`, `strictDepBuilds`, `onlyBuiltDependencies: []`,
`blockExoticSubdeps`, `minimumReleaseAge: 10080`, `trustPolicy: no-downgrade`. No `.npmrc` anywhere:
nothing needs it, and the check refuses the file by name. Moving to pnpm 11/12 renames
`onlyBuiltDependencies` to `allowBuilds`; change it and the pin together. The effect of `trustPolicy` and
`blockExoticSubdeps` is set, not demonstrated here.

## What the settings check enforces (`make settings-check`, exit 1, `file:line: rule message`)

The pinned pnpm's `catalogMode: strict` does not refuse a range at install time, so the check is the enforcement.
It is a set of ALLOW-lists, not a list of known-bad constructs:

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
- `package.json`, root and every workspace package: the fields `resolutions`, `overrides`, `pnpm`,
  `bundledDependencies`, `bundleDependencies` are refused (`supply-override`); every value in `dependencies`,
  `devDependencies`, `peerDependencies`, `optionalDependencies` is exactly `catalog:`, `catalog:<name>` (the entry
  must exist: `catalog-missing`) or `workspace:*`, nothing else (`non-catalog-dep`). `catalog:` is valid in
  `peerDependencies` (checked with a scratch install). `packageManager` is `pnpm@X.Y.Z`, optionally with
  `+sha512.<hex>`, and the same string wherever a package states one; a package's `engines` keys equal the
  root's; the root `engines` equal the shipped values exactly (`pm-engines`). `nvmrc`: `.nvmrc` inside `engines.node`.
- `repo.yaml` (`repo-yaml`, `unit-path`), `unit-unlisted` (a directory under `apps/`, `packages/`,
  `services/`, or `db/`, that is not in `repo.yaml`), `unit-target` (a unit lacks a mandatory target).

## Mandatory and optional unit targets

| kind | mandatory | optional (a missing one is a `skip` line) |
|------|-----------|-------------------------------------------|
| service | `check-fast`, `verify` | `test` |
| app, package | `test` | `check-fast`, `verify` |
| database | none | `check-fast`, `verify`, `test` |

One function decides "this unit has target T", used by the check and by `scripts/monorepo-run.sh`: for a service
or database it asks `make -C <unit> -n <T>` (exit 0 and at least one command line printed, so a name that is
only in `.PHONY`, a file of that name, or an empty recipe is not a target); for an app or package it reads
`package.json` `scripts`. A unit that lacks a mandatory target makes the runner FAIL before any unit runs. A target
that exists but does nothing (`verify: ; true`) cannot be judged by a tool and counts as present.
The runner runs each unit with stdin from `/dev/null`, reads the whole unit list before running any, refuses a
unit path that is a symlink or resolves outside the repository, announces how many units it will run and
asserts it ran that many.

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

Tested by `scripts/tests/monorepo-root-selftest.sh` (needs python3 with PyYAML).
