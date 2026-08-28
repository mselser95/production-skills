# Quick start — for someone joining a team that uses this

Fifteen minutes to a working install, one decision per repo, and three commands
you will actually type. Everything else in this repository is reference
material you can read when a gate asks you to.

If you want the argument for why any of it exists, read `demos/INDEX.md`
instead — every rule here traces to a runnable demo of the failure it prevents.

---

## 1. Install (once per machine, ~5 minutes)

```bash
git clone git@github.com:mselser95/production-skills.git
cd production-skills

# Create your config from each example. These are gitignored on purpose:
# every company-specific fact lives here and in no SKILL.md.
for s in prod-*/; do
  [ -f "$s/config.sh" ] || cp "$s/config.example.yml" "$s/config.sh"
done
$EDITOR prod-review/config.sh     # start here: the blocker bar is the one knob that matters
```

(The loop tests for the file rather than using `cp -n`, because `cp -n` exits
NON-ZERO when it declines to overwrite — which is the ordinary case on a second
run. Chained after `&&`, or under `set -e`, it fails the first step of your
onboarding on the run where nothing was wrong. That is one of the four shapes
`_shared/preamble.md` §4b catalogues, and it was committed in this file, by the
person writing it, and found by running it.)

```bash
bash install.sh                   # copies the skills into your Claude config dir + writes a manifest
bash install.sh --verify          # must print "TCB verified: N files match the manifest"
```

**Copies, not symlinks, and that is the whole point.** The skill definitions
are part of the trusted computing base: a symlinked install means any agent
with write access edits the live standard in place, and nothing would notice.
The copy plus the manifest gives you a mechanical check that survives that —
`--verify` fails if an installed skill, format, policy file or agent definition
no longer matches what was installed, whatever changed it.

Run `--verify` from a session hook or a cron. It answers two different
questions and says which one failed:

- **integrity** — has the installed copy been altered?
- **currency** — is the installed copy the CURRENT one? A clean integrity
  check says nothing about this, and "the gate you are running is four months
  old" is the failure that reports green.

### Also do this: enforce the write-mask mechanically

The skills honour a `do_not_touch` mask, but a prompt is not enforcement. Add
deny rules to your harness settings for `verification/ratified/**`, your CI
config paths, and `registries/**`. Prompts describe the policy; the harness
imposes it.

---

## 2. One decision per repo

Ask one question of any repo you work in: **does it have `AGENTS.md` and
`production.yaml` at its root?**

**No →** the repo is ungoverned. The pipeline, the checklists and the gates do
not apply, not because anyone decided they shouldn't but because there is no
spec to resolve against. To change that, once:

```
"bootstrap this repo"        # invokes prod-bootstrap
```

It inventories the repo, asks you the handful of things only a human can answer
(tier, capabilities and their classes, what must never happen), scaffolds the
spec and the directories, and hands you an honest gap report plus a ratchet
plan — bounded tasks, nothing that blocks today's work on day one.

Budget 30–60 minutes of your attention for the Q&A. It is the only
conversation-first skill in the suite, and it is where the semantic decisions
get made.

**Yes →** the repo is governed. Its `AGENTS.md` routes every agent request
through the pipeline automatically. You do not invoke anything.

**Greenfield?** Don't bootstrap — `prod-new` creates a repo already at the
standard, which costs an afternoon instead of the weeks a retrofit costs.

---

## 3. The three commands you will actually type

Inside a governed repo, day to day:

| You want to | Say | What happens |
|---|---|---|
| start any change | *"prepare the context for X"* | `prod-spec` turns intent into a ~30-line resolved context + a change plan. Writes no code. Stops for your approval if the repo is tier 0. |
| get it built | *"implement T2 of the plan"* | `prod-implement` executes ONE bounded task inside that contract, iterating against the cheap gate, under the write-mask. |
| know if it is done | *"review this against the contract"* | `prod-review` recomputes the obligations from the actual diff and reports divergence, gaps and provenance findings. It fixes nothing. |

"Done" means the review verdict is `contract-satisfied` and every required gate
is green — not that the code compiles.

Two more you will meet less often: `prod-incident` (turn a production incident
into a permanent fixture + candidate invariant) and `prod-ops` (bisect, revert,
flake classification, liability sweeps).

---

## 4. The gates, and what each one costs you

```bash
make check-fast        # seconds — compile, lint, changed-package tests, the fitness gates
make verify            # the full presubmit lane
make verify-standard   # the standard's own probe: every dimension, PASS/FAIL/NA
make check-registries  # liability expiries; a lapsed entry reddens the build on purpose
```

`make verify-standard` is the one to read. It prints a row per dimension with
the evidence behind each verdict, and it must end `FAIL 0`.

**Every FAIL is a finding, never a reason to soften the probe.** That sentence
is the whole culture of this repository. A gate edited to go green is worth
less than no gate, because it now reports success over the case it was built
for.

`NA` is a legal verdict — but only with a recorded reason in `production.yaml`,
never as a silence.

---

## 5. When something goes red

**A gate you did not expect.** Read the row's evidence line before touching
anything: these rows are written to say what they measured, not merely that
they failed. Most of the time the finding is real and small.

**A test you did not write, failing on your change.** That is a finding for a
human, not an obstacle: never modify, weaken or delete an existing test to make
your change pass. This is the rule with no tier exception.

**An obligation you cannot satisfy.** Propose a waiver — with an owner and a
mandatory expiry, in the registry — and continue with the obligation still in
force until someone grants it. A waiver is a decision with a deadline. A silent
skip is neither.

**The probe itself looks wrong.** Say so, loudly, with the measurement. The
probe has been wrong before and its own history is written into its comments;
what it must never be is quietly adjusted until it agrees with the code.

---

## 6. Keeping in step

A governed repo does not import this framework — it COPIED parts of it
(`scripts/verify-standard.sh`, the selftests, the fitness gates). Every copy is
correct the day it was made and on no day after, so:

```bash
make template-drift    # is this repo still in step with the standard?
```

`check-fast` already runs the local half of it on every pass, which answers
"did somebody edit a vendored gate HERE" — a locally edited gate is a fork of
the standard still carrying the standard's name. The full command additionally
answers "has the standard moved". That one reports rather than fails: your repo
should not go red because someone committed to the framework this morning.

**Never re-stamp the provenance file to make a drift report go away.** A stamp
taken to silence a report certifies a state nobody checked, which is strictly
worse than the red it replaced.

---

## 7. What to read next, in order

1. `_shared/preamble.md` — the governance rules every skill obeys. Short, and
   it explains the ones that will feel strict.
2. `demos/INDEX.md` — the runnable demonstrations behind the rules. If a rule
   seems paranoid, its demo is the argument.
3. `_shared/dimensions.md` — the completeness checklist. Reference, not
   reading; find your dimension when a gap report cites it.
4. `_shared/tier-policy.yaml` — every threshold, and why each one is where it
   is. This is the file your repo's obligations are DERIVED from, and the file
   your spec must never restate.

---

## The one-paragraph version

Install with `install.sh` and verify. Bootstrap the repos you care about, once
each. Then: context before code, one bounded task at a time, review against the
contract, and `make verify-standard` ending `FAIL 0` before you call anything
done. When a gate fires, the finding is the product — fix the code or record a
waiver with an expiry, and never edit the gate to agree with you.
