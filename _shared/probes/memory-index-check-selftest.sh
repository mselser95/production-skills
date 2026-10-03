#!/usr/bin/env bash
# memory-index-check-selftest.sh — every check of the memory-index hook shown
# RED on a fixture that violates it and GREEN on one that does not. The hook
# guards a bound the harness enforces silently (200 lines / 25 KB of MEMORY.md),
# so a check that cannot go red here would be decoration.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$here/../hooks/memory-index-check.sh"
[[ -f "$hook" ]] || { echo "memory-index-check selftest: hook not found at $hook"; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/memidx-selftest.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
pass=0 bad=0

mkfix() { # dir -> a valid store: index + 2 memories + 1 hub with 1 member
  local d="$1"; mkdir -p "$d"
  printf -- '---\nname: a\n---\nA\n' > "$d/a.md"
  printf -- '---\nname: b\n---\nB\n' > "$d/b.md"
  printf -- '---\nname: c\n---\nC\n' > "$d/c.md"
  printf -- '---\nname: hub-x\n---\n- [c](c.md) — in hub\n' > "$d/hub-x.md"
  printf -- '# idx\n- [a](a.md) — short\n- [b](b.md) — short\n- [hub](hub-x.md) — hub\n' > "$d/MEMORY.md"
}
run() { # name dir want(ok|FAIL) needle [extra args]
  local name="$1" d="$2" want="$3" needle="${4:-}"; shift 4
  local out rc
  out=$(bash "$hook" --strict "$@" "$d" 2>&1); rc=$?
  local first; first="$(head -n1 <<<"$out")"
  if [[ "$first" == "memory-index: $want"* && "$out" == *"$needle"* ]] \
     && { [[ "$want" == ok && $rc -eq 0 ]] || [[ "$want" == FAIL && $rc -eq 1 ]]; }; then
    pass=$((pass+1)); printf '  ok    %s\n' "$name"
  else
    bad=$((bad+1)); printf '  FAIL  %s -> rc=%s %s\n' "$name" "$rc" "$(head -n2 <<<"$out" | tr '\n' '|')"
  fi
}

mkfix "$tmp/ok";                                   run "valid store -> ok"                    "$tmp/ok" ok "4 memorias alcanzables"
mkfix "$tmp/lines"; for i in $(seq 1 200); do echo "- [a](a.md) — l$i" >> "$tmp/lines/MEMORY.md"; done
                                                   run "201+ lines -> FAIL"                   "$tmp/lines" FAIL "líneas > 200"
mkfix "$tmp/bytes"; for i in $(seq 1 190); do printf -- '- [a](a.md) — %0130d\n' 0 >> "$tmp/bytes/MEMORY.md"; done
                                                   run "over 25 KB -> FAIL (even under 200 lines)" "$tmp/bytes" FAIL "bytes > 25000"
mkfix "$tmp/long"; printf -- '- [a](a.md) — %0170d\n' 0 >> "$tmp/long/MEMORY.md"
                                                   run "one 180-char line -> FAIL"             "$tmp/long" FAIL "más de 160 chars"
mkfix "$tmp/broken"; echo '- [zz](zz.md) — gone' >> "$tmp/broken/MEMORY.md"
                                                   run "broken link -> FAIL"                  "$tmp/broken" FAIL "zz.md no existe"
mkfix "$tmp/orphan"; printf -- '---\nname: d\n---\nD\n' > "$tmp/orphan/d.md"
                                                   run "orphan memory -> FAIL, named"         "$tmp/orphan" FAIL "d.md"
mkfix "$tmp/viahub"; printf -- '# idx\n- [a](./a.md) — dot-slash\n- [b](b.md#notes) — anchor\n- [hub](hub-x.md) — hub\n' > "$tmp/viahub/MEMORY.md"
                                                   run "./x.md and x.md#anchor links count -> ok" "$tmp/viahub" ok "4 memorias alcanzables"
mkfix "$tmp/hubbroken"; echo '- [gone](gone.md) — missing' >> "$tmp/hubbroken/hub-x.md"
                                                   run "broken link inside a hub -> FAIL"      "$tmp/hubbroken" FAIL "link roto en hub-x.md: gone.md"
mkfix "$tmp/nested"; printf -- '---\nname: hub-y\n---\n- [c](c.md)\n' > "$tmp/nested/hub-y.md"; printf -- '- [hub-y](hub-y.md)\n' > "$tmp/nested/hub-x.md"
                                                   run "member only via a nested hub -> orphan (fails safe)" "$tmp/nested" FAIL "c.md"
mkfix "$tmp/nohub"; sed -i.bak '/hub-x/d' "$tmp/nohub/MEMORY.md"; rm -f "$tmp/nohub/MEMORY.md.bak"
                                                   run "hub unlinked -> its member is an orphan too" "$tmp/nohub" FAIL "2 memoria(s) sin línea"
mkdir -p "$tmp/noidx";                             run "missing MEMORY.md -> FAIL"            "$tmp/noidx" FAIL "no existe"

# settings resolution: unset -> FAIL naming the fix; set (with ~) -> resolves
mkdir -p "$tmp/cfg-unset"; echo '{}' > "$tmp/cfg-unset/settings.json"
out=$(CLAUDE_CONFIG_DIR="$tmp/cfg-unset" MEMORY_INDEX_DIR='' bash "$hook" --strict 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"autoMemoryDirectory no está seteado"* ]] && { pass=$((pass+1)); echo "  ok    autoMemoryDirectory unset -> FAIL, names the fix"; } || { bad=$((bad+1)); echo "  FAIL  unset setting rc=$rc: $out"; }
mkdir -p "$tmp/cfg-set" "$tmp/home"; mkfix "$tmp/home/mem"
echo '{"autoMemoryDirectory":"~/mem"}' > "$tmp/cfg-set/settings.json"
out=$(HOME="$tmp/home" CLAUDE_CONFIG_DIR="$tmp/cfg-set" MEMORY_INDEX_DIR='' bash "$hook" --strict 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"$tmp/home/mem"* ]] && { pass=$((pass+1)); echo "  ok    autoMemoryDirectory with ~ -> resolved and checked"; } || { bad=$((bad+1)); echo "  FAIL  set setting rc=$rc: $out"; }

