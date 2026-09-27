#!/usr/bin/env bash
# fm-log.sh - the captain's log: the one writer of a home's Markdown log.
#
# docs/captains-log.md owns the reader-facing contract (layout, sections, what
# each record renders as, configuration). This header owns the command surface
# and mechanics; bin/fm_log.py owns rendering.
#
# The log is a projection. It is rendered from the fleet activity ledger
# (state/fleet-ledger.jsonl, docs/fleet-ledger.md) and one bearings snapshot
# (bin/fm-bearings-snapshot.sh --json --all-decisions --fields queue); no other
# script writes it and nothing depends on firstmate remembering to update it.
# It records text whole: nothing it renders or indexes is truncated.
#
# Location (config/log, one line, per home, not inherited):
#   absent, empty, or on   <home>/data/log (the default)
#   <path>                 that folder instead (~ expands); the whole log moves there
#   off                    the log is off
#
# Usage:
#   fm-log.sh enable [<path>]      turn the log on (and the fleet ledger it needs),
#                                  create the layout and README, render once;
#                                  prints the log root. A path outside the home
#                                  prints a one-time sync warning.
#   fm-log.sh start [--wait <seconds>]
#                                  when the log is on, materialize the fleet ledger
#                                  (config/fleet-ledger) and the layout if missing,
#                                  then sync; the locked session start's one owner
#                                  of the default. Exit 3 and write nothing when off.
#   fm-log.sh disable              write `off` to config/log; the files stay
#   fm-log.sh path                 print the log root; exit 1 when off
#   fm-log.sh sync [--quiet] [--wait <seconds>]
#                                  render new ledger records from state/.log-cursor
#                                  (each task's dispatch fields kept in
#                                  state/.log-entities.json for its later records),
#                                  recompute today's board link and Open at close,
#                                  regenerate queue.md, and print today's note path.
#                                  --quiet prints nothing and never fails the caller
#                                  (exit 0). --wait bounds how long either form waits
#                                  when another sync holds the lock (default 2 seconds
#                                  with --quiet, 10 without).
#   fm-log.sh today [--wait <seconds>]
#                                  sync, then print today's note path
#   fm-log.sh add <worked|open|carried|asked> <text>
#                                  manual escape hatch: one bullet in today's note
#   fm-log.sh ticket <ID> <text>   manual dated line in tickets/<ID>.md
#   fm-log.sh learn <slug> <title> [--task ID]... [--ticket ID]... [--project NAME]...
#                                  write learnings/<slug>.md from stdin and record
#                                  learning.filed on the ledger (the day note's
#                                  Worked through link arrives at the next sync).
#                                  Each flag names the work the learning came from:
#                                  the note opens with tasks/tickets/projects/filed
#                                  frontmatter, the record carries them as `sources`,
#                                  the next sync adds a "Learned" line to each named
#                                  ticket and project note, and recall returns the
#                                  learning for any of them (and for the named tasks'
#                                  tickets and project). With no flag the note has
#                                  no frontmatter and the record no sources.
#   fm-log.sh unresolved           list [[links]] with no note behind them
#   fm-log.sh entities <text>      at intake, suggest the configured ticket ids and
#                                  the registered people (names or aliases) found
#                                  verbatim in <text>, the captain's own words;
#                                  reads only config, records nothing, works with
#                                  the log off. Firstmate decides whether to file
#                                  them with bin/fm-tasks-axi.sh add --ticket/--people.
#   fm-log.sh index [--rebuild]    bring the derived recall index up to date; sync
#                                  already does this after every render. --rebuild
#                                  recreates it from the ledger, notes, and reports.
#   fm-log.sh export --entities --json
#                                  print {version, synced, tasks:{<task-id>:
#                                  {tickets:[{id,url,last}], project:{name,last}|null,
#                                  people:[{name,last}]}}} from the index (never the
#                                  Markdown); last is the entity's newest touch date
#                                  (YYYY-MM-DD) across all tasks. Tasks with no entity
#                                  are left out. Read-only, no lock, no network; exit 1
#                                  when the index is missing or unreadable, 3 when off.
#                                  bin/fm-bearings-board.sh build is its consumer.
#   fm-log.sh recall [<terms>...] [--ticket ID] [--project NAME] [--person NAME]
#                    [--task ID] [--since YYYY-MM-DD|<N>d] [--limit N] [--json]
#                    [--for brief|captain|board|threads]
#   fm-log.sh recall --mentions <text> [--for captain] [...]
#   fm-log.sh recall --recent [--days N] [...]
#                                  look things up in the log; see Recall below
#
# Recall:
#   Entity flags are repeatable. Free terms that exactly name a configured ticket
#   (config/log-tickets) or a task's ticket field, a task id, a project
#   (data/projects.md or any logged task), or a person (config/log-people, one of
#   its aliases, or a task's people field) become entity
#   filters, printed on the `resolved:` line; common question words are dropped,
#   the remaining terms go to full-text search (stemmed, prefix matching), and a
#   term with no text hit that closely resembles one entity name resolves to it
#   by trigram similarity. A ticket matched only from a task's title or id
#   weighs half as much as one in its ticket field. Rows rank entity match, then decisions, learnings,
#   outcomes and reports, then other timeline lines, each weighted by recency
#   (60-day half-life) and text relevance. Open items for the matched tasks
#   (all of them with --recent) always print.
#   Output is TOON (--json gives the same pack as JSON): query, resolved,
#   entities, timeline, decisions (with the captain's recorded words), learnings,
#   open, and `more:` counting what the bound left out. The default bound is 40
#   lines and about 2.5 KB; --limit N raises the line bound and scales the byte
#   bound with it. Every row is dated and cites `<note path>#<anchor>` relative to
#   the log root (scout reports cite data/<id>/report.md). --for captain keeps one
#   cite per group; --for brief drops every path and private text (inbox notes,
#   people notes) and never fails its caller: any error prints nothing and exits
#   0. --for threads (with --recent) is the session-start RECENT THREADS view:
#   open captain decisions from before today, then the 5 most recently touched
#   tickets and projects, within --limit lines and 900 bytes; like brief it never
#   fails, and it prints nothing when the index is stale or empty.
#   --mentions <text> takes no terms: it scans the text for exact mentions only
#   (a configured ticket id as a whole word, a logged task id as a whole word,
#   a config/log-people name or alias verbatim), makes them entity filters, and
#   runs no full-text or fuzzy match. Like brief it never fails its caller and
#   prints nothing when the text names none or nothing matches;
#   bin/fm-log-prompt-hook.sh is its consumer.
#   --for board is the default shape. --recent covers the last --days (7).
#   recall reads the index without any lock and makes no network call. When the
#   last index update failed (state/.log-index-stale) it still answers, with a
#   `stale:` line. A missing index is reported with the command that builds it.
#
# Index (state/.log-index.db, SQLite FTS5 in WAL mode, disposable):
#   Built from the fleet ledger through its own byte cursor, the log's Markdown
#   notes (hand-written and fm:manual lines; lines owned by a ledger anchor come
#   from the ledger instead), learning notes (linked to their sources), the first paragraph of each
#   data/<id>/report.md, and the entity registry, re-reading a file only when its
#   mtime or size changes. config/log-redact applies before anything is indexed,
#   and a change to log-tickets, log-people, or log-redact rebuilds it. A failed
#   update during sync touches state/.log-index-stale; a good one removes it.
#
# Safety:
#   - A log root already owned by another home (.fm-log-owner names a different
#     home) is refused, so two homes never interleave one folder.
#   - An unreachable root (a missing parent, an unwritable or evicted cloud
#     folder) stops safely: state/.log-pending is touched, the cursor stays put,
#     and the next sync replays from the ledger, which is the source of truth.
#   - A snapshot failure keeps the last queue.md and marks it stale.
#   - Only sync, start, enable, add, ticket, learn, and index write, always under
#     state/.log.lock, and never delete anything in the log.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE, FM_CONFIG_OVERRIDE
# resolve the home as the other bin/ scripts do. FM_LOG_TODAY (YYYY-MM-DD)
# stands in for the clock's date in tests; FM_LOG_SNAPSHOT_FILE reads a fixture
# snapshot instead of running bin/fm-bearings-snapshot.sh.
#
# Exit status: 0 success, 1 failure, 2 usage, 3 the log is off, 4 the location
# is unreachable or owned by another home.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
LEDGER="$STATE/fleet-ledger.jsonl"
CURSOR="$STATE/.log-cursor"
PENDING="$STATE/.log-pending"
LOCK="$STATE/.log.lock"
PY="$SCRIPT_DIR/fm_log.py"
INDEX_DB="$STATE/.log-index.db"
INDEX_STALE="$STATE/.log-index-stale"

