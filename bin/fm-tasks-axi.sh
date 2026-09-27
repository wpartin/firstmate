#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Arguments reach tasks-axi as given, apart from one
# rewrite that keeps file arguments meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# Structured tracking fields (add/create only; tasks-axi itself never sees them):
#   --ticket <ID>     repeatable; written as one `ticket: ID, ID` body line
#   --people <name>   repeatable; written as one `people: Name, Name` body line
# The lines are appended after any --body or --body-file text and are passed on
# as one --body. bin/fm-fleet-snapshot.sh owns reading them back, and
# docs/captains-log.md owns what they mean for the log. A value that is empty or
# carries a comma or newline is refused, since either would split the field.
# After a successful add (not --json), a `RELATED:` recall pack follows when a
# --ticket or --people value or a ticket, person, or project named in the title
# has history in the captain's log; nothing prints otherwise or when it is off.
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration.md ("Backlog backend")
# owns that rationale.
#
# Addressing is bin/fm-backlog-transition-lib.sh's fm_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so the no-command
# dashboard works too. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/ (FM_HOME unset keeps the single-home layout unchanged).
#
# Refusals (exit 2, nothing run):
#   - tasks-axi missing from PATH;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - `add` (or its `create` alias) with --start, so neither spelling places a
#     row In flight without the dispatch artifacts bin/fm-spawn.sh creates -
#     the task record, status file, and inbox that go with the row - which such
#     a row would lack, counting as live work nobody is doing that nothing
#     later would notice (`start <id>` stays a documented direct transition);
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file.
# Otherwise the exit status is tasks-axi's own.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
TICKETS=()
PEOPLE=()
BODY=
BODY_SET=0
path_value_next=0
field_next=
is_add=0
TITLE=
JSON_OUT=0
add_value_next=0
case "${1:-}" in add|create) is_add=1 ;; esac

field_value() {  # <flag> <value>
  case "$1" in
    --ticket|--people)
      case "$2" in
        ''|*,*|*$'\n'*) fail "$1 takes one non-empty value without commas or newlines; repeat the flag for more" ;;
      esac
      if [ "$1" = --ticket ]; then TICKETS+=("$2"); else PEOPLE+=("$2"); fi
      ;;
    --body) BODY=$2; BODY_SET=1 ;;
    --body-file) BODY=$(cat -- "$(absolute_from_caller "$2")") || fail "cannot read --body-file $2"; BODY_SET=1 ;;
  esac
}

for arg in "$@"; do
  if [ -n "$field_next" ]; then
    field_value "$field_next" "$arg"
    field_next=
    continue
  fi
  if [ "$is_add" = 1 ]; then
    case "$arg" in
      --ticket|--people|--body|--body-file) field_next=$arg; continue ;;
      --ticket=*|--people=*|--body=*|--body-file=*) field_value "${arg%%=*}" "${arg#*=}"; continue ;;
    esac
  fi
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --start)
      case "${1:-}" in
        add|create)
          fail "add --start would place a row In flight with no dispatch record; add it Queued and let bin/fm-spawn.sh start it"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    *)
      ARGS+=("$arg")
      if [ "$is_add" = 1 ]; then
        if [ "$add_value_next" = 1 ]; then add_value_next=0
        else
          case "$arg" in
            --json) JSON_OUT=1 ;;
            --kind|--repo|--blocked-by|--pr|--report|--priority|--prefix) add_value_next=1 ;;
            -*|add|create) ;;
            *) TITLE=$arg ;;
          esac
        fi
      fi
      ;;
  esac
done

[ -z "$field_next" ] || fail "$field_next needs a value"
if [ "$is_add" = 1 ]; then
  join_list() { local IFS=,; printf '%s' "$*" | sed 's/,/, /g'; }
  [ "${#TICKETS[@]}" -eq 0 ] || BODY="${BODY:+$BODY$'\n'}ticket: $(join_list "${TICKETS[@]}")"
  [ "${#PEOPLE[@]}" -eq 0 ] || BODY="${BODY:+$BODY$'\n'}people: $(join_list "${PEOPLE[@]}")"
  [ "$BODY_SET" = 0 ] && [ -z "$BODY" ] || ARGS+=(--body "$BODY")
fi

# RELATED: after a successful add, recall the item's tickets, people, and the
# entities its title names (docs/captains-log.md "Recall"); silent when nothing
# resolves, the log is off, or recall fails, and never changes the exit status.
related_recall() {
  local log="$SCRIPT_DIR/fm-log.sh" flags=() resolved line kind name pack
  local t p words
  for t in ${TICKETS[@]+"${TICKETS[@]}"}; do flags+=(--ticket "$t"); done
  for p in ${PEOPLE[@]+"${PEOPLE[@]}"}; do flags+=(--person "$p"); done
  if [ -n "$TITLE" ]; then
    read -ra words <<< "$TITLE"
    resolved=$("$log" recall "${words[@]}" --for brief --json 2>/dev/null \
      | jq -r '.resolved[]? | select(.kind != "task" and (.via == "exact" or .via == "pattern")) | .kind + "\t" + .name' 2>/dev/null) || resolved=
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      kind=${line%%$'\t'*}; name=${line#*$'\t'}
      flags+=("--$kind" "$name")
    done <<< "$resolved"
  fi
  [ "${#flags[@]}" -gt 0 ] || return 0
  pack=$("$log" recall --for captain --limit 20 "${flags[@]}" 2>/dev/null) || return 0
  case "$pack" in ''|*"found: nothing in the log"*) return 0 ;; esac
  printf 'RELATED:\n%s\n' "$pack"
}

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"
[ "$is_add" = 1 ] && [ "$JSON_OUT" = 0 ] || exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
tasks-axi ${ARGS[@]+"${ARGS[@]}"} || exit $?
related_recall
