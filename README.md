# production-skills

The skills that operate a production-verifiability framework — one to CREATE a
repo at the standard (`prod-new`), one to bring an existing one to it
(`prod-bootstrap`), and seven to work inside it: an
intelligence-arbitrage loop where **expensive models orchestrate, cheap models
implement, and a deterministic verifier decides**. Each skill removes a class
of ambiguity so the work downstream of it becomes obvious enough for a smaller
model — that is the whole design.

Every skill is organization-agnostic. Every company-specific fact — spec paths,
gate commands, registry locations, budgets — lives in a local `config.sh` that
is never committed. No `SKILL.md` names an org, repo, team, or channel.

All skills share one governance preamble (`_shared/preamble.md`), four
interface formats (`_shared/formats/`): the resolved context, the change plan,
test provenance, and the incident fixture — plus the review audit engine
(`_shared/review-depth.md`) and the AGENTS.md routing-contract template
(`_shared/agents-template.md`) that `prod-bootstrap` installs so every agent
request in a governed repo passes through the pipeline. The formats are the
contracts of the whole system — skills are replaceable, the formats are not.

`_shared/chaos-load-framework.md` is the operational procedure for the two
dimensions nobody executes by reading: load (§25) and chaos (§13/§20/§26). Nine
steps, each with a "not ready if" condition, and a set of mandatory controls
that exist because each one's absence produced a green false result in one of
the 34 demos. It is what a "build the load/chaos experiments for X" request
resolves to, and it is referenced from every skill that can be asked for one.