die() { printf 'fm-log: %s\n' "$*" >&2; exit "${2:-1}"; }

usage() {
  sed -n '/^# Usage:/,/^# Recall:/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
}

# Print the configured log root, or return 3 when the log is off.
log_root() {
  local value=''
  [ ! -f "$CONFIG/log" ] || IFS= read -r value < "$CONFIG/log" || true
  value=${value%%[[:space:]]}
  value=${value##[[:space:]]}
  # shellcheck disable=SC2088 # Matching a literal leading tilde, not expanding one.
  case "$value" in
    off) return 3 ;;
    ''|on) printf '%s/log\n' "$DATA" ;;
    '~'|'~/'*) printf '%s%s\n' "$HOME" "${value#\~}" ;;
    /*) printf '%s\n' "$value" ;;
    *) printf '%s/%s\n' "$FM_HOME" "$value" ;;
  esac
}

home_id() { (cd "$FM_HOME" 2>/dev/null && pwd -P) || printf '%s\n' "$FM_HOME"; }

# Make sure the root exists, is writable, and belongs to this home.
claim_root() {  # <root>
  local root=$1 owner me
  if ! mkdir -p "$root" 2>/dev/null || [ ! -w "$root" ]; then
    : > "$PENDING" 2>/dev/null || true
    die "the log location $root is unreachable; records stay on the ledger and replay at the next sync" 4
  fi
  me=$(home_id)
  if [ -f "$root/.fm-log-owner" ]; then
    owner=$(head -n 1 "$root/.fm-log-owner" 2>/dev/null || true)
    [ "$owner" = "$me" ] \
      || die "the log location $root belongs to another firstmate home ($owner); point config/log elsewhere" 4
  else
    printf '%s\n' "$me" > "$root/.fm-log-owner" 2>/dev/null \
      || die "cannot claim the log location $root" 4
  fi
}

write_readme() {  # <root>
  local root=$1
  [ ! -e "$root/README.md" ] || return 0
  cat > "$root/README.md" <<'EOF'
# Captain's log

Firstmate keeps this log from its own records; it is safe to read in any editor or in Obsidian.

- Each day has a note at `YYYY/MM/DD/YYYY-MM-DD.md`, linked as `[[YYYY-MM-DD]]`, with the sections Carried over, Worked through, Asked and answered, and Open at close.
- `queue.md` is the work queue as it stands; edits there are overwritten.
- `tickets/`, `projects/`, `people/`, and `learnings/` hold one note each, with dated lines.
- Pasted images and files belong in `attachments/`.
- The first line of every day note opens the captain's board.

Text between `%%` marks is an anchor firstmate uses to place records; leave it in place.
EOF
}

board_target() {  # <root>
  local url=''
  if [ -f "$STATE/.log-board-url" ]; then
    IFS= read -r url < "$STATE/.log-board-url" || true
  fi
  case "$url" in
    http://*|https://*|file://*) printf '%s\n' "$url" ;;
    *) printf 'file://%s/board.html\n' "$1" ;;
  esac
}

load_lock_lib() {
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh" || die "cannot load bin/fm-wake-lib.sh"
}

today() { printf '%s\n' "${FM_LOG_TODAY:-$(date +%Y-%m-%d)}"; }

# Render the static board beside the log when the bearings board can build one.
static_board() {  # <root>
  [ -x "$SCRIPT_DIR/fm-bearings-board.sh" ] || return 0
  FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_DATA_OVERRIDE=$DATA FM_CONFIG_OVERRIDE=$CONFIG \
    "$SCRIPT_DIR/fm-bearings-board.sh" build --static --out "$1/board.html" >/dev/null 2>&1 || true
}

# Stage one bearings snapshot (or the test fixture) in a temporary file and print its path.
stage_snapshot() {
  local snap
  snap=$(mktemp "${TMPDIR:-/tmp}/fm-log-snapshot.XXXXXX") || return 1
  if [ -n "${FM_LOG_SNAPSHOT_FILE:-}" ]; then
    cp "$FM_LOG_SNAPSHOT_FILE" "$snap" 2>/dev/null || : > "$snap"
  elif ! FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_DATA_OVERRIDE=$DATA FM_CONFIG_OVERRIDE=$CONFIG \
      "$SCRIPT_DIR/fm-bearings-snapshot.sh" --json --all-decisions --fields queue > "$snap" 2>/dev/null; then
    : > "$snap"
  fi
  printf '%s\n' "$snap"
}

# Update the recall index under the held log lock; a failure leaves the stale marker.
update_index() {  # <root> <snapshot> <rebuild 0|1>
  if FM_HOME=$FM_HOME FM_DATA_OVERRIDE=$DATA python3 "$PY" index "$1" "$CONFIG" "$DATA" "$LEDGER" "$INDEX_DB" "$2" "$3" 2>/dev/null; then
    rm -f -- "$INDEX_STALE"
    return 0
  fi
  [ -e "$INDEX_STALE" ] || date '+%Y-%m-%d %H:%M' > "$INDEX_STALE" 2>/dev/null || true
  return 1
}

do_sync() {  # <quiet 0|1> <wait-seconds>
  local quiet=$1 wait=$2 root snap rc generated
  root=$(log_root) || { [ "$quiet" = 1 ] && return 0; die "the captain's log is off for this home; run fm-log.sh enable" 3; }
  mkdir -p "$STATE" 2>/dev/null || true
  if [ ! -e "$CONFIG/fleet-ledger" ]; then
    [ "$quiet" = 1 ] && return 0
    die "the captain's log needs the fleet activity ledger (config/fleet-ledger); run fm-log.sh enable"
  fi
  if [ "$quiet" = 1 ]; then
    ( claim_root "$root" ) >/dev/null 2>&1 || return 0
  else
    claim_root "$root"
  fi
  load_lock_lib
  if ! fm_lock_acquire_wait_bounded "$LOCK" "$wait"; then
    [ "$quiet" = 1 ] && return 0
    die "another log sync is running; try again shortly"
  fi
  snap=$(stage_snapshot) || { fm_lock_release "$LOCK"; die "cannot stage the snapshot"; }
  generated=$(date '+%Y-%m-%d %H:%M')
  if [ "$quiet" = 1 ]; then
    FM_HOME=$FM_HOME FM_DATA_OVERRIDE=$DATA python3 "$PY" sync "$root" "$CONFIG" "$LEDGER" "$CURSOR" "$snap" "$(board_target "$root")" "$(today)" "$generated" >/dev/null 2>&1
    rc=$?
  else
    FM_HOME=$FM_HOME FM_DATA_OVERRIDE=$DATA python3 "$PY" sync "$root" "$CONFIG" "$LEDGER" "$CURSOR" "$snap" "$(board_target "$root")" "$(today)" "$generated" 2>/dev/null
    rc=$?
  fi
  [ "$rc" -ne 0 ] || update_index "$root" "$snap" 0
  static_board "$root"
  rm -f -- "$snap"
  fm_lock_release "$LOCK"
  if [ "$rc" -ne 0 ]; then
    : > "$PENDING" 2>/dev/null || true
    [ "$quiet" = 1 ] && return 0
    die "rendering the log failed; the ledger keeps every record for the next sync"
  fi
  rm -f -- "$PENDING"
}

# Idempotently create the fleet ledger flag and the log layout for an on log.
materialize() {  # <root>
  mkdir -p "$CONFIG" "$STATE" || die "cannot create this home's config and state directories"
  [ -e "$CONFIG/fleet-ledger" ] || : > "$CONFIG/fleet-ledger"
  claim_root "$1"
  mkdir -p "$1/tickets" "$1/projects" "$1/people" "$1/learnings" "$1/attachments"
  write_readme "$1"
}

# Print a --wait value when it is a positive whole number of seconds; fail otherwise.
valid_wait() {  # <value>
  case "$1" in ''|*[!0-9]*|0) return 1 ;; esac
  printf '%s\n' "$1"
}

with_write_lock() {  # <command...>
  local rc
  load_lock_lib
  fm_lock_acquire_wait_bounded "$LOCK" 10 || die "another log sync is running; try again shortly"
  "$@"
  rc=$?
  fm_lock_release "$LOCK"
  return "$rc"
}

cmd=${1:-}
[ -n "$cmd" ] || usage
shift
case "$cmd" in
  enable)
    [ "$#" -le 1 ] || usage
    mkdir -p "$CONFIG" "$STATE" || die "cannot create this home's config and state directories"
    if [ "$#" -eq 1 ]; then printf '%s\n' "$1" > "$CONFIG/log"; else printf 'on\n' > "$CONFIG/log"; fi
    root=$(log_root) || die "config/log could not be resolved"
    materialize "$root"
    case "$root" in
      "$DATA"/*|"$FM_HOME"/*) ;;
      *) printf 'fm-log: the log now lives at %s, outside this home; whatever syncs that folder (for example a cloud drive) will copy every note. Keep regulated or sensitive work on the default location.\n' "$root" >&2 ;;
    esac
    do_sync 0 10 >/dev/null
    printf '%s\n' "$root"
    ;;
  start)
    wait=10
    if [ "${1:-}" = --wait ]; then [ "$#" -eq 2 ] || usage; wait=$(valid_wait "$2") || usage; shift 2; fi
    [ "$#" -eq 0 ] || usage
    root=$(log_root) || exit 3
    materialize "$root"
    do_sync 0 "$wait"
    ;;
  disable)
    [ "$#" -eq 0 ] || usage
    mkdir -p "$CONFIG" && printf 'off\n' > "$CONFIG/log"
    ;;
  path)
    [ "$#" -eq 0 ] || usage
    log_root || exit 1
    ;;
  sync|today)
    quiet=0
    wait=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --quiet) [ "$cmd" = sync ] || usage; quiet=1 ;;
        --wait) shift; wait=$(valid_wait "${1:-}") || usage ;;
        *) usage ;;
      esac
      shift
    done
    if [ -z "$wait" ]; then
      if [ "$quiet" = 1 ]; then wait=2; else wait=10; fi
    fi
    do_sync "$quiet" "$wait"
    ;;
  add)
    [ "$#" -eq 2 ] || usage
    case "$1" in worked|open|carried|asked) ;; *) usage ;; esac
    root=$(log_root) || die "the captain's log is off for this home" 3
    claim_root "$root"
    with_write_lock python3 "$PY" add "$root" "$CONFIG" "$(board_target "$root")" "$(today)" "$1" "$2"
    ;;
  ticket)
    [ "$#" -eq 2 ] && [ -n "$1" ] || usage
    root=$(log_root) || die "the captain's log is off for this home" 3
    claim_root "$root"
    with_write_lock python3 "$PY" ticket "$root" "$CONFIG" "$1" "$2"
    ;;
  learn)
    [ "$#" -ge 2 ] || usage
    slug=$1 title=$2
    shift 2
    case "$slug" in ''|.*|*[!A-Za-z0-9._-]*) die "learning slug must use A-Za-z0-9._-" 2 ;; esac
    [ -n "$title" ] || usage
    tasks=() tickets=() projects=()
    while [ "$#" -gt 0 ]; do
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      case "$1" in
        --task) case "$2" in .*|*[!A-Za-z0-9._-]*) die "task id must use A-Za-z0-9._-" 2 ;; esac; tasks+=("$2") ;;
        --ticket) tickets+=("$2") ;;
        --project) projects+=("$2") ;;
        *) usage ;;
      esac
      shift 2
    done
    sources=''
    if [ "$((${#tasks[@]} + ${#tickets[@]} + ${#projects[@]}))" -gt 0 ]; then
      sources=$(jq -cn --args '[$ARGS.positional[] | capture("^(?<k>[a-z]+)=(?<v>.*)$"; "s")] as $a
        | def part($k): [$a[] | select(.k == $k) | .v] | unique;
        {tasks: part("tasks"), tickets: part("tickets"), projects: part("projects")}' \
        ${tasks[@]+"${tasks[@]/#/tasks=}"} ${tickets[@]+"${tickets[@]/#/tickets=}"} \
        ${projects[@]+"${projects[@]/#/projects=}"}) || die "cannot encode the learning's sources"
    fi
    root=$(log_root) || die "the captain's log is off for this home" 3
    claim_root "$root"
    with_write_lock python3 "$PY" learn "$root" "$CONFIG" "$slug" "$title" "$sources" "$(today)" || exit 1
    [ ! -e "$CONFIG/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG \
      "$SCRIPT_DIR/fm-fleet-ledger.sh" learning "$slug" "$title" ${sources:+"$sources"} >/dev/null 2>&1 || true
    ;;
  unresolved)
    [ "$#" -eq 0 ] || usage
    root=$(log_root) || die "the captain's log is off for this home" 3
    python3 "$PY" unresolved "$root"
    ;;
  index)
    rebuild=0
    case "${1:-}" in --rebuild) rebuild=1; shift ;; esac
    [ "$#" -eq 0 ] || usage
    root=$(log_root) || exit 3
    mkdir -p "$STATE" || die "cannot create this home's state directory"
    load_lock_lib
    fm_lock_acquire_wait_bounded "$LOCK" 10 || die "another log sync is running; try again shortly"
    snap=$(stage_snapshot) || { fm_lock_release "$LOCK"; die "cannot stage the snapshot"; }
    update_index "$root" "$snap" "$rebuild"
    rc=$?
    rm -f -- "$snap"
    fm_lock_release "$LOCK"
    [ "$rc" -eq 0 ] || die "updating the recall index failed; state/.log-index-stale marks it"
    ;;
  entities)
    [ "$#" -eq 1 ] || usage
    exec python3 "$PY" entities "$CONFIG" "$1"
    ;;
  export)
    [ "$#" -eq 2 ] && [ "$1" = --entities ] && [ "$2" = --json ] || usage
    log_root >/dev/null || exit 3
    exec python3 "$PY" export "$CONFIG" "$INDEX_DB"
    ;;
  recall)
    root=$(log_root) || exit 3
    exec python3 "$PY" recall "$root" "$CONFIG" "$INDEX_DB" "$INDEX_STALE" "$(today)" "$@"
    ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
