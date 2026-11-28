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
| Agent / role definitions | copies every `agents/*.md` to `$cfg/agents/` | generates `$CODEX_HOME/agents/<name>.toml` for each `agents/prod-*.md` only (other agent files are NOT installed for Codex; stderr says so): `name`, `description`, `developer_instructions` (= markdown body + restrictions block), `model` only if env-set. Strings are TOML basic strings with `\`, `"` and every control character escaped; when python3 has `tomllib` every file is parsed back and compared with the intended values before anything is written (otherwise UTF-8 validity + the escaper, see below) | VERIFIED 2026-11-27 that `name` and `description` are read and the role is listed (`codex debug prompt-input`, section below); UNVERIFIED for `developer_instructions` and `model`. `codex --help` and `codex features list` do not mention role files. `codex agents` exists but is a session browser, not role loading |
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
| 6 | the lock exists: live owner, dead owner or unreadable owner (the message says which; never stolen) | - | new |
| 7 | a copy / move / chmod failed, or the lock directory / the private work directory could not be created; the host was rolled back, no manifest written | - | new |
| 129, 130, 143 | HUP, INT, TERM: the commit finished or was rolled back first; never half-installed (a signal after the commit point lets the install complete, exit 0) | - | new |

(`2` is both "STALE INSTALL" on `--verify` and "usage" on a bad `--host`, as on master.)

- **Symlinks, Codex:** `skills/`, `agents/`, the manifest, each of our nine skill dirs and each
  generated role file are `lstat`-ed before anything is written; a symlink at any of them is
  refused (exit 4), even with `--adopt`: it is the user's. Nothing is ever written, `chmod`-ed or
  removed through a symlink: units are moved aside whole by `mv` (a rename acts on the link
  itself), the work directory is made writable with `find -type d -exec chmod` (no `-L`) before it
  is removed, `rm -rf` never follows links, and the manifest is replaced by rename. `$CODEX_HOME` itself may be a symlink (a dotfiles layout).
- **Ownership, Codex:** a destination (skill dir or role file) is replaced only if the host's
  PREVIOUS manifest lists it. Otherwise: exit 5 `refusing to overwrite <path>: not installed by
  this tool; move it away or pass --adopt`, with nothing installed (all destinations of the chosen
  hosts are checked before the first write). `--adopt` (per run) moves each such destination to
  `<config root>/.prod-backups/<UTC timestamp>-<random>/{skills,agents}/` (created by `mktemp -d`, so
  two adoptions in one second get two directories; outside `skills/` and `agents/`, so Codex never
  discovers a backed-up `SKILL.md` as a duplicate skill) and prints that path; installs; nothing is
  ever deleted that this tool did not install. Foreign files are never `chmod`-ed read-only either.
- **Claude keeps its historical behaviour** (a KNOWN LIMITATION, to be fixed under its own
  change): it replaces `skills/<our nine names>` and every `agents/*.md` of the same name with no
  ownership check and no symlink refusal, `--adopt` is ignored, and a symlinked `skills/` or
  `agents/` directory is followed. The Codex path is stricter. What is NOT changed on Claude:
  the default flow's output, tree, modes and manifest.
- **One private work directory per host per run; all-or-nothing:** right after the lock, the
  installer creates `<config root>/.prod-work.XXXXXXXX` with `mktemp -d` (random name, created
  atomically, mode 0700, inside the config root so every rename stays on one filesystem; a
  `skills/` that is a symlink to another filesystem makes the rename a copy, which is yours to
  avoid). EVERYTHING temporary lives in it: `stage/skills/<name>`, `stage/agents/<file>`,
  `trash/skills/<name>`, `trash/agents/<file>`, `chk/` (the TOML-check sidecar files) and
  `manifest.new`. There is no pid-derived or otherwise predictable name anywhere, and a
  directory that was created a moment ago by `mktemp -d` cannot contain anything planted, so
  `cp -R`, `>` and `mv` into it never follow somebody else's symlink. The commit then renames: each
  existing destination into `work/trash` (or into the `--adopt` backup directory), its stage into
  place, after checking that the destination name is free (it was just moved away; if something
  appeared in between the host is rolled back). A failure renames everything back; a SIGINT,
  SIGTERM or SIGHUP only sets a flag that the commit loop reads BETWEEN units, so it never exits
  between "moved aside" and "moved in": it rolls back what it renamed and exits 130/143/129. The
  manifest is built in `work/manifest.new`, `chmod 0444` (Codex), and renamed into place as the
  final step (the commit point; a symlinked manifest is removed as a link first, because `mv` would
  move INTO a link to a directory). The replaced copies are deleted only after that, with the
  work directory. A failed first install leaves nothing behind. `--host both` is per host: when the
  second host fails after the first committed, stderr says so (`install: claude: installed; codex:
  rolled back (exit 7)`) and the exit code is the second host's; the first stays installed.
  Cleanup removes only the exact work directory this run created; a leftover `.prod-work.*` from a
  killed run (SIGKILL cannot be caught) is never touched: one stderr line names it
  (`stale work directory from an interrupted install: <path>; it is safe to delete`; if one of our
  skills is missing from the home, its previous copy may be under `<path>/trash`). A rollback
  that cannot put a previous copy back keeps the work directory and says where it is. Outside
  the work directory the installer only creates the config root and the two destination
  directories, takes the lock, and performs the renames above (plus a `chmod u+w` of the top
  directory of a read-only unit it is about to move, because on Linux a read-only directory cannot
  change parent; undone on rollback).
