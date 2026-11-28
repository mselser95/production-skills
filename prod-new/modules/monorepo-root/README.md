# monorepo-root

The part of a greenfield monorepo that no single service or app owns: the root files two modules
would otherwise collide on. Layout `monorepo` only (in `single` its root files would collide with the
service's own `Makefile`). Not placed in the assembled repo (`exclude`): this README.

## What it owns (placed at the repository root)

| File | What it is |
|------|------------|
| `package.json` | private; `packageManager: pnpm@10.34.3`, `engines` (node `>=24 <27`, pnpm `>=10.34.3 <13`); scripts only delegate to `make` |
| `pnpm-workspace.yaml` | workspace globs `apps/*` and `packages/*`; the ONE `catalog:` (every version is written here); install policy (below) |
| `.nvmrc` | `26`, inside `engines.node` |
| `tsconfig.base.json` | the strict TypeScript base every TS unit extends; this module is its only owner |
| `Makefile` | `check-fast`, `verify`, `test`, `settings-check`: runs the same-named target in every unit of `repo.yaml`, one line per unit, stops at the first failure; no unit logic |
| `repo.yaml`, `docs/repo-schema.md` | the unit inventory and its schema |
| `scripts/monorepo-settings-check.sh`, `scripts/monorepo_check.py`, `scripts/monorepo-run.sh` | the static gate, the one `repo.yaml` reader, the Makefile's runner |
| `.gitignore`, `.editorconfig` | `.gitignore` merges by `union-lines` (`root_merge`), so a service that declares the same glob composes |

Workspace settings (keys checked against the option table of pnpm 10.34.3): `catalogMode: strict`,
`engineStrict`, `strictPeerDependencies`, `strictDepBuilds`, `onlyBuiltDependencies: []`,
`blockExoticSubdeps`, `minimumReleaseAge: 10080`, `trustPolicy: no-downgrade`. No root `.npmrc`: nothing
needs it, and a second home for settings is what the check refuses. Moving to pnpm 11/12 renames
`onlyBuiltDependencies` to `allowBuilds`; change it and the pin together.

## What the settings check refuses (`make settings-check`, exit 1, `file:line: rule message`)

`non-catalog-dep` (a version that is not `catalog:` or `workspace:*` in `dependencies`,
`devDependencies`, `optionalDependencies`; peers are not checked), `catalog-missing`, `pm-engines`
(root `packageManager` / `engines` missing; a package that states a different one), `nvmrc`,
`second-lockfile` (`package-lock.json`, `yarn.lock`, `bun.lock*`, a nested `pnpm-lock.yaml`),
`supply-override` (a nested `pnpm-workspace.yaml`, a `.npmrc` key, a `pnpm` field),
`root-settings` (the root file lacks or weakens a setting), `repo-yaml` (schema), `unit-path`,
`unit-unlisted` (a directory under `apps/`, `packages/`, `services/` that is not in `repo.yaml`),
`unit-target` (a service without `check-fast`/`verify`, an app or package without a `test` script).

## Adding a unit

Create its directory (`services/<name>`, `apps/<name>`, `packages/<name>`, or `db`) and add one entry
to `repo.yaml`. Nothing else in this module changes. The unit brings its own `Makefile` (service) or
`package.json` scripts (app, package) and takes dependency versions from the catalog.

## Not here

The lockfile (`pnpm-lock.yaml` depends on the units; create it once with `pnpm install` online and
commit it), the CI workflow that runs `make settings-check` and `pnpm install --frozen-lockfile`, the
root `production.yaml` v2 `units:` stanza (a later step generates it from `repo.yaml`), the tools a unit
uses (eslint, vitest config), Docker.

Tested by `scripts/tests/monorepo-root-selftest.sh` (needs python3 with PyYAML).
