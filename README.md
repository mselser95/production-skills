# production-skills

The seven skills that operate a production-verifiability framework: an
intelligence-arbitrage loop where **expensive models orchestrate, cheap models
implement, and a deterministic verifier decides**. Each skill removes a class
of ambiguity so the work downstream of it becomes obvious enough for a smaller
model — that is the whole design.

Every skill is organization-agnostic. Every company-specific fact — spec paths,
gate commands, registry locations, budgets — lives in a local `config.sh` that
is never committed. No `SKILL.md` names an org, repo, team, or channel.

All seven share one governance preamble (`_shared/preamble.md`) and four
interface formats (`_shared/formats/`): the resolved context, the change plan,
test provenance, and the incident fixture. The formats are the contracts of
the whole system — skills are replaceable, the formats are not.

| Skill | Tier | What it does |
|---|---|---|
| [`prod-spec/`](prod-spec/) | orchestrator | Intent → resolved context (~30 lines) + change plan. Writes no code. Hosts the T0 human moment. |
| [`prod-review/`](prod-review/) | orchestrator | Diff vs its contract: recomputes obligations from the diff, flags divergence, runs gap discovery, audits test provenance. Fixes nothing. |
| [`prod-incident/`](prod-incident/) | orchestrator | Incident → minimized invariant-asserting fixture + candidate-invariant package (both-direction evidence) + missing-signal report + gate attribution. |
| [`prod-implement/`](prod-implement/) | implementer | One bounded task inside its contract; iterates against the cheap gate under a TCB write-mask; bounded iterations; honest bail with state. |
| [`prod-test-synth/`](prod-test-synth/) | implementer | Candidate-lane tests at volume, provenance-headed and TTL'd, with generator adequacy self-checks. Cannot touch the blocking lane. |
| [`prod-ops/`](prod-ops/) | implementer | The mechanical pipeline layer: bisect, revert, flake classification, quarantine, liability sweeps, rebases. T0-invariant flakes escalate as incidents. |
| [`prod-curate/`](prod-curate/) | curation | Batch promotion (change-detector screening, mutant-utility dedup, known-bad katas) + ratification packages so human adjudication takes minutes. |

Two rules bind all seven (see the preamble for the rest):

- **Skills may infer intent; they may never invent policy.** The escape is a
  waiver proposal with a mandatory expiry, adjudicated by a human.
- **These SKILL.md files are themselves part of the trusted computing base.**
  A weakened skill prompt is another path to green; changes to this repo go
  through the same approval flow as a ratified invariant.

## Install

Skills load from `${CLAUDE_CONFIG_DIR:-~/.claude}/skills/`. Symlink the ones
you want, then create each config from its example:

```bash
git clone git@github.com:mselser95/production-skills.git
cd production-skills

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$CFG/skills"
for s in prod-spec prod-review prod-incident prod-implement prod-test-synth prod-ops prod-curate; do
  ln -s "$(pwd)/$s" "$CFG/skills/$s"
  cp "$s/config.example.yml" "$s/config.sh"
done
$EDITOR */config.sh
```

`config.sh` is plain shell (`KEY="value"`) despite the `.yml` on the example,
so it can be `source`d with no parser. Each skill reads shared material through
relative symlinks in its `references/` — install by symlinking the skill
directory (as above) and they resolve through the repo checkout.

## Validation

Skill descriptions are benchmarked with
[skill-optimizer](https://github.com/fastxyz/skill-optimizer) (`init prompt`
surface): `.skill-optimizer/` in each skill directory holds the committed
config; `skill-optimizer doctor --static` must pass for every skill before a
change to this repo merges, and `skill-optimizer run` scores trigger/argument
accuracy across models.

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
