#!/usr/bin/env bash
# fm-change-range-lib.sh - the single owner of "which change is being measured"
# for firstmate's pre-handover branch checks.
#
# bin/fm-comment-length-check.sh and bin/fm-commit-trailer-check.sh both measure
# one branch against the branch it will land on, and a generated ship brief
# prints both commands together. They must agree exactly on what that range
# means: a disagreement between the two is indistinguishable, to the worker
# reading them, from a real difference in the branch.
#
# THE TWO RANGES, AND WHY THEY ARE NOT THE SAME SPELLING
#   <base>...<head>  three dots, for a DIFF. Everything head added since the two
#                    branches parted, which is the file diff a pull request
#                    shows. A line the base branch changed after the fork is
#                    correctly not counted as this branch's work.
#   <base>..<head>   two dots, for a COMMIT LIST. The commits reachable from
#                    head and not from base, which is exactly this branch's own
#                    commits. Three dots here would be the symmetric difference
#                    and would drag the base branch's own commits into the
#                    report.
#
# WHY THESE CHECKS MEASURE A BRANCH RATHER THAN AUDITING MAIN
# Both checks exist to catch something while it can still be fixed cheaply. A
# comment collapsed on the branch costs nothing; the same collapse after review
# costs a force-push on an open pull request. A commit trailer is worse: GitHub's
# forge composes co-author trailers into a squashed merge commit itself, and a
# session trailer can survive too, so once a branch lands either one may sit on
# the default branch where removing it would mean rewriting shared history. The branch is the last point
# at which either is repairable, so that is where these checks fire.
#
# CALLING CONTRACT
# Source this file, then:
#   PROJECT=$(fm_range_resolve_project "<dir>") || exit 2
#   fm_range_verify "$PROJECT" "<base>" "<head>" || exit 2
#
# Both print their own diagnostic and return 1; neither exits the caller. The
# `|| exit 2` is the caller's, and it is not optional: fm_range_resolve_project
# is called in a command substitution, where an exit would end only the
# subshell and leave the caller running with an empty project path.
#
# Exit status 2 is the shared "could not check" code. Neither check may exit 0
# on an unresolvable ref, because a clean exit is read as a clean branch.

# fm_range_resolve_project <dir>: echo a git working tree's resolved absolute path, or print a diagnostic and return 1.
fm_range_resolve_project() {
  local dir=${1:-} resolved
  if [ -z "$dir" ]; then
    echo "error: --project <dir> is required" >&2
    return 1
  fi
  if [ ! -d "$dir" ]; then
    echo "error: --project is not a directory: $dir" >&2
    return 1
  fi
  resolved=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || {
    echo "error: --project cannot be resolved: $dir" >&2
    return 1
  }
  if ! git -C "$resolved" rev-parse --git-dir >/dev/null 2>&1; then
    echo "error: --project is not a git working tree: $resolved" >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}

# fm_range_verify <project> <base> <head>: both refs must name a commit there and share history, or print a diagnostic and return 1.
fm_range_verify() {
  local project=$1 base=$2 head=$3
  if ! git -C "$project" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    echo "error: base ref does not resolve in $project: $base" >&2
    return 1
  fi
  if ! git -C "$project" rev-parse --verify --quiet "$head^{commit}" >/dev/null; then
    echo "error: head ref does not resolve in $project: $head" >&2
    return 1
  fi
  if ! git -C "$project" merge-base "$base" "$head" >/dev/null 2>&1; then
    echo "error: base and head share no history in $project: $base and $head" >&2
    return 1
  fi
  return 0
}
