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
stanza can be generated from this file. A unit lacks a target when `make -C <unit> -n <target>` fails or prints
no command (service, database), or `package.json` has no such script (app, package): an optional one is a
`skip` line in the runner; a mandatory one above is refused by the settings check (`unit-target`) and FAILs the
runner before any unit runs. A target that exists but does nothing (`verify: ; true`) cannot be judged by a tool.
A directory `db/` must be listed (kind `database`) like `apps/*`, `packages/*` and `services/*`.
