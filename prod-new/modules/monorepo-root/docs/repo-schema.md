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
| service | go, rust, python | `services/<name>` | the unit's `Makefile` (`check-fast` and `verify` are required) |
| app | ts | `apps/<name>` | `package.json` scripts (`test` required; `check-fast`, `verify` optional) |
| package | ts | `packages/<name>` | the same |
| database | sql | `db` | the unit's `Makefile`, whichever of the targets it defines (none required) |

The field names follow the root `production.yaml` v2 `units:` stanza (`id`, `database`), so that
stanza can be generated from this file. A unit target the unit does not define is reported as
`skip` by the Makefile and, for the required ones above, refused by the settings check.
