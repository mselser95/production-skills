# Hosts: what `install.sh --host claude|codex|both` relies on

Checked 2026-11-27 against `codex-cli 0.172.0` (`codex --version`). Every claim carries one
label. VERIFIED says how. UNVERIFIED means no command on this machine settled it and the
installer took the conservative option. DEGRADED marks a guarantee weaker on Codex than on
Claude Code. Source of the doc-derived rows: `notes/hosts-research-2026-11-27.md` (official
docs fetched that day; those pages carry no dates). No real Codex session has loaded anything
this installer produces.

## Model mapping (Claude name -> Codex model)

| Claude `model:` | Codex `model` emitted | Label |
|---|---|---|
| `sonnet` (implementer, acceptance-author) | omitted: role inherits the session model | UNVERIFIED (no documented equivalence) |
| `opus` (validator) | omitted: role inherits | UNVERIFIED |
| `haiku` (scout, mechanic) | omitted: role inherits | UNVERIFIED |
| override | `PROD_CODEX_MODEL_<ROLE>` env at install time, e.g. `PROD_CODEX_MODEL_SCOUT=<model>`; `<ROLE>` = agent name without `prod-`, upper-case, `-` as `_` | VERIFIED by selftest only (the installer writes the key); the model NAME is the operator's |

The notes suggest `gpt-6-luna` / `gpt-6.2-sol` (implementer) and `gpt-6.2-astra` (validator).
That is inference, not documented, so it is NOT baked in. `model_reasoning_effort` is not
emitted (UNVERIFIED mapping).

## Capability table

