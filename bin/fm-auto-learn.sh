#!/usr/bin/env bash
# fm-auto-learn.sh - file one automatic learning into the captain's log.
#
# Usage: fm-auto-learn.sh <state-dir> <task> <source> <key> <fact> [<correction>]
#        fm-auto-learn.sh --nm-fixes <state-dir> <task> <worktree> <base-ref>
#        fm-auto-learn.sh --ci-fixes <state-dir> <task> <owner/repo> <pr-number>
#
# --nm-fixes files one nm-finding learning per `no-mistakes(review|test|lint): <subject>`
# commit in <base-ref>..HEAD of <worktree>: the pipeline's fix commit for a finding
# it raised. `no-mistakes axi status` reports only finding counts, so the fix
# commit's subject is the recorded finding and its correction.
# --ci-fixes reads the PR's commits and each commit's check runs through `gh api`
# and files one ci-fix learning per check that concluded failure on a commit and
# success on a later one, naming the first commit where it passed.
#
# Called by the script that already sees a corrected belief, never by an agent:
#   nm-finding        a no-mistakes finding its pipeline fixed (fm-teardown.sh)
#   ci-fix            a CI check that failed and later passed on one PR (fm-pr-check.sh)
#   blocker           a `resolved` line closing a `blocked` key (fm-classify-lib.sh)
#   captain-override  a captain answer choosing another option than the
#                     recommendation the hold's reason named (fm-captain-hold.sh)
#   learned           a worker's `learned [at=<epoch>]: <fact>` line (fm-classify-lib.sh)
#
# <key> identifies the correction; the note is learnings/auto-<source>-<hash of
# source and key>.md, filed through `fm-log.sh learn --auto`, so the same
# correction never files twice and the note carries origin: auto for /stow.
# Its sources are --task <task> plus --project <basename of the task's project=>
# from <state-dir>/<task>.meta when present. <fact> becomes the title and, with
# <correction>, the body; each is whitespace-collapsed and bounded to
# FM_AUTO_LEARN_MAX_CHARS (default 400) characters so a learning holds the fact
# and its correction, never a transcript.
#
# Best effort by design: it prints nothing and always exits 0, so a caller's own
# work never depends on it. Nothing is filed when the log is off (fm-log.sh exits
# 3) or FM_AUTO_LEARN=off.
set -u

[ "${FM_AUTO_LEARN:-on}" != off ] || exit 0
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

case "${1:-}" in
  --nm-fixes)
    [ "$#" -eq 5 ] || exit 0
    git -C "$4" log --reverse --format=%s "$5..HEAD" 2>/dev/null | while IFS= read -r subject; do
      case "$subject" in
        'no-mistakes(review): '*|'no-mistakes(test): '*|'no-mistakes(lint): '*)
          step=${subject#no-mistakes(}; step=${step%%)*}
          "$SELF" "$2" "$3" nm-finding "$3:$subject" \
            "no-mistakes $step found the first draft wrong: ${subject#*: }" "fix commit: $subject" ;;
      esac
    done
    exit 0 ;;
  --ci-fixes)
    [ "$#" -eq 5 ] || exit 0
    command -v gh >/dev/null 2>&1 || exit 0
    failing=$'\n'
    while IFS=$'\t' read -r sha subject; do
      [ -n "$sha" ] || continue
      runs=$(gh api "repos/$4/commits/$sha/check-runs?per_page=100" \
        --jq '.check_runs | group_by(.name) | map(max_by(.id))[] | [.conclusion // "", .name] | @tsv' 2>/dev/null) || continue
      while IFS=$'\t' read -r conclusion name; do
        [ -n "$name" ] || continue
        case "$conclusion" in
          failure|timed_out)
            case "$failing" in *$'\n'"$name"$'\n'*) ;; *) failing="$failing$name"$'\n' ;; esac ;;
          success)
            case "$failing" in
              *$'\n'"$name"$'\n'*)
                failing=${failing/$'\n'"$name"$'\n'/$'\n'}
                "$SELF" "$2" "$3" ci-fix "$4#$5:$name:$sha" \
                  "CI check $name failed on $4 PR $5 until a later commit fixed it" "fixed by: $subject" ;;
            esac ;;
        esac
      done <<< "$runs"
    done < <(gh api "repos/$4/pulls/$5/commits?per_page=100" \
      --jq '.[] | [.sha, (.commit.message | split("\n")[0])] | @tsv' 2>/dev/null)
    exit 0 ;;
esac

[ "$#" -ge 5 ] && [ "$#" -le 6 ] || exit 0
state=$1 task=$2 source=$3 key=$4 fact=$5 correction=${6:-}
case "$source" in nm-finding|ci-fix|blocker|captain-override|learned) ;; *) exit 0 ;; esac
case "$task" in ''|.*|*[!A-Za-z0-9._-]*) exit 0 ;; esac
[ -d "$state" ] || exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
max=${FM_AUTO_LEARN_MAX_CHARS:-400}
case "$max" in ''|*[!0-9]*) max=400 ;; esac

bound() {  # <text>
  local t
  t=$(printf '%s' "$1" | tr '\n\t\r' '   ' | tr -s ' ')
  t=${t# }; t=${t% }
  [ "${#t}" -le "$max" ] || t="${t:0:$max}..."
  printf '%s' "$t"
}

fact=$(bound "$fact")
[ -n "$fact" ] || exit 0
correction=$(bound "$correction")
hash=$(printf '%s\0%s' "$source" "$key" | shasum -a 1 2>/dev/null | cut -c1-12)
[ -n "$hash" ] || exit 0
slug="auto-$source-$hash"

args=(--task "$task")
project=''
[ ! -f "$state/$task.meta" ] || project=$(sed -n 's/^project=//p' "$state/$task.meta" 2>/dev/null | tail -n 1)
project=${project%/}
[ -z "$project" ] || args+=(--project "${project##*/}")

body="$fact"$'\n'
[ -z "$correction" ] || body+=$'\n'"Corrected by: $correction"$'\n'
body+=$'\n'"Filed automatically ($source, task $task)."$'\n'

printf '%s' "$body" | FM_HOME="${FM_HOME:-$(dirname "$state")}" FM_STATE_OVERRIDE="$state" \
  "$SCRIPT_DIR/fm-log.sh" learn "$slug" "$fact" "${args[@]}" --auto >/dev/null 2>&1 || true
exit 0
