#!/usr/bin/env bash
# brand-strings-selftest.sh — every rule of brand-strings.sh shown firing on a
# fixture where its property is false, the cost bound proven with counting
# wrappers, and five mutations of the probe each shown RED.
# Hermetic (temp dir only, invented names only), sequential, a few seconds.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
real_probe="$here/brand-strings.sh"
example="$here/../brand-denylist.example.txt"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/brand-strings-selftest.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export GIT_CEILING_DIRECTORIES="$tmp"   # a fixture is never "inside" some enclosing repo
unset BRAND_DENYLIST
pass=0 bad=0 first_bad="" probe="$real_probe" quiet=0 only=""

deny="$tmp/deny.txt"
printf '# invented names only\nacmecorp\n\nExampleBrand\n' >"$deny"

# check <name> <want_rc> <must contain|-> <must NOT contain|-> <tree> [probe args...]
check() {
  [[ -z "$only" || "$1" == *"$only"* ]] || return 0   # a mutation runs just its own case
  local name="$1" want="$2" has="$3" hasnt="$4" t="$5" out rc; shift 5
  out="$(bash "$probe" "$t" "$@" 2>&1)"; rc=$?
  if [[ $rc -eq $want && ( "$has" == - || "$out" == *"$has"* ) && ( "$hasnt" == - || "$out" != *"$hasnt"* ) ]]; then
    pass=$((pass + 1))
  else
    bad=$((bad + 1)); [[ -n "$first_bad" ]] || first_bad="$name"
    [[ $quiet -eq 1 ]] || echo "FAIL [$name]: rc=$rc want=$want has='$has' hasnt='$hasnt' got: $out"
  fi
}
mkt() { rm -rf "${tmp:?}/$1"; mkdir -p "$tmp/$1"; echo "$tmp/$1"; }

# ---- fixtures ----
clean=$(mkt clean); echo 'export const a = 1;' >"$clean/a.ts"; echo '# readme' >"$clean/README.md"
comment=$(mkt comment); printf 'line one\n// made by AcmeCorp\n' >"$comment/a.ts"
pdir=$(mkt pdir); mkdir -p "$pdir/acmecorp-assets"; echo ok >"$pdir/acmecorp-assets/x.txt"
pfile=$(mkt pfile); echo ok >"$pfile/ExampleBrand-logo.txt"
svg=$(mkt svg); printf '<svg><title>Logo of examplebrand</title></svg>\n' >"$svg/i.svg"
json=$(mkt json); printf '{"vendor": "acmecorp"}\n' >"$json/d.json"
mixed=$(mkt mixed); echo 'ACMECORP' >"$mixed/up.css"
dot=$(mkt dot); echo 'KEY=acmecorp' >"$dot/.env.local"
lock=$(mkt lock); printf '"resolved": "https://example.test/acmecorp/x.tgz"\n' >"$lock/package-lock.json"
skip=$(mkt skip); mkdir -p "$skip/node_modules/p" "$skip/.git"; echo acmecorp >"$skip/node_modules/p/i.js"; echo acmecorp >"$skip/.git/config"; echo ok >"$skip/a.txt"
bin=$(mkt bin); printf 'acmecorp\0\1\2' >"$bin/blob.dat"; echo ok >"$bin/a.txt"
binname=$(mkt binname); printf 'xx\0\1' >"$binname/acmecorp.bin"
spaces=$(mkt spaces); mkdir -p "$spaces/my dir"; echo 'acmecorp' >"$spaces/my dir/a file.ts"
empty=$(mkt empty)
gitrepo=$(mkt gitrepo); git -C "$gitrepo" init -q 2>/dev/null; mkdir -p "$gitrepo/ignored"
echo 'ignored/' >"$gitrepo/.gitignore"; echo acmecorp >"$gitrepo/ignored/x.txt"; echo ok >"$gitrepo/a.ts"; echo 'acmecorp' >"$gitrepo/new.ts"

