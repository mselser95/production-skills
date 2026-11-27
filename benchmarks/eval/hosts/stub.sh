#!/usr/bin/env bash
# stub.sh -- deterministic fake host for the selftest. No network, no model.
# Contract (same as every host): <workdir> <host-home> <prompt-file> <output-file> <usage-json> <model> <budget> <agent_mode> [<schema-file>]
# (the stub ignores the model, budget, mode and schema: STUB_SOLVE_CMD writes whatever the cell needs)
#   STUB_MODE=solve|noop|timeout|crash|noauth   (default noop; noauth exits 78 like a real adapter)
#   STUB_EXIT=n / STUB_HANG=1            solve: do the work, then exit n / hang (grader would pass, row must not)
#   STUB_SOLVE_CMD=<script>              solve: run `bash $STUB_SOLVE_CMD <workdir> <output-file>`
#   STUB_CHILD_SECS=<n>                  timeout: leave a background `sleep n` child behind
#   STUB_RECORD=<file>                   write what this host could see (workdir tree, home tree, prompt)
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
workdir="$1" home="$2" prompt="$3" out="$4" usage="$5"

if [[ -n "${STUB_RECORD:-}" ]]; then
  {
    echo "--workdir--"; (cd "$workdir" && find . -not -path './.git/*' -not -name .git | sort)
    echo "--home--"; (cd "$home" && find . | sort)
    echo "--home-symlinks--"; (cd "$home" && find . -type l | sort)
    echo "--prompt--"; cat "$prompt"
  } >"$STUB_RECORD" 2>&1
fi

case "${STUB_MODE:-noop}" in
  solve)
    bash "${STUB_SOLVE_CMD:?STUB_SOLVE_CMD required for solve}" "$workdir" "$out" || exit 1
    # solve THEN misbehave: a host that crashed/hung must not be credited with its state
    if [[ -n "${STUB_EXIT:-}" ]]; then exit "$STUB_EXIT"; fi
    if [[ -n "${STUB_HANG:-}" ]]; then sleep 3600; fi
    ;;
  noop) : ;;
  timeout)
    sleep "${STUB_CHILD_SECS:-3601}" &
    if [[ -n "${STUB_READY:-}" ]]; then : >"$STUB_READY"; fi
    sleep 3600
    ;;
  noauth) echo "stub: no credential" >&2; exit 78 ;;
  crash) echo "stub: simulated crash" >&2; exit 3 ;;
  *) echo "stub: unknown STUB_MODE" >&2; exit 2 ;;
esac
printf '{"tokens_in":1200,"tokens_out":300,"cost_usd":0.01}\n' >"$usage"
exit 0
