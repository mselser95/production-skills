# Host equivalence research — Claude Code vs Codex CLI (2026-11-27)

Input for Phase 4 (`_shared/hosts.md`). Sources: official docs fetched 2026-11-27
(developers.openai.com/codex → redirects to learn.chatgpt.com/docs; code.claude.com/docs;
agentskills.io/specification) plus the local binary (codex-cli 0.172.0). The doc pages show no
dates. `[LOCAL]` = seen in the binary only. `[DOC]` = official docs. Nothing here is proven by a
run unless it says MEASURED.

| Capability | Claude Code | Codex CLI | Equivalent |
|---|---|---|---|
| Skill format | SKILL.md + frontmatter | SKILL.md, `name` + `description` required | yes (portable core) |
| Skill roots | `~/.claude/skills`, `.claude/skills` | [DOC] `.agents/skills` (cwd→repo root), `$HOME/.agents/skills`, `/etc/codex/skills`; [LOCAL] `$CODEX_HOME/skills` | partial — CONFLICT doc vs binary, test |
| Explicit invoke | `/skill-name` | `/skills` or `$name` | partial |
| Disable a skill | `skillOverrides`, `disable-model-invocation` | `[[skills.config]] path/name + enabled=false` | partial |
| `allowed-tools` | honoured (pre-approves) | not documented | unknown |
| Skill list budget | description capped 1,536 chars in listing | list ≤ 2 % of context; `skills.max_context_tokens` ≤ 10,000 | partial |
| Subagent definition | `.claude/agents/*.md` (frontmatter) | `~/.codex/agents/*.toml` / `.codex/agents/*.toml`; keys `name`, `description`, `developer_instructions`, `model`, `model_reasoning_effort` | no — needs a generator |
| Per-agent tool allow-list | `tools` / `disallowedTools` | only `features.*=false` switches | partial → DEGRADED |
| Per-agent sandbox | `permissionMode` | not overridable, inherits parent | no → DEGRADED |
| Forbid spawning per role | omit `Agent` from `tools` | only global `agents.enabled=false` | no → DEGRADED (hook on `spawn_agent`) |
| Hooks config | `settings.json` `hooks` | `$CODEX_HOME/hooks.json`, `.codex/hooks.json`, or `[hooks]` in config.toml; needs `features.hooks` | partial |
| PreToolUse stdin | `tool_name`, `tool_input`, `tool_use_id`, `cwd`, ... | same fields (+ `turn_id`, `model`) | yes |
| PreToolUse deny | exit 2 + stderr, or `permissionDecision: deny` | same two shapes | yes |
| `tool_name` values | `Bash`, `Edit`, `Write`, `Agent` | `Bash`, `apply_patch`, `spawn_agent` (also matches `Agent`), `mcp__s__t` | partial — one script can serve both |
| Hook trust | none | hash-based trust; headless needs `--dangerously-bypass-hook-trust` | no |
| Headless | `claude -p --output-format json` | `codex exec --json` | partial |
| Spend cap | `--max-budget-usd` | none documented | no |
| Instructions file | CLAUDE.md (also reads AGENTS.md) | AGENTS.md (+ override), 32 KiB cap | partial |
| Auto memory | on by default, per project | `features.memories`, off by default | partial |

Portable core (agentskills.io): `name` ≤ 64 chars matching the dir, `description` ≤ 1024,
optional `license`, `compatibility`, `metadata` (string→string), `allowed-tools` (experimental).
"Keep SKILL.md under 500 lines", body < 5,000 tokens recommended, references one level deep and
relative to the skill root. → direct input for the Phase 3 size gate.

Suggested model mapping for Codex roles (inference, not documented): implementer `gpt-6-luna` or
`gpt-6.2-sol`; validator `gpt-6.2-astra`.

## Consequences

1. Agent definitions cannot be shared: generate Codex TOML from the `agents/*.md` source.
2. Three guarantees have no native Codex equivalent (tool allow-list, per-role sandbox, no-spawn):
   enforce by instruction text + a PreToolUse hook on `Bash`/`apply_patch`/`spawn_agent`, and mark
   DEGRADED until a run proves the hook blocks.
3. The existing dispatch-guard hook contract is nearly identical on both hosts; one script can
   serve both if it reads `tool_name` case-insensitively and handles `apply_patch` + `spawn_agent`.
4. Claude headless auth: the documented path is `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`
   (long-lived) or `ANTHROPIC_API_KEY`. Preferable to reading the keychain from a script.

## Unverified — test empirically

- Which Codex skill root actually wins, and whether `$CODEX_HOME/skills` is still scanned.
- Whether Codex `output_tokens` already includes `reasoning_output_tokens`.
- Subagents under `codex exec` (headless); nesting limit.
- Codex handling of unknown frontmatter keys; relative path resolution inside a skill.
- `claude --max-turns`: documented, but absent from this version's `--help`.