# ---- the cases ----
suite() {
  check "clean tree is ok" 0 "brand-strings: ok -- 2 file(s), 2 entries, 0 binary skipped" - "$clean" --denylist "$deny"
  check "entry in a code comment: path:line" 1 "a.ts:2: acmecorp" - "$comment" --denylist "$deny"
  check "comment hit ends in FAIL summary" 1 "brand-strings: FAIL -- 1 finding(s)" - "$comment" --denylist "$deny"
  check "entry in a directory name" 1 "acmecorp-assets/x.txt: acmecorp (in path)" - "$pdir" --denylist "$deny"
  check "entry in a file name (case differs)" 1 "ExampleBrand-logo.txt: examplebrand (in path)" - "$pfile" --denylist "$deny"
  check "entry inside an SVG title" 1 "i.svg:1: examplebrand" - "$svg" --denylist "$deny"
  check "entry inside JSON" 1 "d.json:1: acmecorp" - "$json" --denylist "$deny"
  check "entry in a different case (content)" 1 "up.css:1: acmecorp" - "$mixed" --denylist "$deny"
  check "entry in a dotfile" 1 ".env.local:1: acmecorp" - "$dot" --denylist "$deny"
  check "entry in a lockfile" 1 "package-lock.json:1: acmecorp" - "$lock" --denylist "$deny"
  check "node_modules/ and .git/ are not scanned" 0 "brand-strings: ok -- 1 file(s)" "acmecorp" "$skip" --denylist "$deny"
  check "binary content not reported, counted as skipped" 0 "2 entries, 1 binary skipped" "blob.dat:" "$bin" --denylist "$deny"
  check "binary file reported when its NAME matches" 1 "acmecorp.bin: acmecorp (in path)" - "$binname" --denylist "$deny"
  check "paths with spaces" 1 "my dir/a file.ts:1: acmecorp" - "$spaces" --denylist "$deny"
  check "git tree: untracked hit reported" 1 "new.ts:1: acmecorp" - "$gitrepo" --denylist "$deny"
  check "git tree: ignored file not reported" 1 - "ignored/x.txt" "$gitrepo" --denylist "$deny"
  : >"$tmp/empty.txt"; printf '# only a comment\n\n   \n' >"$tmp/comments.txt"; printf 'ok\n' >"$tmp/short.txt"
  check "empty denylist refuses (exit 2)" 2 "empty denylist" - "$clean" --denylist "$tmp/empty.txt"
  check "comments-only denylist refuses" 2 "no effective entries" - "$clean" --denylist "$tmp/comments.txt"
  check "missing denylist file refuses" 2 "missing or unreadable" - "$clean" --denylist "$tmp/nope.txt"
  check "no denylist at all refuses" 2 "no denylist" - "$clean"
  check "2-char entry refuses" 2 "shorter than 3" - "$clean" --denylist "$tmp/short.txt"
  check "empty tree refuses" 2 "nothing was checked" - "$empty" --denylist "$deny"
  check "the committed example list is valid and clean on a clean tree" 0 "3 entries" - "$clean" --denylist "$example"
}
suite_env() {
  local o rc
  o=$(BRAND_DENYLIST="$tmp/empty.txt" bash "$probe" "$comment" --denylist "$deny" 2>&1); rc=$?
  if [[ $rc -eq 1 && "$o" == *"a.ts:2: acmecorp"* ]]; then pass=$((pass + 1)); else bad=$((bad + 1)); first_bad="${first_bad:-flag-beats-env}"; fi
  o=$(BRAND_DENYLIST="$deny" bash "$probe" "$comment" 2>&1); rc=$?
  if [[ $rc -eq 1 && "$o" == *"a.ts:2: acmecorp"* ]]; then pass=$((pass + 1)); else bad=$((bad + 1)); first_bad="${first_bad:-env-used}"; fi
}

# ---- cost bound: external-process count must not depend on tree size ----
wrap="$tmp/wrap"; mkdir -p "$wrap"; cnt="$tmp/count"
for c in git grep find sed awk sort wc cat mktemp rm head; do
  real="$(command -v "$c" 2>/dev/null)"; [[ -x "$real" ]] || continue
  printf '#!/bin/sh\necho x >>"$BS_COUNT"\nexec %s "$@"\n' "$real" >"$wrap/$c"; chmod +x "$wrap/$c"
done
mk_big() { # <dir> <nfiles> [git]: one finding, otherwise neutral
  local d="$1" n="$2" i; mkdir -p "$d"
  for ((i = 0; i < n; i++)); do
    [[ $((i % 100)) -eq 0 ]] && mkdir -p "$d/d$((i / 100))"
    printf 'const v%d = %d;\nexport default v%d;\n' "$i" "$i" "$i" >"$d/d$((i / 100))/f$i.ts"
  done
  echo '// examplebrand' >"$d/d0/f0.ts"
  [[ "${3:-}" == git ]] && git -C "$d" init -q 2>/dev/null
  return 0
}
count_procs() { : >"$cnt"; BS_COUNT="$cnt" PATH="$wrap:$PATH" bash "$real_probe" "$1" --denylist "$deny" >/dev/null 2>&1; wc -l <"$cnt" | tr -d ' '; }
bound() {
  local mode="$1" a b
  [[ $mode == git ]] && { git -C "$tmp/s20" init -q 2>/dev/null; git -C "$tmp/s2000" init -q 2>/dev/null; }
  a=$(count_procs "$tmp/s20"); b=$(count_procs "$tmp/s2000")
  echo "  process count ($mode-mode): 20 files=$a, 2000 files=$b"
  if [[ -n "$a" && "$a" -gt 0 && "$a" == "$b" ]]; then pass=$((pass + 1)); else bad=$((bad + 1)); echo "FAIL [process count ($mode)]: $a vs $b"; fi
}

suite; suite_env
mk_big "$tmp/s20" 20; mk_big "$tmp/s2000" 2000
bound plain; bound git

# ---- mutations: each must turn some case RED on a scratch copy ----
mutate() { # <label> <case-name fragment> <sed expression>
  local copy="$tmp/mut.sh" p0=$pass b0=$bad
  sed "$3" "$real_probe" >"$copy"
  if cmp -s "$copy" "$real_probe"; then bad=$((bad + 1)); echo "FAIL [mutation $1]: the sed did not change the probe"; return; fi
  probe="$copy" quiet=1 first_bad="" only="$2"; suite
  local fb="$first_bad"; probe="$real_probe" quiet=0 only=""
  # drop the mutant's own failures from the tally: they are the point
  pass=$p0; bad=$b0
  if [[ -n "$fb" ]]; then pass=$((pass + 1)); echo "  RED  mutation '$1' -> case failed: $fb"
  else bad=$((bad + 1)); echo "FAIL [mutation $1]: GREEN -- no case noticed"; fi
}
mutate "path scan removed" "directory name" 's/if (index(p, e\[i\]))/if (0 \&\& index(p, e[i]))/'
mutate "case-insensitivity removed" "different case" 's/-Iino/-Ino/; s/-rIino/-rIno/; s/p = tolower(\$0)/p = $0/'
mutate "empty-list guard removed" "comments-only" 's/^\[\[ \$entries -gt 0 \]\] || die2.*$/true/'
mutate "binary files not counted" "counted as skipped" 's/^nbin=.*$/nbin=0/'
mutate "node_modules exclusion removed" "node_modules/ and" 's/-o -name node_modules/-o -name .git/; s/ --exclude-dir=node_modules//g'

echo "$pass ok, $bad failed"
[[ $bad -eq 0 ]]