Everything above is scoped to ONE repo. `_shared/domain-boundaries.md` is the
one layer above that: DOMA-style domain ownership (`foundational`/`derived`/
`aggregate`), a `domain_gateway` capability class, and the invariant that a
service outside a domain may depend only on that domain's declared gateway,
never its datastore. It is entirely OPT-IN — gated on an org-level
`_shared/domain-topology.yaml` (copy from `domain-topology.example.yaml`,
gitignored like every skill's `config.sh`) that a single-service org never
needs to create. Absent, every domain-aware step in every skill below is a
silent no-op.

| Skill | Tier | What it does |
|---|---|---|
| [`prod-spec/`](prod-spec/) | orchestrator | Intent → resolved context (~30 lines) + change plan. Writes no code. Hosts the T0 human moment. |
| [`prod-review/`](prod-review/) | orchestrator | Hard senior review of a diff vs its contract: divergence recompute, gap discovery, provenance audit, plus the full audit engine (idiom recon, blocker calibration, 10 review areas). Fixes nothing. |
| [`prod-incident/`](prod-incident/) | orchestrator | Incident → minimized invariant-asserting fixture + candidate-invariant package (both-direction evidence) + missing-signal report + gate attribution. |
| [`prod-implement/`](prod-implement/) | implementer | One bounded task inside its contract; iterates against the cheap gate under a TCB write-mask; bounded iterations; honest bail with state. |
| [`prod-test-synth/`](prod-test-synth/) | implementer | Candidate-lane tests at volume, provenance-headed and TTL'd, with generator adequacy self-checks. Cannot touch the blocking lane. |
| [`prod-ops/`](prod-ops/) | implementer | The mechanical pipeline layer: bisect, revert, flake classification, quarantine, liability sweeps, rebases. T0-invariant flakes escalate as incidents. |
| [`prod-new/`](prod-new/) | orchestrator (interactive) | **Greenfield**: create a NEW repo born at the standard — three zones, tracing, event sourcing, metrics + contracts, outbox, invariant counters, conformance kits, registries with expiry, every lane wired. Four questions, everything else derived. |
| [`prod-bootstrap/`](prod-bootstrap/) | orchestrator (interactive) | Bring a repo to standard: inventory → human Q&A → spec + scaffold + AGENTS.md routing contract + gap report + ratchet refactor plan. |
| [`prod-curate/`](prod-curate/) | curation (mixed) | Batch promotion (change-detector screening, mutant-utility dedup, known-bad katas) + ratification packages so human adjudication takes minutes. |

Two rules bind every skill (see the preamble for the rest):

- **Skills may infer intent; they may never invent policy.** The escape is a
  waiver proposal with a mandatory expiry, adjudicated by a human.
- **These SKILL.md files are themselves part of the trusted computing base.**
  A weakened skill prompt is another path to green; changes to this repo go
  through the same approval flow as a ratified invariant.

## The dispatch layer

The economics run through `_shared/dispatch.md` (the routing table: session
model thinks, pinned agents execute) and three agent definitions in
`agents/`: `prod-scout` (haiku, read-only recon), `prod-implementer` (sonnet,
one bounded task under the write-mask), `prod-acceptance-author` (sonnet,
writes the acceptance tests for an approved `acceptance/<feature>.yaml`
before implementation), `prod-mechanic` (haiku, prod-ops operations and
curation screening). Orchestrator skills dispatch; they do not
do mechanical work inline. Model pins live in the agent frontmatter —
retargeting a tier is a one-line change there, never a skill edit.

## Install

**New here? Read [`QUICKSTART.md`](QUICKSTART.md)** — install, the one decision
per repo, the three commands you will actually type, and what to do when a gate
goes red. The rest of this file is reference.

```bash
git clone git@github.com:mselser95/production-skills.git
cd production-skills
for s in prod-*/; do
  [ -f "$s/config.sh" ] || cp "$s/config.example.yml" "$s/config.sh"
done
$EDITOR */config.sh
bash install.sh && bash install.sh --verify
```

`install.sh` installs the skills as **hash-verified COPIES, not symlinks**, and
records a manifest. This is deliberate and this README used to say the
opposite: the skill definitions are part of the trusted computing base, and a
symlinked install means any agent with write access edits the live TCB in
place, with nothing to notice it. `--verify` compares the installed tree
against the manifest and additionally reports STALENESS — integrity and
currency are different questions, and a clean integrity check says nothing
about whether the gate you are running is the current one.

The `do_not_touch` write-mask that `prod-implement`/`prod-ops` honor should
also be enforced mechanically: add permission deny rules for
`verification/ratified/**`, your CI config paths, and the registries to your
harness settings — the mask is policy, and prompts are not enforcement.

`config.sh` is plain shell (`KEY="value"`) despite the `.yml` on the example,
so it can be `source`d with no parser. Each skill reads shared material through
relative symlinks in its `references/` — install by symlinking the skill
directory (as above) and they resolve through the repo checkout.

## Harness hooks and config

Two things this repo enforces through the Claude Code harness rather than through
prose, because prose is read and then overridden by whoever is in a hurry. Both
run from the checkout (`~/dev/personal/production-skills`), both are wired in
every `settings.json` the user runs (`~/.claude`, `~/.claude-bloxroute`,
`~/.claude-clc`), and both have a selftest under `_shared/probes/` that shows
each decision RED on a fixture where it must fire.

| hook | event | what it refuses / reports |
|---|---|---|
| `_shared/hooks/agent-dispatch-guard.sh` | `PreToolUse` on `Agent` | `general-purpose`/`fork` dispatches inside a governed repo (names the pinned agent); forks for implementation anywhere; injects the context-budget rules into research agents |
| `_shared/hooks/memory-index-check.sh` | `SessionStart` | a `MEMORY.md` the harness would truncate (>200 lines or >25 KB, lines >160 chars), broken index links, and orphan memories no index or hub line reaches; prints one `memory-index: ok\|FAIL` line per session |

Settings that go with them (`settings.json`, user scope):

```json
{
  "autoMemoryDirectory": "~/.claude-memory",
  "autoDreamEnabled": false,
  "subagentPromptCacheTtl": "1h",
  "bashOutputMaxChars": 12000,
  "hooks": {
    "PreToolUse":   [{ "matcher": "Agent", "hooks": [{ "type": "command", "command": "bash ~/dev/personal/production-skills/_shared/hooks/agent-dispatch-guard.sh", "timeout": 10 }] }],
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "bash ~/dev/personal/production-skills/_shared/hooks/memory-index-check.sh", "timeout": 10 }] }]
  }
}
```

`autoMemoryDirectory` is used by the CLI DIRECTLY as the memory directory (`~/`
expanded, no per-project subdirectory — verified in the 2.1.289 bundle, the docs
only say "a different location"), so one store serves every project and config
dir without the symlink hack. `autoDreamEnabled` is in the settings schema but
not the docs ("background memory consolidation"); it is pinned `false` because
the index is hand-kept and gated, and consolidation belongs behind a gate
(SkillGLoW 2609.02217), never unattended.

The index itself is regenerated with `python3 scripts/memory-reindex.py [DIR]`:
operational and standing-rule memories keep one short line each, the long tail
is grouped into `hub-*.md` files (one index line per hub, member lines verbatim
inside). Re-running on an unchanged store is byte-identical. The design rests on
the harness bound (first 200 lines / 25 KB of `MEMORY.md`, nothing else loaded)
and on DreamBench-SWE 2608.20664 (verbatim per-repo records beat summaries);
MemoryArena 2602.16313 does NOT support "small core + retrieval" and is not cited
for it.

## Validation

Skill files are validated with
[skill-optimizer](https://github.com/fastxyz/skill-optimizer) (`prompt`
surface). `.skill-optimizer/` in each skill directory holds the committed
config AND the **frozen task set** (`tasks.generated.json`) — tasks are
regenerated only deliberately, because unfrozen tasks make run-to-run scores
incomparable.

Two classes of check, used differently (the repo's own GATE/SIGNAL
discipline):

Two GATEs, and they check different things. Run both.

- **GATE:** `skill-optimizer doctor --static`, from inside each skill directory
  (it reads `./.skill-optimizer/skill-optimizer.json`, so the working directory
  is load-bearing). This validates the **optimizer config** — authModes, task
  freezing, benchmark wiring. Run from the wrong directory it prints
  `ERROR: Cannot read config` **and exits 0**, so read the output, not only the
  status.

- **GATE:** `bash _shared/probes/skills-static.sh` — validates the **SKILL.md
  frontmatter**, which the tool above does not. Measured 2026-08-29 by mutating
  a copy of `prod-ops` and running both against the same fixtures:

  | mutation to SKILL.md | `doctor --static` | `skills-static.sh` |
  |---|---|---|
  | `description:` present but empty | rc=0, "0 error(s)" | FAILS |
  | frontmatter invalid YAML | rc=0, "0 error(s)" | FAILS |
  | `SKILL.md` deleted entirely | rc=1 (caught) | FAILS |

  An empty description is the state that makes a skill unreachable in practice
  — it is the only text the model sees when choosing a skill — while every
  other structural check stays green. That is the gap the local probe closes.

  Do not substitute `claude plugin validate <skills-dir>` for either. Probed the
  same day, it PASSED all three mutations when applied to a **nested** skill: it
  does not descend into nested skill directories.

  `skills-static-selftest.sh` proves every rule fires on a fixture where that
  rule's property is false — 13 cases, including a green baseline (without which
  every case could "pass" because the probe fails on everything) and a
  zero-subjects case that exits 2 rather than 0.