- **Lock:** `<config root>/.prod-skills.lock` (a `mkdir`), taken for every chosen host before any
  check, removed on exit by a trap. If it exists the installer reads the owner pid safely (a
  regular file, not a symlink or FIFO; at most 16 bytes; digits only; anything else is "owner
  unreadable" and no file content is ever echoed) and says which case it is: a live owner
  (`another install is running`), a dead one (`stale lock ... its owner, pid N, is not running`,
  with the exact `rm -rf '<lock>'` to run), or unreadable; exit 6 each time, and it is never
  stolen. A directory that cannot be created for another reason (a read-only config root) is exit
  7 with the reason, not "another install is running".
- **Verify compares (path, hash) rows,** not hashes: every file the source would install must
  be in the manifest at that path with that hash (STALE otherwise), the manifest's skill rows
  must be exactly those paths (an extra path, or a file at the wrong place, is STALE, exit 2,
  named as `extra:`), every source agent must be installed (Claude: by hash; Codex: one
  `prod-*.toml` per `agents/prod-*.md`, exactly). On Codex the roles are REGENERATED from the
  current source (the installer's own generator, into a scratch directory inside a private
  `mktemp -d` under `$TMPDIR`) and compared as (hash, path) rows, like Claude's verbatim copies.
  Same situation, same code on both hosts: an installed role/agent edited and the manifest
  rewritten to match is 2 STALE (the row the source would install is not in the manifest); a source
  agent edited and not reinstalled is 2; an installed role edited with the manifest untouched is
  1 DRIFT. Run verify with the same `PROD_CODEX_MODEL_*` variables as the install, or the
  regenerated role differs (STALE).
- **Modes, Codex:** `umask 022` is set before ANY directory is created (the lock step creates
  `$CODEX_HOME` itself when it is missing) and the installer chmods the directories it creates
  (`$CODEX_HOME`, `skills/`, `agents/`) to 0755, whatever the caller's umask; files take the
  source's own modes, then are made read-only; manifest 0444; the private work directory is 0700.
  Claude inherits the caller's umask as before. A directory that already existed keeps its mode.
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
  overwritten either, unless you pass `--adopt`, which moves them under
  `<config root>/.prod-backups/` first (see the contract above).
- `--host both`: source-consistency (mirror pairs) runs once. Verify runs both hosts, names the
  failing one(s) on stderr (`install.sh: verify FAILED for: codex(exit 1)`), and exits with the
  lowest non-zero code (1 outranks 2 outranks 3).
- Role files are TOML basic strings, so no body is un-representable (`'''`, `"""`, CR, tabs,
  control characters are escaped; non-ASCII passes through); a NUL byte, invalid UTF-8 (checked
  on the whole source file with `iconv`, else python3's strict decoder, else refused: never
  written unvalidated), a frontmatter `name` that is not `^[a-z][a-z0-9-]*$` or differs from the
  file name are refused. For valid UTF-8 the escaper is total. The parse check needs python3 with
  `tomllib` (3.11+); without it (stock macOS python3 is 3.9) the installer says so on stderr and
  relies on the UTF-8 check plus the escaper, which the selftest proves with a strict reader of
  exactly the subset the generator emits. Role texts reach python through files, never argv (a 2
  MB body works).

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
