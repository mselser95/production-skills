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

if (( pass == 0 )); then echo "check-template-drift selftest: ZERO cases ran"; exit 1; fi
if (( bad )); then echo "check-template-drift selftest: $bad of $((pass+bad)) case(s) failed"; exit 1; fi
echo "check-template-drift selftest: ok -- $pass case(s)"
