#!/usr/bin/env bash
# provenance: candidate (ttl: 2027-04-06); derived-from: invariant a-gate-never-reports-green-over-something-it-did-not-measure
# pinning: true   (exact summary wording and exit codes; no ratified property names them yet)
#
# check-template-drift-selftest.sh -- drives scripts/check-template-drift.sh on a scratch
# repo against a scratch template, to show it tells a repo the truth about what it LACKS:
# a repo stamped from an older template (fewer vendored files) is told, by name, which
# files the template vends that it does not have; a repo in step is told none; a file the
# template retired is named; --local needs no template and says nothing about the list;
# and no readable template list is "could not compare", never "0 missing".
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../check-template-drift.sh"
[[ -f "$script" ]] || { echo "check-template-drift selftest: $script not found"; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/drift-selftest.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
pass=0 bad=0
sha() { printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; }

# mktpl <dir> <file>... : a template whose stamp script lists exactly these vendored files
mktpl() {
  local d="$1"; shift; mkdir -p "$d/scripts"
  { echo 'VENDORED=('; echo '  # a comment inside the list'; for f in "$@"; do echo "  $f"; done; echo ')'; } > "$d/scripts/stamp-template-provenance.sh"
  for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; printf 'content of %s\n' "$f" > "$d/$f"; done
}
# mkrepo <dir> <file>... : a repo whose provenance records exactly these files, as the template has them
mkrepo() {
  local d="$1"; shift; mkdir -p "$d/.prod" "$d/scripts"
  ( cd "$d" && git init -q )
  { echo 'stamped_from: production-skills@test'; echo 'files:'
    for f in "$@"; do
      mkdir -p "$d/$(dirname "$f")"; printf 'content of %s\n' "$f" > "$d/$f"
      printf '  - path: %s\n    sha256: %s\n    template_sha256: %s\n' "$f" "$(sha "content of $f")" "$(sha "content of $f")"
    done; } > "$d/.prod/template-provenance.yaml"
  # the template-side hash is of the file's bytes; printf adds a newline, so hash the file
  for f in "$@"; do h="$(shasum -a 256 "$d/$f" | awk '{print $1}')"; sed -i.bak "s/$(sha "content of $f")/$h/g" "$d/.prod/template-provenance.yaml"; done; rm -f "$d/.prod/template-provenance.yaml.bak"
}
# run <name> <want-rc> <repo> <env-assignments-or-->  <substr-present>... ;  "!x" = must be ABSENT
run() {
  local name="$1" wrc="$2" r="$3" mode="$4"; shift 4
  local out rc ok=1 w
  out="$(cd "$r" && env HOME="$tmp/nohome" CLAUDE_CONFIG_DIR="$tmp/nocfg" ${TD:+TEMPLATE_DIR="$TD"} bash "$script" $mode 2>&1)"; rc=$?
  [[ "$rc" -eq "$wrc" ]] || ok=0
  for w in "$@"; do
    if [[ "$w" == '!'* ]]; then [[ "$out" != *"${w:1}"* ]] || ok=0; else [[ "$out" == *"$w"* ]] || ok=0; fi
  done
  if (( ok )); then pass=$((pass+1)); echo "  ok   $name"
  else bad=$((bad+1)); echo "  FAIL $name (rc=$rc want $wrc)"; echo "$out" | sed 's/^/       /'; fi
}

OLD=(scripts/a.sh scripts/b.sh); NEW=(scripts/a.sh scripts/b.sh scripts/c.sh scripts/tests/d-selftest.sh)
mktpl "$tmp/tpl-new" "${NEW[@]}"
mkrepo "$tmp/repo-old" "${OLD[@]}"
mkrepo "$tmp/repo-cur" "${NEW[@]}"

TD="$tmp/tpl-new"
run "a repo stamped at an older list is told exactly the files it lacks" 0 "$tmp/repo-old" "" \
  "MISSING UPSTREAM FILE (2)" "scripts/c.sh" "scripts/tests/d-selftest.sh" "!scripts/a.sh -- vended" "!scripts/b.sh -- vended" "2 MISSING UPSTREAM FILE(s)" "!in step with the standard"
run "a repo in step is told none missing and is in step" 0 "$tmp/repo-cur" "" \
  "in step with the standard" "!MISSING UPSTREAM FILE (" "!RETIRED UPSTREAM ("
# a file the template retired
mktpl "$tmp/tpl-ret" scripts/a.sh scripts/b.sh
mkrepo "$tmp/repo-ret" scripts/a.sh scripts/b.sh scripts/gone.sh
TD="$tmp/tpl-ret"
run "a path the template no longer vends is RETIRED UPSTREAM, reported not failed" 0 "$tmp/repo-ret" "" \
  "RETIRED UPSTREAM (1)" "scripts/gone.sh" "1 retired upstream" "!UNKNOWN" "!MISSING UPSTREAM FILE ("
# --local needs no template and does not talk about the list
TD="$tmp/nonexistent-template"
run "--local without a template: no list comparison, unchanged verdict" 0 "$tmp/repo-old" "--local" \
  "in step with the standard" "!MISSING UPSTREAM FILE (" "!UNKNOWN"
# no reachable template: says it could not compare, never 0 missing
run "no template reachable: could not compare, not '0 missing'" 0 "$tmp/repo-old" "" \
  "UNKNOWN" "could not read the template's list" "!MISSING UPSTREAM FILE (" "!in step with the standard"
# a template whose stamp script has no list is also not '0 missing'
mkdir -p "$tmp/tpl-empty/scripts"; echo '# no list here' > "$tmp/tpl-empty/scripts/stamp-template-provenance.sh"
TD="$tmp/tpl-empty"
run "a template stamp script with no readable list: could not compare" 0 "$tmp/repo-cur" "" \
  "could not read the template's list" "!in step with the standard"
# local drift still fails (exit class unchanged)
echo "edited" >> "$tmp/repo-cur/scripts/a.sh"; TD="$tmp/tpl-new"
run "local drift still exits 1" 1 "$tmp/repo-cur" "" "LOCAL DRIFT (1)"

# ACCEPTED DRIFT: registries/contract-debt.yaml `template_paths:` + owner + expires
# mkdebt <repo> <expires> [extra-entry-line] : a registry whose one entry names scripts/a.sh
mkdebt() {
  mkdir -p "$1/registries"
  { echo 'entries:'; echo '  - id: fork-a'; echo '    owner: "@someone"'; echo "    expires: $2"
    echo '    template_paths: [scripts/a.sh]'; echo '    evidence: >'; echo '      prose that says expires: 2099-01-01 must not extend the entry'
    [[ -n "${3:-}" ]] && echo "    $3"; } > "$1/registries/contract-debt.yaml"
}
LIVE=2099-12-31; LAPSED=2020-01-01
TD="$tmp/tpl-new"
for v in absent-live absent-none absent-expired edited-live edited-expired retired; do mkrepo "$tmp/repo-$v" "${NEW[@]}"; done
rm "$tmp/repo-absent-live/scripts/a.sh" "$tmp/repo-absent-none/scripts/a.sh" "$tmp/repo-absent-expired/scripts/a.sh" "$tmp/repo-retired/scripts/a.sh"
echo edited >> "$tmp/repo-edited-live/scripts/a.sh"; echo edited >> "$tmp/repo-edited-expired/scripts/a.sh"
mkdebt "$tmp/repo-absent-live" "$LIVE"; mkdebt "$tmp/repo-absent-expired" "$LAPSED"
mkdebt "$tmp/repo-edited-live" "$LIVE"; mkdebt "$tmp/repo-edited-expired" "$LAPSED"
mkdebt "$tmp/repo-retired" "$LIVE" "retired: 2026-01-01"
run "absent file + live contract-debt entry: ACCEPTED, exit 0" 0 "$tmp/repo-absent-live" "" \
  "ACCEPTED DRIFT (1)" "scripts/a.sh -- ABSENT; accepted by contract-debt entry 'fork-a' (expires $LIVE)" "!LOCAL DRIFT" "!in step with the standard" "1 accepted"
run "absent file + no entry: LOCAL DRIFT, exit 1" 1 "$tmp/repo-absent-none" "" \
  "LOCAL DRIFT (1)" "scripts/a.sh -- vendored at scaffold time and now ABSENT" "!ACCEPTED DRIFT"
run "absent file + EXPIRED entry: LOCAL DRIFT, exit 1" 1 "$tmp/repo-absent-expired" "" \
  "LOCAL DRIFT (1)" "entry 'fork-a' EXPIRED $LAPSED" "!ACCEPTED DRIFT"
run "edited (hash mismatch) file + live entry: ACCEPTED, exit 0" 0 "$tmp/repo-edited-live" "" \
  "ACCEPTED DRIFT (1)" "edited here since scaffold; accepted by contract-debt entry 'fork-a'" "!LOCAL DRIFT"
run "edited file + expired entry: LOCAL DRIFT, exit 1" 1 "$tmp/repo-edited-expired" "" \
  "LOCAL DRIFT (1)" "EXPIRED $LAPSED" "!ACCEPTED DRIFT"
run "a RETIRED entry accepts nothing" 1 "$tmp/repo-retired" "" "LOCAL DRIFT (1)" "!ACCEPTED DRIFT"
run "--local honours acceptance too" 0 "$tmp/repo-edited-live" "--local" "ACCEPTED DRIFT (1)" "!LOCAL DRIFT"

# --- edge cases of the registry reader ---
# mkdebt2 <repo> <entry-lines...> : write `entries:` + the given raw lines
mkdebt2() { local r="$1"; shift; mkdir -p "$r/registries"; { echo 'entries:'; printf '%s\n' "$@"; } > "$r/registries/contract-debt.yaml"; }
# edge <name> <want-rc> <want-substr> <raw lines...> : fresh repo with scripts/a.sh absent
edgen=0
edge() {
  local name="$1" wrc="$2" w="$3"; shift 3; edgen=$((edgen+1))
  local r="$tmp/repo-edge$edgen"; mkrepo "$r" "${NEW[@]}"; rm "$r/scripts/a.sh"; mkdebt2 "$r" "$@"
  if [[ "$w" == '!'* ]]; then run "$name" "$wrc" "$r" "" "$w"; else run "$name" "$wrc" "$r" "" "$w"; fi
}
edge "template_paths: [] names nothing (no crash under set -u)" 1 "LOCAL DRIFT (1)" \
  '  - id: e' '    owner: o' '    expires: 2099-01-01' '    template_paths: []'
edge "block list (with a blank line inside) is accepted" 0 "ACCEPTED DRIFT (1)" \
  '  - id: e' '    owner: o' '    expires: 2099-01-01' '    template_paths:' '      - scripts/zzz.sh' '' '      - scripts/a.sh'
edge "expires: never is live" 0 "ACCEPTED DRIFT (1)" \
  '  - id: e' '    owner: o' '    expires: never' '    template_paths: [scripts/a.sh]'
edge "missing expires accepts nothing" 1 "LOCAL DRIFT (1)" \
  '  - id: e' '    owner: o' '    template_paths: [scripts/a.sh]'
edge "missing owner accepts nothing" 1 "LOCAL DRIFT (1)" \
  '  - id: e' '    expires: 2099-01-01' '    template_paths: [scripts/a.sh]'
edge "a commented-out entry accepts nothing" 1 "LOCAL DRIFT (1)" \
  '#  - id: e' '#    owner: o' '#    expires: 2099-01-01' '#    template_paths: [scripts/a.sh]'
edge "a bare retired: key (no value) retires the entry" 1 "LOCAL DRIFT (1)" \
  '  - id: e' '    owner: o' '    expires: 2099-01-01' '    retired:' '    template_paths: [scripts/a.sh]'
# the indent guard: prose that STARTS with `expires:` deeper inside `evidence: >` on an EXPIRED entry
edge "prose line 'expires: 2099' inside evidence cannot revive an expired entry" 1 "EXPIRED 2020-01-01" \
  '  - id: e' '    owner: o' '    expires: 2020-01-01' '    template_paths: [scripts/a.sh]' '    evidence: >' '      expires: 2099-01-01'

if (( pass == 0 )); then echo "check-template-drift selftest: ZERO cases ran"; exit 1; fi
if (( bad )); then echo "check-template-drift selftest: $bad of $((pass+bad)) case(s) failed"; exit 1; fi
echo "check-template-drift selftest: ok -- $pass case(s)"
