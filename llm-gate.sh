#!/usr/bin/env bash
# llm-gate: find LLM / AI-assistant attribution in git commits.
#
# Flags co-author style trailers that name an AI assistant, "Generated with <tool>"
# footers, AI session/thread links, AI-specific trailer keys, and commits whose
# author or committer is an AI bot. Runs anywhere with bash 3.2+ and git.
#
# Usage:
#   llm-gate.sh [options] <revision-range>...  check every commit in the range(s),
#                                              e.g. origin/main..HEAD
#   llm-gate.sh [options] --message-file FILE  check one message (commit-msg hook);
#                                              FILE may be - for stdin
#   llm-gate.sh [options] --filter             copy a message from stdin to stdout
#                                              without the flagged lines
# Options:
#   --label TEXT            what to call --message-file input in findings
#   --no-identities         skip the commit author/committer check
#   --extra-patterns FILE   extra ERE patterns, one per line; a matching line is flagged
#   --ignore-patterns FILE  ERE patterns, one per line; a matching line is never flagged
#   -q, --quiet             findings only, no remediation hint
#   -h, --help
# Patterns are case-insensitive. Exit status: 0 clean, 1 attribution found,
# 2 usage or git error. Under GitHub Actions, findings are also written as
# error annotations and to the job summary.
set -euo pipefail
# Byte-wise matching: messages need not be valid UTF-8, and the negated classes
# below are ASCII ranges because some C-locale regex engines (MSYS) won't match
# high bytes with [^[:alnum:]].
export LC_ALL=C

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "$0"; }
die() { printf 'llm-gate: %s\n' "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Patterns. Matched with bash's [[ =~ ]] (POSIX ERE) under nocasematch.

b='([^a-zA-Z0-9_]|$)'   # right word boundary

# AI tools, models, and vendors. Used only where the surrounding text already
# says "attribution" (a "Generated with ..." footer, an Assisted-by trailer),
# so plain product names are safe here.
tools='claude|anthropic|copilot|chat ?gpt|openai|codex|gpt-?[0-9][[:alnum:].]*|o[1-9](-mini|-pro)?'
tools+='|gemini|bard|jules|cursor|aider|devin|codeium|windsurf|codewhisperer|amazon[ -]?q|kiro'
tools+='|tabnine|cody|amp ?code|sweep ?ai|coderabbit(ai)?|lovable|v0\.dev|bolt\.new|replit|deepseek'
tools+='|qwen|grok|mistral|codestral|llama ?[0-9]|opencode|open ?hands|junie|cline|roo ?code'
tools+='|augment ?code|factory droid|droid|crush|warp|goose|continue\.dev|phind|perplexity'
tools+='|ai|llms?|an? (ai|llm)|(an? )?(large )?language models?|ai (assistant|agent|tool|model|pair programmer)'

# Names an AI identity may use in "Name <email>" (trailer values, commit authors).
# Matched only as the whole name, so "Claude Monet <...>" or "Devin Lee <...>"
# is a person, while "Claude Opus 4 <...>" or "Devin AI <...>" is not.
id_tools="${tools}|amp|sweep|codegen|factory"
vendor='((github|google|openai|anthropic|amazon|aws|microsoft|jetbrains|sourcegraph|charm|factory|cognition|xai|meta|mistral)[[:space:]]+)?'
suffix='(code|cli|agent|agents|assistant|assist|ai|bot|swe|coding|connector|integration|developer'
suffix+='|dev|labs|opus|sonnet|haiku|fable|instant|pro|flash|lite|ultra|mini|nano|turbo|preview'
suffix+='|max|high|low|medium|thinking|reasoning|chat|[0-9][[:alnum:].-]*|\([^)]*\)|\[bot\])'
re_id_name="^[[:space:]\"']*${vendor}(${id_tools})([[:space:]-]*${suffix})*[[:space:]\"']*(<|$)"
re_id_bot="(^|[^a-zA-Z0-9]|-)(${id_tools}|amazon-q)(-[[:alnum:]-]*)?\[bot\]"
re_id_tag="\((${id_tools})\)"   # aider-style "Jane Doe (aider)"
re_id_email='[0-9]+\+copilot@users\.noreply\.github\.com|(^|[<[:space:]])((noreply|no-reply)@(anthropic|openai)\.com'
re_id_email+='|(noreply|no-reply|ai|[[:alnum:]._-]*(agent|bot|amp|crush|droid|devin|aider|opencode|warp|cursor))'
re_id_email+='@(cursor\.(com|sh)|aider\.chat|ampcode\.com|opencode\.ai|charm\.land|warp\.dev|devin\.ai'
re_id_email+='|cognition\.ai|factory\.ai|kiro\.dev|codeium\.com|windsurf\.com|lovable\.dev|replit\.com'
re_id_email+='|augmentcode\.com|cline\.bot|tabnine\.com|sourcegraph\.com|all-hands\.dev))'

# Person trailers (Co-authored-by, Signed-off-by, Helped-by, ...): flagged when
# the value is an AI identity.
re_trailer='^[[:space:]]*([[:alpha:]][[:alnum:]-]*-by)[[:space:]]*:[[:space:]]*(.*[^[:space:]])'
# Tool trailers: flagged when the value names a tool anywhere.
re_tool_key='^[[:space:]]*(assisted|generated|created|made|written|built)-(by|with|using)[[:space:]]*:(.*)'
re_tool_value="(^|[^a-zA-Z0-9_])(${tools})${b}"
# Trailer keys that only AI tooling writes (AI-Assisted:, Amp-Thread-ID:, ...).
re_ai_key='^[[:space:]]*((ai|llm|genai)|(claude|codex|cursor|amp|aider|copilot|devin|jules|gemini|chatgpt|openai|anthropic|opencode|crush|droid|factory|warp|kiro|windsurf|cline))-[[:alnum:]-]+[[:space:]]*:'

# "Generated with <tool>" style footers, at the start of a line after optional
# emoji/markup, optionally as "This PR was ...".
lead='^[^a-zA-Z0-9]*((this|the)[[:space:]]+([[:alnum:]-]+[[:space:]]+){0,4}(was|were|is|are|has been|have been)[[:space:]]+)?([[:alpha:]]+ly[[:space:]]+)?'
verbs_by='(generated|created|co-?authored|co-?written|co-?developed|co-?created|assisted|powered|drafted|produced|vibe-?coded)[[:space:]]+(with|by|using|via|through|in)'
verbs_with='(written|authored|made|built|developed|coded|implemented)[[:space:]]+(with|using|via|through)'
helped='(with[[:space:]]+)?(the[[:space:]]+)?(help|assistance)[[:space:]]+(from|of|by)'
glue='[^a-zA-Z0-9]*((the|an?)[[:space:]]+)?((help|assistance|aid)[[:space:]]+(of|from)[[:space:]]+((the|an?)[[:space:]]+)?)?[^a-zA-Z0-9]*'
re_footer="${lead}(${verbs_by}|${verbs_with}|${helped})${glue}${vendor}(${tools})${b}"

# Links to AI chat sessions, threads, and tasks.
re_link='claude\.ai/(code|chat|share)|chatgpt\.com/(codex|share|c|g)/|chat\.openai\.com/(share|c)/'
re_link+='|ampcode\.com/threads|devin\.ai/sessions|jules\.google\.com/(task|session)'
re_link+='|cursor\.com/(agents|background-agent)|opencode\.ai/s/|gemini\.google\.com/(share|app)/'
re_link+='|g\.co/gemini/share|copilot\.microsoft\.com/(shares|chats)|v0\.dev/chat|lovable\.dev/projects'

# ---------------------------------------------------------------------------

extra=()
ignore=()
check_identities=1
quiet=0
mode=range
message_file=
label=
ranges=()

load_patterns() {  # FILE ARRAY_NAME
  local line
  [[ -r $1 ]] || die "can't read pattern file: $1"
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z $line || $line == \#* ]] && continue
    eval "$2+=(\"\$line\")"
  done <"$1"
}

while (($#)); do
  case $1 in
    --message-file) (($# > 1)) || die "$1 needs a file"; mode=message; message_file=$2; shift 2 ;;
    --filter) mode=filter; shift ;;
    --label) (($# > 1)) || die "$1 needs text"; label=$2; shift 2 ;;
    --no-identities) check_identities=0; shift ;;
    --extra-patterns) (($# > 1)) || die "$1 needs a file"; load_patterns "$2" extra; shift 2 ;;
    --ignore-patterns) (($# > 1)) || die "$1 needs a file"; load_patterns "$2" ignore; shift 2 ;;
    -q | --quiet) quiet=1; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; ranges+=("$@"); break ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) ranges+=("$1"); shift ;;
  esac
done

shopt -s nocasematch

# classify LINE IS_SUBJECT: sets $rule and returns 0 when the line is attribution.
# Trailer rules skip the subject line, where "ai-tools: ..." is a commit scope.
classify() {
  local line=$1 re
  rule=
  for re in ${ignore[@]+"${ignore[@]}"}; do
    [[ $line =~ $re ]] && return 1
  done
  if ((!$2)); then
    if [[ $line =~ $re_ai_key ]]; then
      rule='AI trailer'
    elif [[ $line =~ $re_tool_key ]] && [[ ${BASH_REMATCH[3]} =~ $re_tool_value ]]; then
      rule='AI tool trailer'
    elif [[ $line =~ $re_trailer ]] && is_ai_identity "${BASH_REMATCH[2]}"; then
      rule='AI co-author trailer'
    fi
  fi
  if [[ -z $rule ]]; then
    if [[ $line =~ $re_footer ]]; then
      rule='AI attribution line'
    elif [[ $line =~ $re_link ]]; then
      rule='AI session link'
    else
      for re in ${extra[@]+"${extra[@]}"}; do
        if [[ $line =~ $re ]]; then
          rule='extra pattern'
          break
        fi
      done
    fi
  fi
  [[ -n $rule ]]
}

is_ai_identity() {
  [[ $1 =~ $re_id_name || $1 =~ $re_id_bot || $1 =~ $re_id_tag || $1 =~ $re_id_email ]]
}

in_actions() { [[ ${GITHUB_ACTIONS:-} == true ]]; }

found=0
summary_rows=

# finding WHERE SUBJECT RULE TEXT
finding() {
  found=$((found + 1))
  printf '  %-22s %s\n' "$3:" "$4"
  if in_actions; then
    local title="llm-gate: $3 in $1"
    printf '::error title=%s::%s\n' "$(esc_prop "$title")" "$(esc_data "$4")"
    summary_rows+="| $(md "$1") | $(md "$2") | $3 | $(md "$4") |"$'\n'
  fi
}

# Replacements are quoted so bash 5.2's patsub_replacement leaves "&" alone.
esc_data() { local s=${1//%/"%25"}; s=${s//$'\r'/"%0D"}; printf '%s' "${s//$'\n'/"%0A"}"; }
esc_prop() { local s; s=$(esc_data "$1"); s=${s//:/"%3A"}; printf '%s' "${s//,/"%2C"}"; }
md() {
  local s=${1//&/"&amp;"}
  s=${s//</"&lt;"}; s=${s//>/"&gt;"}; s=${s//|/"\\|"}
  printf '%s' "$s"
}

# check_text WHERE SUBJECT TEXT
check_text() {
  local line header=0 first=1
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    if classify "$line" "$first"; then
      if ((!header)); then
        printf '%s %s\n' "$1" "$2"
        header=1
      fi
      finding "$1" "$2" "$rule" "$line"
    fi
    first=0
  done <<<"$3"
}

check_identity() {  # WHERE SUBJECT ROLE IDENTITY
  local re
  for re in ${ignore[@]+"${ignore[@]}"}; do
    [[ $4 =~ $re ]] && return 0
  done
  if is_ai_identity "$4"; then
    printf '%s %s\n' "$1" "$2"
    finding "$1" "$2" "AI $3" "$4"
  fi
}

check_range() {
  local count=0 rec sha author committer body subject
  git rev-parse --git-dir >/dev/null 2>&1 || die 'not in a git repository'
  # Fail on a bad range before reading the log, so a typo can't pass as "clean".
  git rev-list --count "$@" >/dev/null || die "bad revision range: $*"
  while IFS= read -r -d $'\x1e' rec; do
    rec=${rec#$'\n'}
    [[ -z $rec ]] && continue
    sha=${rec%%$'\x1f'*}; rec=${rec#*$'\x1f'}
    author=${rec%%$'\x1f'*}; rec=${rec#*$'\x1f'}
    committer=${rec%%$'\x1f'*}; body=${rec#*$'\x1f'}
    subject=${body%%$'\n'*}
    count=$((count + 1))
    if ((check_identities)); then
      check_identity "${sha:0:12}" "$subject" author "$author"
      check_identity "${sha:0:12}" "$subject" committer "$committer"
    fi
    check_text "${sha:0:12}" "$subject" "$body"
  done < <(git -c log.showSignature=false log --no-color --format='%H%x1f%an <%ae>%x1f%cn <%ce>%x1f%B%x1e' "$@")
  printf 'llm-gate: checked %d commit(s) in %s\n' "$count" "$*" >&2
}

remediation() {
  cat >&2 <<EOF

llm-gate: AI attribution found. Remove it before merging:
  * One commit: git commit --amend (or git rebase -i, "reword") and delete the lines above.
  * Every commit on the branch, with llm-gate.sh on your PATH:
      git rebase -x 'git log -1 --format=%B | llm-gate.sh --filter | git commit --amend --no-verify -F -' ${LLM_GATE_UPSTREAM:-origin/main}
      git push --force-with-lease
  * An AI author/committer needs a new identity: add --reset-author to the amend.
  * Fix the pull request title/description in the GitHub UI; the check re-runs on edit.
EOF
}

write_summary() {
  in_actions && [[ -n ${GITHUB_STEP_SUMMARY:-} ]] || return 0
  {
    if ((found)); then
      printf '### llm-gate: %d AI attribution finding(s)\n\n' "$found"
      printf '| Where | Subject | Rule | Line |\n|---|---|---|---|\n%s\n' "$summary_rows"
      printf 'Remove these lines (or re-author the commits) and push again. See https://github.com/cy-pca/llm-gate#fixing-a-failed-check\n'
    else
      printf '### llm-gate: no AI attribution found in %s\n' "${label:-the checked commits}"
    fi
  } >>"$GITHUB_STEP_SUMMARY"
}

case $mode in
  filter)
    # Drop flagged lines, then tidy the gaps they leave the way git's default
    # cleanup would: no leading or trailing blank lines, no runs of them.
    out='' blank=0 first=1
    while IFS= read -r line || [[ -n $line ]]; do
      line=${line%$'\r'}
      if classify "$line" "$first"; then
        first=0
        continue
      fi
      first=0
      if [[ $line =~ ^[[:space:]]*$ ]]; then
        blank=1
      else
        if ((blank)) && [[ -n $out ]]; then out+=$'\n'; fi
        out+="$line"$'\n'
        blank=0
      fi
    done
    printf '%s' "$out"
    exit 0
    ;;
  message)
    ((${#ranges[@]} == 0)) || die '--message-file takes no revision range'
    if [[ $message_file == - ]]; then
      text=$(cat)
      : "${label:=stdin}"
    else
      [[ -r $message_file ]] || die "can't read message file: $message_file"
      # A commit-msg hook's file still holds git's "#" comments and, with
      # commit -v, the diff below the scissors line; neither is the message.
      text=$(sed -e '/^# -\{24\} >8 -\{24\}$/,$d' -e '/^#/d' "$message_file")
      : "${label:=$message_file}"
    fi
    check_text "$label" '' "$text"
    ;;
  range)
    ((${#ranges[@]})) || { usage >&2; exit 2; }
    check_range "${ranges[@]}"
    ;;
esac

write_summary
if ((found)); then
  ((quiet)) || remediation
  exit 1
fi
