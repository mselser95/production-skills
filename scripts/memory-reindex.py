#!/usr/bin/env python3
"""Rebuild the auto-memory index (MEMORY.md) within the harness bound (200 lines / 25 KB).

Usage: python3 scripts/memory-reindex.py [DIR]   (DIR defaults to ~/.claude-memory)

Existing hooks are read verbatim from the current MEMORY.md and hub-*.md files.

The hub list (HUBS) and the always-direct set (DIRECT_OPS / DIRECT_BLOX / DIRECT_ACTIVE)
are THIS user's classification of THIS store, kept in the shared repo so the gate
(memory-index-check.sh) and its generator ship together. Another store edits those
tables; files matching no rule are listed as UNCLASSIFIED and get a direct line under their own
section; hub-*.md files not in HUBS keep an index line of their own.
Long-tail lessons move into hub files (one index line per hub, member lines verbatim
inside the hub). Operational / standing-rule memories keep a direct, short line.
Re-runnable: regenerates hubs and MEMORY.md from the snapshot every time.
"""
import os, re, subprocess, sys, collections
MEM = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else '~/.claude-memory')
os.chdir(MEM)
# existing hooks are read from the live index and hubs, so re-running keeps every line
old = []
for src in ['MEMORY.md'] + sorted(f for f in os.listdir('.') if f.startswith('hub-') and f.endswith('.md')):
    old += open(src, errors='ignore').read().splitlines()
oldline = {}
for l in old:
    m = re.match(r'- \[(.*?)\]\((.*?)\)\s*—\s*(.*)$', l) or re.match(r'- \[(.*?)\]\((.*?)\)\s*(.*)$', l)
    if m:
        oldline[m.group(2)] = (m.group(1), m.group(3).strip(), l.rstrip())

def fm(f):
    t = open(f, errors='ignore').read()
    d = re.search(r'^description:\s*(.*)$', t, re.M)
    ty = re.search(r'^\s*type:\s*(\w+)', t, re.M)
    n = re.search(r'^name:\s*(.*)$', t, re.M)
    desc = d.group(1).strip().strip('"').strip("'") if d else ''
    return (n.group(1).strip() if n else f[:-3]), desc, (ty.group(1) if ty else '')

files = sorted(f for f in os.listdir('.') if f.endswith('.md') and f != 'MEMORY.md' and not f.startswith('hub-'))

def title_hook(f):
    if f in oldline:
        return oldline[f][0], oldline[f][1], oldline[f][2]
    name, desc, _ = fm(f)
    t = open(f, errors='ignore').read()
    h1 = re.search(r'^# (.+)$', t, re.M)
    title = h1.group(1).strip() if h1 else (name[:1].upper() + name[1:]).replace('-', ' ')
    return title, desc, f'- [{title}]({f}) — {desc}'

def short(h, n=70):
    h = re.split(r';| — ', h)[0].strip()
    if len(h) > n:
        h = h[:n].rsplit(' ', 1)[0].rstrip(',:.') + '…'
    return h

def line(t, f, h, cap=150):
    pre = f'- [{t}]({f}) — '
    if len(pre) > cap - 30:  # title too long to leave room for a hook: cut the title
        room = cap - 30 - len(f'- []({f}) — ')
        t = t[:room].rsplit(' ', 1)[0] + '…'
        pre = f'- [{t}]({f}) — '
    return pre + short(h, max(30, cap - len(pre)))