| Capability | Claude Code: installer does | Codex: installer does | Label |
|---|---|---|---|
| Config root | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` | `${CODEX_HOME:-$HOME/.codex}` | VERIFIED: `codex exec --help` names `$CODEX_HOME` ("auth still uses CODEX_HOME", "Layer $CODEX_HOME/<name>.config.toml"); `codex --help` names `~/.codex/config.toml` |
| Skill discovery path | copies nine skills to `$cfg/skills/<s>` | copies nine skills to `$CODEX_HOME/skills/<s>` | VERIFIED 2026-11-27 for `$CODEX_HOME/skills` by `codex debug prompt-input` (section below; the other roots were not tried). Older note: no help text names a skills directory. The notes list `$CODEX_HOME/skills` as seen in the binary and `~/.agents/skills` / `.agents/skills` as documented, and call it a CONFLICT. Chosen: the binary-referenced one. `codex features list` shows `skip_host_skill_discovery` (under development), which only implies host-level discovery exists. Strings of the binary were not read: it lives under the real `~/.codex`, off limits here |
| `references/` symlinks | dereferenced into real files | dereferenced the same way (no symlink survives in the tree) | VERIFIED by selftest; whether Codex resolves relative paths inside a skill is UNVERIFIED |
| Skill frontmatter | `name`, `description`, `allowed-tools` etc. kept as is | kept as is | UNVERIFIED: Codex handling of unknown keys (`allowed-tools` is "not documented" there) |
| Agent / role definitions | copies every `agents/*.md` to `$cfg/agents/` | generates `$CODEX_HOME/agents/<name>.toml` for each `agents/prod-*.md` only (other agent files are NOT installed for Codex; stderr says so): `name`, `description`, `developer_instructions` (= markdown body + restrictions block), `model` only if env-set. Strings are TOML basic strings with `\`, `"` and every control character escaped; every file is parsed back and compared with the intended values before anything is written | VERIFIED 2026-11-27 that `name` and `description` are read and the role is listed (`codex debug prompt-input`, section below); UNVERIFIED for `developer_instructions` and `model`. `codex --help` and `codex features list` do not mention role files. `codex agents` exists but is a session browser, not role loading |
| Per-role model | frontmatter `model:` | see the mapping table | UNVERIFIED, DEGRADED: roles inherit the session model unless the operator sets a name, so the cheap-implementer / strong-validator split is not enforced |
| Per-role tool allow-list (`tools:`) | honoured by the host | restated in WORDS at the end of `developer_instructions`, derived from `tools:` (no Edit/Write -> "must not edit, create or delete files"; no Bash -> "must not run shell commands"; no Agent -> "must not spawn other agents"). A role with NO `tools:` line gets the sentence "declares no tool restriction" and no bans (on Claude Code it inherits every tool) | DEGRADED: instruction-only; Codex has only `features.*` switches (notes, UNVERIFIED). A hook that enforces it does not exist yet |
| Per-role sandbox | `permissionMode` | nothing emitted; role inherits the parent | DEGRADED (notes: not overridable, UNVERIFIED) |
| Forbid spawning | omit `Agent` from `tools` | sentence in the restrictions block; the global `agents.enabled=false` is not touched | DEGRADED: a PreToolUse hook on `spawn_agent` would be the real guard (not built) |
| Hooks | not touched by the installer | not touched by the installer | `codex features list` shows `hooks  stable  true` and `plugin_hooks removed`: VERIFIED present; the notes' `hooks.json` shape is UNVERIFIED |
| Read-only install | `chmod -R a-w` on skills and `agents/prod-*.md` | `chmod -R a-w` on our nine skill dirs and `agents/prod-*.toml` only | VERIFIED by selftest; it removes the silent write, not a deliberate `chmod` |
| Integrity manifest | `$cfg/prod-skills.manifest`: sha256 of every skill file + whole `agents/` dir | `$CODEX_HOME/prod-skills.manifest`, same format: nine skills + `agents/prod-*.toml` only | VERIFIED by selftest |
| `--verify` exit codes | 1 TCB DRIFT, 2 STALE INSTALL, 3 TCB WRITABLE | identical codes and messages | VERIFIED by selftest |

## Ownership, symlinks, locking, failure (install-time contract)

Exit codes of `install.sh` (old = the script on master; new adds 4-7, nothing else moves):

| Code | Meaning | Old | New |
|---|---|---|---|
| 0 | ok | yes | yes |
| 1 | TCB DRIFT (verify); source drift / no manifest; a Codex role file or source symlink refused | yes | yes (+ refusals) |
| 2 | STALE INSTALL (verify); usage error | yes | yes |
| 3 | TCB WRITABLE (verify) | yes | yes |
| 4 | destination is a symlink (Codex tree) | - | new |
| 5 | destination exists and is not ours (Codex), `--adopt` not given | - | new |
| 6 | another install holds the lock | - | new |
| 7 | a copy / move / chmod failed; the host was rolled back, no manifest written | - | new |

(`2` is both "STALE INSTALL" on `--verify` and "usage" on a bad `--host`, as on master.)

- **Symlinks, Codex:** `skills/`, `agents/`, the manifest, each of our nine skill dirs and each
  generated role file are `lstat`-ed before anything is written; a symlink at any of them is
  refused (exit 4), even with `--adopt`: it is the user's. Nothing is ever written, `chmod`-ed or
  removed through a symlink: units are moved aside whole by `mv` (a rename acts on the link
  itself), the trash is unlocked with `find ! -type l`, `rm -rf` never follows links, and the
  manifest is replaced by rename. `$CODEX_HOME` itself may be a symlink (a dotfiles layout).
- **Ownership, Codex:** a destination (skill dir or role file) is replaced only if the host's
  PREVIOUS manifest lists it. Otherwise: exit 5 `refusing to overwrite <path>: not installed by
  this tool; move it away or pass --adopt`, with nothing installed (all destinations of the chosen
  hosts are checked before the first write). `--adopt` (per run) moves each such destination to
  `<path>.bak.<timestamp>` and installs; nothing is ever deleted that this tool did not install.
  Foreign files are never `chmod`-ed read-only either.
- **Claude keeps its historical behaviour** (a KNOWN LIMITATION, to be fixed under its own
  change): it replaces `skills/<our nine names>` and every `agents/*.md` of the same name with no
  ownership check and no symlink refusal, `--adopt` is ignored, and a symlinked `skills/` or
  `agents/` directory is followed. The Codex path is stricter. What is NOT changed on Claude:
  the default flow's output, tree, modes and manifest.
- **Staging, all-or-nothing per host:** every skill and role is built beside its destination
  (`.prod-stage.<pid>.*`); only when all are built does the commit start: each existing
  destination is renamed to trash (or `.bak.<ts>`), its stage renamed in; any failure renames
  everything back. The manifest is built last in a temp file, `chmod 0444` (Codex), and renamed
  into place as the final step, so an incomplete install never leaves a manifest. The replaced
  copies are deleted only after that. A failed first install leaves nothing behind. `--host both`
  is per host: a second host failing leaves the first installed.
- **Lock:** `<config root>/.prod-skills.lock` (a `mkdir`), taken for every chosen host before any
  check, removed on exit by a trap. A held lock exits 6; one older than 10 minutes is reported
  as stale with its pid and is never stolen: remove it by hand once no install is running.
- **Verify compares (path, hash) rows,** not hashes: every file the source would install must
  be in the manifest at that path with that hash (STALE otherwise), the manifest's skill rows
  must be exactly those paths (an extra path, or a file at the wrong place, is STALE, exit 2,
  named as `extra:`), every source agent must be installed (Claude: by hash; Codex: one
  `prod-*.toml` per `agents/prod-*.md`, exactly). Not checked on Codex: whether a generated role
  file still matches what the CURRENT source would generate (the source has no hash for it;
  tampering is caught by the manifest, a source edit that is not reinstalled is not).
- **Modes, Codex:** the install runs under an explicit `umask 022` (directories 0755, files from
  the source's own modes, then read-only; manifest 0444), whatever the caller's umask. Claude
  inherits the caller's umask as before.
- **Source symlinks:** a dangling symlink anywhere in a skill source is an error for Codex
  (exit 1, naming it, nothing written). Claude keeps dropping it silently.
- **Healthy-flow differences on Claude** (the only ones): `--verify` is path-aware and also
  checks installed agents against the source; installs take the lock, check every step and
  roll back; the blanket `chmod -R u+w` over `skills/` and `agents/` (which also unlocked
  foreign files and could not be undone) is gone; a symlinked manifest is replaced instead of
  written through.

## Decisions that follow

- The Codex manifest hashes only OUR files. A Codex home also holds the user's own skills,
  `.system`, roles and `config.toml`; hashing them would raise a drift alarm on every
  unrelated edit. The Claude manifest keeps hashing the whole `agents/` dir, unchanged.
- Foreign files in the Codex home are never chmodded read-only. They are never deleted or
  overwritten either, unless you pass `--adopt`, which moves them to `<path>.bak.<timestamp>`
  first (see the contract above).
- `--host both`: source-consistency (mirror pairs) runs once. Verify runs both hosts, names the
  failing one(s) on stderr (`install.sh: verify FAILED for: codex(exit 1)`), and exits with the
  lowest non-zero code (1 outranks 2 outranks 3).
- Role files are TOML basic strings, so no body is un-representable (`'''`, `"""`, CR, tabs,
  control characters, non-ASCII are escaped); a NUL byte, invalid UTF-8, a frontmatter `name`
  that is not `^[a-z][a-z0-9-]*$` or differs from the file name are refused. The parse check
  needs python3 with `tomllib` (3.11+); without it the installer says so on stderr and relies
  on the escaper alone.

## What `codex features list` says about multi-agent support (re-checked 2026-11-27)

Run with the real binary (`codex-cli 0.172.0`), `HOME` and `CODEX_HOME` pointed at an empty temp
directory (nothing under a real home was read or written; the binary reports its own install path):

```
multi_agent                              deprecated         true
multi_agent_mode                         removed            false
multi_agent_v2                           stable             false
multi_agent_v2_dynamic_tools             under development  false
hooks                                    stable             true
plugin_hooks                             removed            false
skill_search                             stable             true
skip_host_skill_discovery                under development  false
```

AT RISK: the multi-agent switch this role mechanism sits behind is `deprecated` (still on) and its
successor `multi_agent_v2` is `stable` but OFF by default in this version. Role files are
listed to the model today (below), but this installer cannot say that a future version, or a
default config with `multi_agent_v2` on, still honours `agents/*.toml` the same way. Nothing here
changes any feature flag.

## How to check that Codex sees the skills and roles, without a model call

`codex debug prompt-input "x"` renders, locally, the model-visible prompt input as JSON (rc 0, no
credentials, no network turn). With `HOME=<tmp>`, `CODEX_HOME=<tmp>/codex` after
`install.sh --host codex`, on 0.172.0 (run on 2026-11-27):

- each of our nine skills appears as `- prod-<name>: <description> (file: r0/prod-<name>/SKILL.md)`:
  VERIFIED that `$CODEX_HOME/skills/<s>/SKILL.md` with our frontmatter is discovered
  (`r0` is the binary's alias for the skills root, whose path it prints as `$CODEX_HOME/skills`);
- each generated role appears as `prod-<name>: { <description> }` (checked: `prod-scout`,
  `prod-validator`, `prod-acceptance-author`, `prod-implementer`, `prod-mechanic`): VERIFIED that
  `$CODEX_HOME/agents/<name>.toml` is parsed and its `name` and `description` are read.

Cannot be checked without a model call, and are UNVERIFIED: that a spawned role runs with our
`developer_instructions`; that the `model` key is honoured; that a skill's `references/` are
followed; that anything the DEGRADED rows above restate in words is obeyed; that `multi_agent_v2`
off still allows spawning. `codex doctor` checks installation, auth and runtime, not skills.

## Still to settle with a real Codex session

1. Whether `~/.agents/skills` is also scanned (`$CODEX_HOME/skills` is, see above).
2. Whether a spawned role applies `developer_instructions` and `model` (name and description are listed).
3. Model names per role, and whether `model_reasoning_effort` should be set.
4. A hook that enforces the DEGRADED rows above, proven by a run that it blocks.