# the hook must also run under macOS /bin/bash 3.2 (empty arrays under set -u)
if [[ -x /bin/bash ]]; then
  out=$(/bin/bash "$hook" --strict "$tmp/ok" 2>&1); rc=$?
  [[ $rc -eq 0 && "$out" == "memory-index: ok"* ]] && { pass=$((pass+1)); echo "  ok    /bin/bash $(/bin/bash -c 'echo ${BASH_VERSION%%(*}') -> ok on valid store"; } || { bad=$((bad+1)); echo "  FAIL  /bin/bash rc=$rc: $out"; }
  out=$(/bin/bash "$hook" --strict "$tmp/orphan" 2>&1); rc=$?
  [[ $rc -eq 1 && "$out" == *"d.md"* ]] && { pass=$((pass+1)); echo "  ok    /bin/bash -> FAIL with violations listed"; } || { bad=$((bad+1)); echo "  FAIL  /bin/bash orphan rc=$rc: $out"; }
fi

# the re-index generator: output within the bound, byte-identical on re-run
gen="$here/../../scripts/memory-reindex.py"
if [[ -f "$gen" ]]; then
  cp -r "$tmp/ok" "$tmp/gen"; python3 "$gen" "$tmp/gen" >/dev/null 2>&1; cp "$tmp/gen/MEMORY.md" "$tmp/gen.first"
  python3 "$gen" "$tmp/gen" >/dev/null 2>&1
  if cmp -s "$tmp/gen/MEMORY.md" "$tmp/gen.first" && bash "$hook" --strict "$tmp/gen" >/dev/null 2>&1; then
    pass=$((pass+1)); echo "  ok    memory-reindex.py: idempotent and the result passes the gate"
  else bad=$((bad+1)); echo "  FAIL  memory-reindex.py: not idempotent or result fails the gate: $(bash "$hook" --strict "$tmp/gen" 2>&1 | head -n 2 | tr '\n' '|')"; fi
else echo "  n/a   memory-reindex.py not found beside the probes (vendored layout)"; fi

# hook mode (no --strict) never exits non-zero, even on FAIL
out=$(bash "$hook" "$tmp/lines" 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == "memory-index: FAIL"* ]] && { pass=$((pass+1)); echo "  ok    hook mode: FAIL printed, exit 0"; } || { bad=$((bad+1)); echo "  FAIL  hook mode rc=$rc"; }

echo "memory-index-check selftest: $pass ok, $bad failed"
if (( bad > 0 )); then exit 1; fi
echo "ok -- $pass case(s)"