- **SIGNAL:** `bash _shared/probes/benchmark-currency.sh` — before reading any
  score, ask whether it is still ABOUT the skill it sits next to. Measured
  2026-08-29: **all seven committed scores predate the skill they measure**, by
  10 to 12 days, and two skills have never been benchmarked at all. `prod-ops`
  reads `FAIL, 12.5% < floor 60.0%` — a number about a document that no longer
  exists, sitting in the directory of the document that replaced it.

  A stale score is not a finding about the skill; it is a finding about the
  score. Do not work the gaps in a stale report — they were measured against
  text that has since changed. This probe is advisory (exit 0) on purpose:
  refreshing needs Codex credentials, and a gate that fails until a human
  performs an action they may not be able to perform is a gate that gets
  disabled, taking the honest ones with it.

- **SIGNAL:** `skill-optimizer run` against the frozen tasks — the prompt
  surface scores *lexical recall* of section content, so a paraphrased-but-
  correct response can score low; treat deltas against the frozen baseline as
  review input, never as a hard gate, and read the failing evaluations before
  believing them.

## Prerequisites in the target repo

The skills assume a repo that declares, minimally:

```yaml
# production.yaml (spec-lite v0)
tier: 0|1|2
invariants: []      # ids resolving to symbols under verification/ratified/
capabilities: []    # declared boundaries with a class each
```

plus, as the framework hardens: `verification/ratified/**` under server-side
protection, the liability registries, and a cheap-gate command. Skills degrade
gracefully — each one's Bail section says exactly what it needs and cannot
fake.

Optionally, when the org has adopted a domain topology
(`_shared/domain-topology.yaml`), `production.yaml` also carries
`service.owning_domain`, `service.domain_role`
(`foundational|derived|aggregate`) and `domain_dependencies: []` — see
`_shared/domain-boundaries.md`.
