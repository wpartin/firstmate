#!/usr/bin/env bash
# fm-commit-msg-hook.sh - git `commit-msg` hook that strips AI attribution
# trailers from a commit message before the commit is created.
#
# This is the PREVENTION half of bin/fm-commit-trailer-check.sh, which owns the
# detection rule, the assistant name list, and the removal itself. This file is
# only the hook calling convention: git invokes a `commit-msg` hook with the
# message file as $1, and this hands that straight to the owner with --strip.
#
# It removes rather than refuses on purpose. A blocked commit sends the worker
# back to compose the message again, with the same harness instruction still
# telling it to add the trailers; removing them ends the loop in one pass and
# reports on stderr what it took out.
#
# INSTALLING IT, AND THE BOUNDARY THAT SHAPES WHERE IT CAN GO
# Firstmate must never write into a project repository, so firstmate cannot
# install this into a project clone's hooks. It is installable in two places:
#   - This repo, by firstmate, in its own checkout:
#       ln -sf ../../bin/fm-commit-msg-hook.sh .git/hooks/commit-msg
#     A worktree shares its repository configuration, so one install covers the
#     pooled task worktrees too.
#   - Any repository the captain owns, by the captain, the same way.
# See the task report for why a machine-wide `core.hooksPath` and a harness
# PreToolUse hook are the only other candidates, and what each one costs.
set -u

case "${1:-}" in
  -h|--help)
    echo "Usage: fm-commit-msg-hook.sh <commit-message-file>"
    echo "Installed as a git commit-msg hook; strips AI attribution trailers in place."
    exit 0
    ;;
esac

[ "$#" -ge 1 ] || { echo "error: fm-commit-msg-hook.sh needs the commit message file git passes as \$1" >&2; exit 2; }

# Installed as .git/hooks/commit-msg this file IS a symlink, and readlink -f is GNU-only, so follow the link chain by hand to reach its sibling.
SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || SELF_DIR=
SELF_BASE=$(basename -- "${BASH_SOURCE[0]}")
HOPS=0
while [ -n "$SELF_DIR" ] && [ -L "$SELF_DIR/$SELF_BASE" ] && [ "$HOPS" -lt 16 ]; do
  TARGET=$(readlink -- "$SELF_DIR/$SELF_BASE") || break
  case "$TARGET" in
    /*) SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "$TARGET")" 2>/dev/null && pwd -P) || break ;;
    *) SELF_DIR=$(CDPATH='' cd -- "$SELF_DIR/$(dirname -- "$TARGET")" 2>/dev/null && pwd -P) || break ;;
  esac
  SELF_BASE=$(basename -- "$TARGET")
  HOPS=$((HOPS + 1))
done

OWNER="$SELF_DIR/fm-commit-trailer-check.sh"
[ -x "$OWNER" ] || { echo "error: fm-commit-msg-hook.sh cannot find fm-commit-trailer-check.sh next to itself (looked in ${SELF_DIR:-an unresolvable directory})" >&2; exit 2; }
exec "$OWNER" --message "$1" --strip
