# production-skills

The skills that operate a production-verifiability framework: an
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

| Skill | Tier | What it does |
|---|---|---|
| [`prod-spec/`](prod-spec/) | orchestrator | Intent → resolved context (~30 lines) + change plan. Writes no code. Hosts the T0 human moment. |
| [`prod-review/`](prod-review/) | orchestrator | Hard senior review of a diff vs its contract: divergence recompute, gap discovery, provenance audit, plus the full audit engine (idiom recon, blocker calibration, 10 review areas). Fixes nothing. |
| [`prod-incident/`](prod-incident/) | orchestrator | Incident → minimized invariant-asserting fixture + candidate-invariant package (both-direction evidence) + missing-signal report + gate attribution. |
| [`prod-implement/`](prod-implement/) | implementer | One bounded task inside its contract; iterates against the cheap gate under a TCB write-mask; bounded iterations; honest bail with state. |
| [`prod-test-synth/`](prod-test-synth/) | implementer | Candidate-lane tests at volume, provenance-headed and TTL'd, with generator adequacy self-checks. Cannot touch the blocking lane. |
| [`prod-ops/`](prod-ops/) | implementer | The mechanical pipeline layer: bisect, revert, flake classification, quarantine, liability sweeps, rebases. T0-invariant flakes escalate as incidents. |
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
one bounded task under the write-mask), `prod-mechanic` (haiku, prod-ops
operations and curation screening). Orchestrator skills dispatch; they do not
do mechanical work inline. Model pins live in the agent frontmatter —
retargeting a tier is a one-line change there, never a skill edit.

## Install

Skills load from `${CLAUDE_CONFIG_DIR:-~/.claude}/skills/`. Symlink the ones
you want, then create each config from its example:

```bash
git clone git@github.com:mselser95/production-skills.git
cd production-skills

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$CFG/skills"
for s in prod-spec prod-review prod-incident prod-implement prod-test-synth prod-ops prod-curate prod-bootstrap; do
  ln -s "$(pwd)/$s" "$CFG/skills/$s"
  cp "$s/config.example.yml" "$s/config.sh"
done
mkdir -p "$CFG/agents"
for a in agents/*.md; do ln -s "$(pwd)/$a" "$CFG/agents/$(basename "$a")"; done
$EDITOR */config.sh
```

The `do_not_touch` write-mask that `prod-implement`/`prod-ops` honor should
also be enforced mechanically: add permission deny rules for
`verification/ratified/**`, your CI config paths, and the registries to your
harness settings — the mask is policy, and prompts are not enforcement.

`config.sh` is plain shell (`KEY="value"`) despite the `.yml` on the example,
so it can be `source`d with no parser. Each skill reads shared material through
relative symlinks in its `references/` — install by symlinking the skill
directory (as above) and they resolve through the repo checkout.

## Validation

Skill files are validated with
[skill-optimizer](https://github.com/fastxyz/skill-optimizer) (`prompt`
surface). `.skill-optimizer/` in each skill directory holds the committed
config AND the **frozen task set** (`tasks.generated.json`) — tasks are
regenerated only deliberately, because unfrozen tasks make run-to-run scores
incomparable.

Two classes of check, used differently (the repo's own GATE/SIGNAL
discipline):

- **GATE:** `skill-optimizer doctor --static` — structural validity; must pass
  for every skill before a change merges.
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
