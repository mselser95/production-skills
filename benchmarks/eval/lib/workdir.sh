#!/usr/bin/env bash
# workdir.sh -- sourced by run.sh and lint.sh: ONE way to build the directory an
# agent (or a reference solver) starts from, so lint proves the grader on
# exactly the state a real cell hands the agent.
#
# grade.sh, reference/ and task.json live beside fixture/, never in it, and are
# never copied here -- the agent must not be able to read its own grader.

# eval_mkworkdir <task-dir> <dest>  -> 0 ok, 1 fixture/setup failed
eval_mkworkdir() {
  local task="$1" dest="$2"
  mkdir -p "$dest" || return 1
  if [[ -d "$task/fixture" ]]; then
    cp -R "$task/fixture/." "$dest/" || return 1
  fi
  # a clean repo with one commit; no user git config, hooks or identity leak in
  (
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    cd "$dest" || exit 1
    git init -q . \
      && git add -A \
      && git -c user.name=eval -c user.email=eval@example.invalid -c commit.gpgsign=false \
           commit -q --allow-empty -m "fixture"
  ) >/dev/null 2>&1 || return 1
  if [[ -f "$task/fixture.setup.sh" ]]; then
    (cd "$dest" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$task/fixture.setup.sh") >/dev/null 2>&1 || return 1
  fi
  return 0
}
