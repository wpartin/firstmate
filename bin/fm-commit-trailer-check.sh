#!/usr/bin/env bash
# fm-commit-trailer-check.sh - find, and optionally remove, the AI attribution
# trailers a harness adds to a commit message.
#
# AGENTS.md has said "Never add an agent name as a commit co-author" all along,
# and the trailers went in anyway, because a harness system reminder instructs
# the worker to add them on every commit. An instruction that loses to another
# instruction needs a check, not a louder instruction.
#
# THE TWO TRAILERS ARE NOT THE SAME PROBLEM, AND ARE REPORTED SEPARATELY
#   co-author   `Co-authored-by:` naming an AI assistant. The durable one: a
#               forge composes co-author trailers into the merge commit itself,
#               so it can reach the default branch even when the branch's own
#               message is discarded. This is the one that matters most.
#   session     `Claude-Session:` and any other `<Name>-Session:` URL trailer, or
#               a line carrying a session link. Whether one survives depends on
#               how the repository composes a squashed commit message, so it is
#               NOT safe to assume it disappears on its own; session trailers do
#               reach default branches in practice.
#
# Either way the conclusion is the same and is what shapes this script: once a
# trailer is on the default branch, removing it means rewriting shared history,
# which nobody is going to do.
#
# WHY THE CHECK FIRES ON A BRANCH AND NOT ON MAIN
# The branch is the only point at which either trailer can still be removed. A
# post-merge audit of the default branch can only report damage it cannot undo,
# so this runs before a branch is handed over. bin/fm-change-range-lib.sh owns
# the range contract, including why a commit list uses two dots and a diff uses
# three.
#
# Usage:
#   fm-commit-trailer-check.sh --project <dir> --base <ref> [--head <ref>]
#   fm-commit-trailer-check.sh --message <file> [--strip]
#   fm-commit-trailer-check.sh --help
#
#   --project <dir>   the project working tree whose commits to read.
#   --base <ref>      the branch this one will land on. Its own commits are not
#                     examined, only the commits this branch adds.
#   --head <ref>      the branch being examined. Defaults to HEAD.
#   --message <file>  examine one commit message file instead of a range. This
#                     is git's `commit-msg` hook calling convention, so the same
#                     owner serves both the audit and the hook.
#   --strip           with --message, REMOVE the offending trailer lines in
#                     place and exit 0, reporting on stderr what was removed.
#                     Refused with --base: removing a trailer from a commit that
#                     already exists means rewriting history, which this script
#                     will not do silently.
#
# Exit codes:
#   0  no offending trailer, or --strip removed every one it found.
#   1  at least one offending trailer is present and was left alone.
#   2  the check could not be performed: bad usage, an unresolvable ref, or an
#      unreadable message file. Never 0, because a clean exit reads as clean.
#
# WHICH CO-AUTHORS COUNT
# The name list below is this script's own and names AI coding assistants and
# bot accounts. A human co-author is untouched. It errs loud on purpose: a false
# report costs a worker one look at a trailer they meant to keep, and a false
# pass costs a permanent line on the default branch. Adding a newly encountered
# assistant is a one-line change to ASSISTANT_PATTERN.
#
# Lines beginning with `#` are ignored, and scanning stops at git's scissors
# line, because in `commit-msg` hook mode the file still carries git's own
# instructions and, under `commit --verbose`, the diff.
set -u

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-change-range-lib.sh
. "$SCRIPT_DIR/fm-change-range-lib.sh"

die() { echo "error: $*" >&2; exit 2; }

# Matched against a co-author trailer's whole value on word boundaries, so an assistant name inside an ordinary word is not a hit.
ASSISTANT_PATTERN='claude|anthropic|openai|chatgpt|gpt-[0-9]|copilot|codex|cursor|gemini|aider|grok|kimi|opencode|devin-ai'

PROJECT=
BASE=
HEAD=HEAD
MESSAGE=
STRIP=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) [ "$#" -ge 2 ] || die "--project requires a value"; PROJECT=$2; shift 2 ;;
    --project=*) PROJECT=${1#--project=}; shift ;;
    --base) [ "$#" -ge 2 ] || die "--base requires a value"; BASE=$2; shift 2 ;;
    --base=*) BASE=${1#--base=}; shift ;;
    --head) [ "$#" -ge 2 ] || die "--head requires a value"; HEAD=$2; shift 2 ;;
    --head=*) HEAD=${1#--head=}; shift ;;
    --message) [ "$#" -ge 2 ] || die "--message requires a value"; MESSAGE=$2; shift 2 ;;
    --message=*) MESSAGE=${1#--message=}; shift ;;
    --strip) STRIP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [ -n "$MESSAGE" ] && [ -n "$BASE" ]; then
  die "--message and --base are alternative modes: one message file, or one branch range"
fi
if [ -z "$MESSAGE" ] && [ -z "$BASE" ]; then
  die "nothing to examine: pass --message <file>, or --project <dir> --base <ref>"
fi
if [ "$STRIP" -eq 1 ] && [ -z "$MESSAGE" ]; then
  die "--strip applies only to --message: removing a trailer from a commit that already exists would rewrite history"
fi

