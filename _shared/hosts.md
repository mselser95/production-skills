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
| Skill discovery path | copies nine skills to `$cfg/skills/<s>` | copies nine skills to `$CODEX_HOME/skills/<s>` | UNVERIFIED: no help text names a skills directory. The notes list `$CODEX_HOME/skills` as seen in the binary and `~/.agents/skills` / `.agents/skills` as documented, and call it a CONFLICT. Chosen: the binary-referenced one. `codex features list` shows `skip_host_skill_discovery` (under development), which only implies host-level discovery exists. Strings of the binary were not read: it lives under the real `~/.codex`, off limits here |
| `references/` symlinks | dereferenced into real files | dereferenced the same way (no symlink survives in the tree) | VERIFIED by selftest; whether Codex resolves relative paths inside a skill is UNVERIFIED |
| Skill frontmatter | `name`, `description`, `allowed-tools` etc. kept as is | kept as is | UNVERIFIED: Codex handling of unknown keys (`allowed-tools` is "not documented" there) |
| Agent / role definitions | copies `agents/*.md` to `$cfg/agents/` | generates `$CODEX_HOME/agents/<name>.toml` per agent: `name`, `description`, `developer_instructions` (= markdown body + restrictions block), `model` only if env-set | UNVERIFIED: location and keys are from the docs per the notes; `codex --help` and `codex features list` do not mention role files. `codex agents` exists but is a session browser, not role loading |
| Per-role model | frontmatter `model:` | see the mapping table | UNVERIFIED, DEGRADED: roles inherit the session model unless the operator sets a name, so the cheap-implementer / strong-validator split is not enforced |
| Per-role tool allow-list (`tools:`) | honoured by the host | restated in WORDS at the end of `developer_instructions`, derived from `tools:` (no Edit/Write -> "must not edit, create or delete files"; no Bash -> "must not run shell commands"; no Agent -> "must not spawn other agents") | DEGRADED: instruction-only; Codex has only `features.*` switches (notes, UNVERIFIED). A hook that enforces it does not exist yet |
| Per-role sandbox | `permissionMode` | nothing emitted; role inherits the parent | DEGRADED (notes: not overridable, UNVERIFIED) |
| Forbid spawning | omit `Agent` from `tools` | sentence in the restrictions block; the global `agents.enabled=false` is not touched | DEGRADED: a PreToolUse hook on `spawn_agent` would be the real guard (not built) |
| Hooks | not touched by the installer | not touched by the installer | `codex features list` shows `hooks  stable  true` and `plugin_hooks removed`: VERIFIED present; the notes' `hooks.json` shape is UNVERIFIED |
| Read-only install | `chmod -R a-w` on skills and `agents/prod-*.md` | `chmod -R a-w` on our nine skill dirs and `agents/prod-*.toml` only | VERIFIED by selftest; it removes the silent write, not a deliberate `chmod` |
| Integrity manifest | `$cfg/prod-skills.manifest`: sha256 of every skill file + whole `agents/` dir | `$CODEX_HOME/prod-skills.manifest`, same format: nine skills + `agents/prod-*.toml` only | VERIFIED by selftest |
| `--verify` exit codes | 1 TCB DRIFT, 2 STALE INSTALL, 3 TCB WRITABLE | identical codes and messages | VERIFIED by selftest |

## Decisions that follow

- The Codex manifest hashes only OUR files. A Codex home also holds the user's own skills,
  `.system`, roles and `config.toml`; hashing them would raise a drift alarm on every
  unrelated edit. The Claude manifest keeps hashing the whole `agents/` dir, unchanged.
- Foreign files in the Codex home are never chmodded read-only and never deleted.
- `--host both`: source-consistency (mirror pairs) runs once. Verify runs both hosts, names the
  failing one(s) on stderr (`install.sh: verify FAILED for: codex(exit 1)`), and exits with the
  lowest non-zero code (1 outranks 2 outranks 3).
- A role body containing three consecutive single quotes cannot be written as a TOML literal
  string; the installer refuses instead of escaping.

## Still to settle with a real Codex session

1. Which skills root the binary scans (`$CODEX_HOME/skills` vs `~/.agents/skills`).
2. Whether `$CODEX_HOME/agents/*.toml` is read and the four keys are accepted.
3. Model names per role, and whether `model_reasoning_effort` should be set.
4. A hook that enforces the DEGRADED rows above, proven by a run that it blocks.
