#!/usr/bin/env bash
# live.sh -- the paid run behind `make eval-live`: every corpus task x both
# hosts x both arms x N reps, one row each, then the report beside the results.
# It spends real money, so it refuses to run unless EVAL_LIVE=1 and always
# prints the plan first.
#   N=3                      reps per cell
#   EVAL_MODEL_CLAUDE / EVAL_MODEL_CODEX   optional model per host
#   EVAL_HOSTS="claude codex"              hosts to run
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$here/../.." && pwd)"
n="${N:-3}" hosts="${EVAL_HOSTS:-claude codex}"
tasks=()
corpus="${EVAL_CORPUS:-$here/corpus}"   # a PATH, never evaluated
for t in "$corpus"/*/*/; do [[ -f "$t/task.json" ]] && tasks+=("${t%/}"); done
sha="$(cd "$repo" && git log -1 --format=%h -- benchmarks/eval 2>/dev/null)"; sha="${sha:-unknown}"
seed="${EVAL_SEED:-$(date -u +%s)}"
# one file per live run (UTC date AND time): a same-day rerun cannot append duplicate reps
res="${EVAL_RESULTS_DIR:-$here/results}/$(date -u +%Y-%m-%dT%H%M%SZ)-$sha.jsonl"
mkdir -p "$(dirname "$res")"
cells=$(( ${#tasks[@]} * $(wc -w <<<"$hosts") * 2 * n ))
echo "eval-live plan: ${#tasks[@]} task(s) x hosts [$hosts] x arms [skill bare] x $n rep(s) = $cells cell(s)"
echo "  results: $res (+ .md beside it)"
echo "  arm-order seed: $seed (stored in every row as order_seed)"
if [[ "${EVAL_LIVE:-0}" != 1 ]]; then
  echo "eval-live: REFUSING -- this spends real money. Re-run with EVAL_LIVE=1 (e.g. EVAL_LIVE=1 make eval-live N=3)." >&2
  exit 2
fi
if (( ${#tasks[@]} == 0 )); then echo "eval-live: no tasks under corpus/ -- nothing to run" >&2; exit 2; fi
# A3: one credential check per host BEFORE the paid loop (prints ok/missing, never a secret)
for h in $hosts; do
  if [[ "$(bash "$here/lib/authcheck.sh" "$h" 2>/dev/null)" != ok ]]; then
    echo "eval-live: REFUSING -- no usable credential for host '$h' (claude: CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY / login; codex: CODEX_API_KEY / ~/.codex/auth.json)" >&2
    exit 2
  fi
done
for t in "${tasks[@]}"; do
  for h in $hosts; do
    m=""; [[ "$h" == claude ]] && m="${EVAL_MODEL_CLAUDE:-}"; [[ "$h" == codex ]] && m="${EVAL_MODEL_CODEX:-}"
    r=1
    while (( r <= n )); do
      # keyed by <skill>/<id>, never by the checkout path: the same seed gives the same order anywhere
      for arm in $(python3 -I -B "$here/lib/armorder.py" "$seed" "$(basename "$(dirname "$t")")/$(basename "$t")" "$h" "$r"); do
        bash "$here/run.sh" --task "$t" --arm "$arm" --host "$h" --rep "$r" --out "$res" --model "$m" --order-seed "$seed"
        rc=$?
        if [[ $rc -eq 3 ]]; then echo "eval-live: STOP -- host $h cannot run here (credential or sandbox failure, row recorded)" >&2; exit 3; fi
        [[ $rc -eq 0 ]] || echo "eval-live: run.sh could not even start $t $h $arm $r (rc $rc)" >&2
      done
      r=$((r + 1))
    done
  done
done
python3 -I -B "$here/report.py" "$res" --markdown | tee "${res%.jsonl}.md"