# ---- classification ---------------------------------------------------------
DIRECT_OPS = set('''rigor-standard-for-every-repo-change always-run-facundo-grade-review
feedback_review_local_before_every_pr review-local-loops-until-ok feedback_monitor_ci_every_pr
feedback_pr_review_watch_fix_merge production-skills-repo-and-routing production-skills-is-governed-t1
production-skills-takes-direct-pushes-to-main agent-dispatch-guard-hook opus-orchestrates-sonnet-writes-code
haiku-implementers-loop-on-closed-fixes skill-tool-costs-the-whole-listing-per-turn
feedback_always_tag_alan_on_pr_reviews feedback_max_subagents_by_default feedback_measure_dont_assert
verify-end-to-end-whenever-possible feedback_redact_secrets feedback_no_slack_drafts feedback_just_run_it
feedback_file_followups_on_own_judgement feedback_prefer_the_cleanest_design feedback_run_ci_locally_before_push
feedback_lint_before_push feedback_may_merge_when_approved_clean 
scale-vertically-and-horizontally-by-default background-work-in-go-must-be-temporal
go-logging-slog-over-zap-with-otelslog the-bash-tool-runs-zsh eza-eats-stdin-when-no-path-given
bang-prefix-does-not-reach-background-sessions deny-globs-only-cover-the-session-cwd
parallel-agents-share-tmp-and-collide stale-skill-install-downgrades-every-gate clc-work-lives-in-dev-clc
project_clc_unrelated_to_terrace clc-stack-is-not-terrace feedback_never_reference_terrace
risk-engine-lives-in-clcsolutions feedback_read_refs_server_side_not_from_a_local_ref
feedback_code_search_indexes_default_branches_only git-commit-takes-everything-staged push-origin-head-pushed-main
clc-kubectl-explicit-context clc-kubectl-flag-order feedback_vault_apply_by_user
parallelize-independent-work-with-agents a-plan-means-text-not-repo-actions
stay-in-the-scope-mati-named fix-it-dont-file-it-even-when-agents-md-says-escalate
dont-defer-a-gate-fail-as-owners-call-without-trying run-secret-scan-before-every-commit
never-commit-key-material-even-throwaway monitor-pr-comments-after-opening always-enable-automerge-on-my-prs
readmes-must-be-exhaustive-with-diagrams slack-mentions-must-be-raw-not-escaped
review-loop-slack-is-always-external-language test-against-real-staging-never-a-fake
one-binary-several-commands-not-several-binaries not-validated-is-where-the-blocker-lives
template-provenance-stamped-from-is-a-digest vendored-selftests-run-where-the-template-is-absent
memory-index-is-bounded-by-the-harness automemorydirectory-is-used-directly memory-papers-what-held-up
global-working-rules-rationale'''.split())
DIRECT_BLOX = re.compile(r'falconxyz|falcon-service|falcon-xyz|bloxroute|project-falconxyz|dashboard-default-branch|no-databases-on-the-falconxyz|no-playwright-for-falconxyz|staging-scanner-rate|testnet-fallback|vendor-and-scrub|settlement-worker-is-local|falcond-is-off|clc-and-terrace-are-read-only|clone-the-source-instead|project_bughunt_api_service')
DIRECT_ACTIVE = set('project_clc_ha_migration_campaign project_perps_jul4_incident_followups production-skills-papers-roadmap-state'.split())
HUBS = [  # (slug, title, keywords for the index line, regex)
 ('clc-merge-gates', 'CLC merge gates por repo', 'quién mergea con qué approvals, auto-merge, bypass',
  r'merge-gate|bff-merge|e2e-gate-is|infra-repo-keeps|infra-admins-bypass|infra-required-checks|clc-admin-bypass|needs-two-approvals|merges-within-a-minute|proto-merge-gate|ci-repo-approve|armed-auto-merge|a-warning-has-no-landing|parallel-auto-reviewer|ci-runner-migration-wave|ci-and-infra-push-direct|infra-stacked-prs|infra-merge-commits-never|infra-branches-race|gh-stack-merge|review-requests-get-cleared|risk-engine-approve-cancels|risk-engine-review-event-costs'),
 ('clc-ci-runners', 'clc-ci runners y tiempos', 'medium 6x lento, egress, cache de setup-go, budget',
  r'clc-ci-|ci-slow-runner|arc-runners|a-toolchain-bump|re-canary|setup-go-cache|clc-shared-ci|project_gh_actions_budget|inherited-runner-labels|risk-engine-ci-gate-pins|risk-engine-pool-comments'),
 ('risk-engine', 'risk-engine (clcsolutions)', 'build amd64, boot O(n), StatefulSet, CI, spec ratificada',
  r'risk-|riskengine|project_clc_ha|project_clc_local_amd64|project_clc_risk_engine|kraken-pong|mapper-refold|decouple-network'),
 ('clc-e2e', 'clcsolutions/e2e harness', 'tiers, flakes, pins, lo que nunca corrió en PRs',
  r'^e2e-|project_clc_e2e'),
 ('lending-service', 'lending-service', 'authz = NetworkPolicy, JWT vars, prod real, enum stale',
  r'^lending-'),
 ('clc-infra-gitops', 'clc-infra GitOps / DOKS', 'Flux, Crossplane, CNPG, seeders, Vault, policy-tests',
  r'^infra-|clc-infra|crossplane|clc-flux|seed-app|clc-seed|clc-inline-env|bff-identity-addr|clc-460|clc-401|project_clc_infra|project_clc_deletion|project_clc_backup|project_clc_metrics|project_clc_dev_bringup|clc-prod-rollout|clc-two-prometheus|clc-public-workloads|clc-alloy|replicas-1|named-environment|infra-image-setter|prometheus-withlabelvalues|project_deploy_authority|feedback_rightsize_vpa|probe-seed-app-env|reference_docr_token|project_clc_services_and_ci|ops-console-|identity-service|tenant-dashboard'),
 ('clc-services', 'otros servicios CLC', 'marketdata, bff, proto, webhook, bitgo, exchanges, perps',
  r'marketdata|webhook-nats|project_mds|project_market_data|project_strategy_pnl|project_clc_bitgo|reference_binance|project_exchange_dev|two-review-loops-config-dir|project_execution_service|project_orderbook|project_deadline_sentinel|^bff-|^proto-|one-proto-repo|lending'),
 ('terrace-legacy', 'Terrace / veranda / control-minikube (legado)', 'reglas viejas de ese stack, solo referencia',
  r'control_minikube|project_veranda|feedback_kubectl_context|feedback_at_run_locally|feedback_coordinate_env|feedback_no_k8s|feedback_no_port_forward|feedback_push_to_main--veranda|feedback_read_only_or_prs_only|feedback_no_synthetic_data|feedback_never_cache_balance|red-casa-lote'),
 ('review-mechanics', 'mecánica de reviews (gh, review-loop, Linear)', 'watermarks, stale state, absence claims, tickets',
  r'review-loop|github-review-post|gh-pr-state|gh-search-code|blocker-over-a-live|a-ci-caveat|subagent-absence|a-reviewers-suggested|three-dot-compare|watch-pr-once|linear-merged|no-ticket-key|followup-prs|a-pr-can-be-a-measured|an-absence-claim|a-not-validated-premise|whats-good-makes|a-budget-change|a-per-harness-green|classify-an-advisory|a-red-check-on-main|three-wrong-measurements'),
 ('github-actions', 'GitHub Actions y required checks', 'zero checks, re-runs, contexts, govulncheck, continue-on-error',
  r'invalid-workflow|actions-rerun|ci-job-dies|required-context-outlives|red-check-can-be|dispatch-only-guard|infra-pr-red-check|a-job-that-gates-nothing|measure-which-contexts|e2e-nightly-cert|the-honest-report-only|green-govulncheck|a-vuln-count|a-git-hook-exports|playwright-failure-output'),
 ('gates-and-vacuity', 'gates, probes, selftests y vacuidad', 'cómo una gate pasa sin hacer nada; mutación; templates',
  r'gate|probe|selftest|vendored|template|mutation|vacu|a-fixture|two-redundant|a-joint|four-shapes|generated-output|an-unmeasured-bound|a-denominator|progress-signals|byte-identical|exemption-restore|a-demo-is|never-validate-a-demo|a-scenario-checklist|load-and-chaos|a-rule-that-punishes|an-uninstalled|a-target-that-exists|org-specific-facts|reproducing-a-mutation|probabilistic-test|a-green-infra-board|a-config-file-outside'),
 ('evidence-and-reading', 'leer evidencia sin engañarse', 'comentarios que mienten, logs truncados, grep que cuenta de más',
  r'three-wrong|truncating-a-log|assert-after-verify|silencing-stderr|checked-and-none|a-comment-can-falsify|a-script-comment|proto-comment-can|documented-deploy-order|a-note-that-justifies|matching-the-field|a-grep-that-counts|bash-n-proves|an-undefined-bash|a-silent-empty-sweep|jq-sub|a-blank-line|a-green-step|an-unwired-gate|measure-the-tail|three-of-three|the-instrument-was|verify-with-the|a-fix-that-eats'),
 ('code-and-design', 'lecciones de código y diseño', 'spans, retries, error paths, handles vivos, async, worktrees',
  r'a-span-is-not|retry-on-every|an-error-path|a-vendor-returns|async-op-reports|a-deployed-server|shared-checkout|mutation-agents-need|parallel-workflow-agents|a-selftest-that-drives|gates-guard-deletions|production-verifiability-framework'),
]
hub_members = collections.OrderedDict((h[0], []) for h in HUBS)
direct_ops, direct_blox, direct_active, uncl = [], [], [], []
for f in files:
    s = f[:-3]
    if s in DIRECT_OPS: direct_ops.append(f); continue
    if DIRECT_BLOX.search(s): direct_blox.append(f); continue
    if s in DIRECT_ACTIVE: direct_active.append(f); continue
    for slug, _, _, rx in HUBS:
        if re.search(rx, s): hub_members[slug].append(f); break
    else: uncl.append(f)