# scan_message <file>: print one CLASS<TAB>LINENO<TAB>TEXT record per offending trailer in that message file.
scan_message() {
  awk -v assistant="$ASSISTANT_PATTERN" '
    # git discards everything from the scissors line down.
    /^#+ *-+ *>8 *-+/ { exit }
    /^[ \t]*#/ { next }
    {
      line = $0
      lower = tolower(line)
      if (lower ~ /^[ \t]*co-authored-by:/) {
        value = line
        sub(/^[ \t]*[Cc][Oo]-[Aa][Uu][Tt][Hh][Oo][Rr][Ee][Dd]-[Bb][Yy]:[ \t]*/, "", value)
        v = tolower(value)
        hit = 0
        if (v ~ ("(^|[^a-z0-9])(" assistant ")([^a-z0-9]|$)")) hit = 1
        if (index(v, "[bot]") > 0) hit = 1
        if (v ~ /(^|[^a-z0-9.-])bot@/) hit = 1
        if (hit) { printf "coauthor\t%d\t%s\n", NR, line }
        next
      }
      if (lower ~ /^[ \t]*[a-z][a-z0-9_-]*-session:[ \t]*https?:\/\/[^ \t]+[ \t]*$/) {
        printf "session\t%d\t%s\n", NR, line
        next
      }
      if (index(lower, "claude.ai/code/session") > 0) {
        printf "session\t%d\t%s\n", NR, line
        next
      }
    }
  ' "$1"
}

# --- one message file, the commit-msg hook path -----------------------------

if [ -n "$MESSAGE" ]; then
  [ -f "$MESSAGE" ] || die "--message file does not exist: $MESSAGE"
  FOUND=$(scan_message "$MESSAGE") || die "cannot read the message file: $MESSAGE"

  if [ -z "$FOUND" ]; then
    exit 0
  fi

  if [ "$STRIP" -eq 0 ]; then
    echo "This commit message carries AI attribution trailers that must not be committed:"
    printf '%s\n' "$FOUND" | while IFS=$'\t' read -r class lineno text; do
      printf '  line %s  (%s)  %s\n' "$lineno" "$class" "$text"
    done
    echo
    echo "FAILED: remove them before committing. A trailer that reaches the default branch can only be removed by rewriting shared history."
    exit 1
  fi

  TMP_MSG=$(mktemp "${MESSAGE%/*}/.fm-commit-msg.XXXXXX" 2>/dev/null) ||
    TMP_MSG=$(mktemp "${TMPDIR:-/tmp}/fm-commit-msg.XXXXXX") ||
    die "cannot create a temporary file to rewrite the message"

  # Drop the offending lines by number, then trim the blank lines that leaves dangling.
  LINES=$(printf '%s\n' "$FOUND" | cut -f2 | tr '\n' ',' )
  if ! awk -v drop="$LINES" '
    BEGIN { n = split(drop, a, ","); for (i = 1; i <= n; i++) if (a[i] != "") skip[a[i] + 0] = 1 }
    { if (!(NR in skip)) print }
  ' "$MESSAGE" > "$TMP_MSG"; then
    rm -f "$TMP_MSG"
    die "cannot rewrite the message file: $MESSAGE"
  fi

  if ! awk '
    { lines[NR] = $0 }
    END {
      last = NR
      while (last > 0 && lines[last] ~ /^[ \t]*$/) last--
      for (i = 1; i <= last; i++) print lines[i]
    }
  ' "$TMP_MSG" > "$TMP_MSG.trim"; then
    rm -f "$TMP_MSG" "$TMP_MSG.trim"
    die "cannot rewrite the message file: $MESSAGE"
  fi

  if ! mv "$TMP_MSG.trim" "$MESSAGE"; then
    rm -f "$TMP_MSG" "$TMP_MSG.trim"
    die "cannot replace the message file: $MESSAGE"
  fi
  rm -f "$TMP_MSG"

  echo "removed AI attribution trailers from the commit message:" >&2
  printf '%s\n' "$FOUND" | while IFS=$'\t' read -r class lineno text; do
    printf '  (%s)  %s\n' "$class" "$text" >&2
  done
  exit 0
fi

# --- a branch range, the pre-handover audit ---------------------------------

[ -n "$PROJECT" ] || die "--project <dir> is required with --base"
PROJECT=$(fm_range_resolve_project "$PROJECT") || exit 2
fm_range_verify "$PROJECT" "$BASE" "$HEAD" || exit 2

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-commit-trailer.XXXXXX") || die "cannot create a working directory"
trap 'rm -rf "$WORK"' EXIT INT TERM

SHAS=$(git -C "$PROJECT" log --format=%H "$BASE..$HEAD") ||
  die "cannot list the commits this branch adds in $PROJECT"

COAUTHOR=0
SESSION=0
REPORT=""

for sha in $SHAS; do
  git -C "$PROJECT" log -1 --format=%B "$sha" > "$WORK/msg" ||
    die "cannot read the message of $sha in $PROJECT"
  found=$(scan_message "$WORK/msg") || die "cannot scan the message of $sha"
  [ -n "$found" ] || continue

  subject=$(git -C "$PROJECT" log -1 --format=%s "$sha")
  short=$(git -C "$PROJECT" log -1 --format=%h "$sha")
  REPORT="$REPORT$short  $subject
"
  while IFS=$'\t' read -r class lineno text; do
    [ -n "$class" ] || continue
    REPORT="$REPORT$(printf '    (%s)  %s' "$class" "$text")
"
    case "$class" in
      coauthor) COAUTHOR=$((COAUTHOR + 1)) ;;
      session) SESSION=$((SESSION + 1)) ;;
    esac
  done <<EOF
$found
EOF
done

if [ "$COAUTHOR" -eq 0 ] && [ "$SESSION" -eq 0 ]; then
  exit 0
fi

printf '%s' "$REPORT"
echo
echo "FAILED: $COAUTHOR AI co-author trailer(s) and $SESSION session-link trailer(s) in the commits this branch adds."
if [ "$COAUTHOR" -gt 0 ]; then
  echo "A co-author trailer can survive the merge onto the default branch, where removing it would mean rewriting shared history."
fi
echo "Rewrite the branch's commit messages now, while the branch is still yours."
exit 1
