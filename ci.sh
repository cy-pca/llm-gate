#!/usr/bin/env bash
# GitHub Actions glue for llm-gate. Works out which commits a pull request,
# merge-queue group, or push adds, makes sure they are available locally, and
# runs llm-gate.sh on them and on the pull request title and description.
#
# Configured through the LLM_GATE_* variables that action.yml sets.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
gate=$here/llm-gate.sh
zero=0000000000000000000000000000000000000000

base=${LLM_GATE_BASE:-}
head=${LLM_GATE_HEAD:-}
default_branch=${LLM_GATE_DEFAULT_BRANCH:-}
pr=${LLM_GATE_PR_NUMBER:-}
tmp=${RUNNER_TEMP:-${TMPDIR:-/tmp}}

notice() { printf '::notice title=llm-gate::%s\n' "$*"; }
fatal() { printf '::error title=llm-gate::%s\n' "$*"; exit 2; }

args=()
[[ ${LLM_GATE_CHECK_IDENTITIES:-true} == true ]] || args+=(--no-identities)
if [[ -n ${LLM_GATE_EXTRA_PATTERNS:-} ]]; then
  printf '%s\n' "$LLM_GATE_EXTRA_PATTERNS" >"$tmp/llm-gate-extra-patterns"
  args+=(--extra-patterns "$tmp/llm-gate-extra-patterns")
fi
if [[ -n ${LLM_GATE_IGNORE_PATTERNS:-} ]]; then
  printf '%s\n' "$LLM_GATE_IGNORE_PATTERNS" >"$tmp/llm-gate-ignore-patterns"
  args+=(--ignore-patterns "$tmp/llm-gate-ignore-patterns")
fi
# Branch named in the remediation hint.
export LLM_GATE_UPSTREAM="origin/${LLM_GATE_BASE_REF:-${default_branch:-main}}"

status=0
record() { if (($1 > status)); then status=$1; fi; }

has_commit() { git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null; }

# Use the job's own checkout when it already holds the full history of both ends.
use_checkout() {
  local ws=${GITHUB_WORKSPACE:-}
  [[ -n $ws && -n $base && $base != "$zero" ]] || return 1
  [[ $(git -C "$ws" rev-parse --is-shallow-repository 2>/dev/null) == false ]] || return 1
  has_commit "$ws" "$base" && has_commit "$ws" "$head" || return 1
  repo=$ws
  range="$base..$head"
  echo "llm-gate: using the checkout at $ws"
}

# Otherwise fetch just the commits (no trees or blobs) into a scratch repository.
fetch_commits() {
  [[ -n ${GITHUB_REPOSITORY:-} ]] || fatal 'GITHUB_REPOSITORY is not set'
  repo=$tmp/llm-gate.git
  rm -rf "$repo"
  trap 'rm -rf "$repo"' EXIT
  git init -q --bare "$repo"
  git -C "$repo" remote add origin "${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY"
  if [[ -n ${LLM_GATE_TOKEN:-} ]]; then
    local auth
    auth=$(printf 'x-access-token:%s' "$LLM_GATE_TOKEN" | base64 | tr -d '\n')
    printf '::add-mask::%s\n' "$auth"
    # printf is a builtin, so the header never shows up in a process listing.
    printf '[http]\n\textraheader = AUTHORIZATION: basic %s\n' "$auth" >>"$repo/config"
  fi
  fetch() { git -C "$repo" fetch -q --no-tags --filter=tree:0 origin "$@"; }

  fetch "+$head:refs/llm-gate/head" ||
    { [[ -n $pr ]] && fetch "+refs/pull/$pr/head:refs/llm-gate/head"; } ||
    fatal "can't fetch head commit $head from $GITHUB_REPOSITORY"

  if [[ -n $base && $base != "$zero" ]] && fetch "+$base:refs/llm-gate/base"; then
    :
  elif [[ -n $default_branch ]] && fetch "+refs/heads/$default_branch:refs/llm-gate/base"; then
    notice "no usable base commit; checking commits not on $default_branch"
  else
    fatal "can't fetch base commit ${base:-<none>} from $GITHUB_REPOSITORY"
  fi
  range=refs/llm-gate/base..refs/llm-gate/head
}

if [[ -z $head ]]; then
  fatal 'no head commit; set the head input for this event'
elif [[ $head == "$zero" ]]; then
  notice 'branch deleted; no commits to check'
else
  use_checkout || fetch_commits
  echo "llm-gate: checking ${base:-$default_branch}..$head"
  (cd "$repo" && bash "$gate" ${args[@]+"${args[@]}"} "$range") || record $?
fi

if [[ ${LLM_GATE_CHECK_PR_TEXT:-true} == true && -n "${LLM_GATE_PR_TITLE:-}${LLM_GATE_PR_BODY:-}" ]]; then
  quiet=()
  ((status != 1)) || quiet=(-q)
  printf '%s\n\n%s\n' "${LLM_GATE_PR_TITLE:-}" "${LLM_GATE_PR_BODY:-}" |
    bash "$gate" ${args[@]+"${args[@]}"} ${quiet[@]+"${quiet[@]}"} \
      --label "pull request${pr:+ #$pr} title/description" --message-file - || record $?
fi

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  if ((status == 0)); then echo result=pass; else echo result=fail; fi >>"$GITHUB_OUTPUT"
fi
exit "$status"