# ---- hub files ----------------------------------------------------------------
for slug, title, kw, _ in HUBS:
    mem = hub_members[slug]
    body = [f'---', f'name: hub-{slug}', f'description: Hub ({len(mem)} memorias) — {title}: {kw}. Abrir cuando el trabajo toque este tema; cada línea apunta a la memoria completa.', 'metadata:', '  type: reference', '---', '',
            f'# {title}', '', f'Hub de índice generado el 2026-10-03 desde MEMORY.md (líneas verbatim). {kw}.', '']
    for f in mem:
        body.append(title_hook(f)[2])
    open(f'hub-{slug}.md', 'w').write('\n'.join(body) + '\n')

# ---- MEMORY.md ----------------------------------------------------------------
L = []
L.append('# Memoria compartida (~/.claude-memory, via autoMemoryDirectory en los 3 settings.json)')
L.append('# El harness carga SOLO las primeras 200 líneas / 25 KB: por eso este índice es corto y las')
L.append('# lecciones largas viven en hubs (hub-*.md), que se abren cuando el tema aparece. Gate: memory-index-check.sh.')
L.append('')
L.append('## Reglas de trabajo y herramientas (leer siempre)')
for f in sorted(direct_ops, key=lambda x: title_hook(x)[0].lower()):
    t, h, _ = title_hook(f); L.append(line(t, f, h))
L.append('')
L.append('## bloxroute / falconxyz (cwd actual)')
for f in sorted(direct_blox, key=lambda x: title_hook(x)[0].lower()):
    t, h, _ = title_hook(f); L.append(line(t, f, h))
L.append('')
L.append('## Campañas activas')
for f in direct_active:
    t, h, _ = title_hook(f); L.append(line(t, f, h))
L.append('')
if uncl:
    L.append('## Sin clasificar (darles un hub o una regla en memory-reindex.py)')
    for f in sorted(uncl, key=lambda x: title_hook(x)[0].lower()):
        t, h, _ = title_hook(f); L.append(line(t, f, h))
    L.append('')
L.append('## Hubs por tema (abrir el que toque el trabajo)')
for slug, title, kw, _ in HUBS:
    n = len(hub_members[slug]); L.append(line(f'Hub · {title}', f'hub-{slug}.md', f'{n} memorias: {kw}', 158))
# hub files that exist but are not in HUBS (hand-made, or from another store): keep them reachable
known = {f'hub-{slug}.md' for slug, _, _, _ in HUBS}
for f in sorted(x for x in os.listdir('.') if x.startswith('hub-') and x.endswith('.md') and x not in known):
    name, desc, _ = fm(f); L.append(line(f'Hub · {name}', f, desc or 'hub sin descripción'))
out = '\n'.join(L) + '\n'
open('MEMORY.md', 'w').write(out)
print(f'index: {len(L)} lines, {len(out.encode())} bytes, max line {max(len(l) for l in L)}')
print('direct ops', len(direct_ops), 'blox', len(direct_blox), 'active', len(direct_active), 'hubs', {k: len(v) for k, v in hub_members.items()})
print('UNCLASSIFIED', len(uncl)); [print('  ', u, '|', title_hook(u)[0][:70]) for u in uncl]
missing = [s for s in DIRECT_OPS if not os.path.exists(s + '.md')]
print('DIRECT_OPS not on disk yet:', missing)
