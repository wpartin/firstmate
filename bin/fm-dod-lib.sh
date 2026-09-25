#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" block, the
# mode-independent working rules that follow it, and the named-head reachability
# gate that accepts a ship `done:` claim.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# The working rules are emitted by fm_dod_block itself rather than by a second
# call each caller must remember, because a rule a caller can forget to render
# is the same hole in a new place. They are mode-independent: a comment and a
# commit message cost the same whichever way the branch is delivered.
# bin/fm-comment-length-check.sh owns the comment rule's language scope and is
# asked for it here, so the brief never states a list that can drift from what
# the check actually measures.
# fm_dod_block <no-mistakes|direct-PR|local-only> <task-id> [branch] [<forge>] [<publish>]
# prints the block on stdout with no trailing blank line. The caller validates the
# mode; an unknown mode is refused rather than silently rendered as the pipeline
# contract.
# Review-then-hold is the contract in every mode: the worker runs the no-mistakes
# pipeline as a review pass with `--skip push,pr,ci`, recovers the pipeline's fix
# commits into its branch (branch_sync.next_action / recover_custody /
# `axi sync --recover`), iterates to a clean pass, and then either holds or
# publishes. no-mistakes starts that pass on firstmate's instruction after its
# handoff `done:`; direct-PR and local-only start it themselves once committed.
# <publish> is on|off, defaults to off, and is this task's publish authorization.
# Off, the worker reports `done: reviewed, ready in branch <branch>` and stops
# without pushing; a later firstmate steer can grant publishing for that task,
# and the block tells the worker how to proceed on it. On, the worker publishes
# right after the clean pass: no-mistakes through a second run that skips the
# already-run review steps so the pipeline's push, pr, and ci steps publish, and
# direct-PR by pushing and opening a non-draft PR itself; a forge=gerrit task
# publishes one squashed change instead. Either then gives the existing ready
# report, so merge monitoring arms as before. local-only never publishes, so
# fm_publish_valid_for_mode refuses on for it, and it keeps the guarded local
# landing. A relaunch reads the brief again, so a steer-granted authorization
# must be steered again after one.
# The optional third argument is the task's full ship-branch name (a project's
# registered prefix may replace the legacy `fm/` one); it defaults to `fm/<task-id>`
# and is the immutable task branch rendered in every delivery contract.
# Callers of the gate are bin/fm-crew-state.sh (current-state done),
# bin/fm-pr-check.sh (PR registration), and bin/fm-inactive-reconcile.sh
# (secondmate ledger-first publish of a child done). A ship `done:` is not
# accepted while the named head exists only in the worker's disposable copy.
# The check tests that head, not whether some branch moved. In no-mistakes
# mode the pre-validation `done: {summary}` is the pipeline handoff and is
# not gated; only the later CI-ready `done: PR <url> checks green` is, or on a
# Gerrit project the later `done: PR <change url> published for review`, or the
# held `done: reviewed, ready in branch <branch>`. The held report, in any mode,
# is accepted as done-and-held when fm_dod_nm_custody_returned shows the copy
# holds its passed run's result and the named head is on a branch of the
# project's local repository, which survives the disposable copy until cleanup;
# it needs no remote. The
# named head is the worker copy's HEAD, except that a done naming the task's
# recorded pr= passes when the forge holds that head: a forge-reported
# pr_head= in no-mistakes mode, or a recorded merge
# (state/<id>.pr-poll-merge-notified). A push to Gerrit's refs/for/ leaves no
# ref a fetch can see, so a done naming a Gerrit change skips the remote-tracking
# reachability test entirely: it passes when that change is already the task's
# recorded pr=, which bin/fm-pr-check.sh writes only after this gate accepted it
# at arming, and otherwise only when a live read shows the change's current
# patch set carrying the worker copy's HEAD tree. A published-for-review report
# whose URL is not a canonical Gerrit change is refused outright. A squash is a new commit on the
# server's base, so the tree rather than the commit is what names the published
# content. In no-mistakes mode that live read is preceded by
# fm_dod_nm_custody_returned: a copy that publishes before recovering the
# pipeline's fix commits agrees with its own unfixed patch set, so the copy must
# also hold the result of a passed run. These live reads are the one check at the ready
# decision; a later rebase or patch set on the server does not revoke an armed
# task's done. Teardown's landed-work test remains the complete discard gate.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against; a forge=gerrit block
# appends " forge=gerrit shape=squash" to that line. The "Ship branch: <branch>"
# and "Publish authorization: <on|off>" lines under it are machine-readable the
# same way: bin/fm-spawn.sh refuses a ship whose spawn-selected branch or
# explicit --publish disagrees with them.
# forge is none|gerrit and defaults to none; bin/fm-project-mode.sh's header owns
# what the registry binding means, and this file owns what gerrit changes for a
# WORKER (docs/gerrit-forge-integration.md is the design). A forge composes with
# the two modes that publish and is refused on local-only, which publishes
# nothing. On gerrit an authorized worker publishes one squashed change with
# `gerrit-axi publish --squash` instead of opening a pull request, after the same
# review pass, because a passed run whose fixes stayed in the gate looks exactly
# like one whose fixes arrived and publishing it ships the unfixed code. Either
# mode's ready report is `done: PR <change url> published for review`, preceded
# by a `note:` line listing each pipeline finding and its fix, because the
# squash's description never shows the fix commits. A stack of
# changes is refused until it can be watched by its membership pinned when its
# watch is armed, because the merge poll watches one change. No contract here
# lets a worker submit, vote on, or abandon a change.
# The two PR-based blocks require a non-draft pull request before the done
# report, read back from the forge; a lane that deliberately holds a draft
# declares a paused wait instead. bin/fm-pr-check.sh refuses to arm merge
# monitoring on a draft through the same reading bin/fm-pr-merge.sh uses.
# This file is the one owner of the no-mistakes `--intent` contract: only the
# brief's `## Captain's intent` subsection plus later captain words, never
# `## Firstmate spec` and never the worker's own tradeoffs.
# Author the subsection body and later relays as the actual words, without
# adding speaker labels or direct address: the heading supplies provenance and
# is not part of --intent. A legacy mixed Task instead marks each captain line
# with `[captain] `; the selector returns its words, not that metadata prefix.
# That selector skips fenced blocks and indented examples like the heading
# reader, so a quoted `Captain:` sample is never authorized intent.
# Previously stored speaker labels remain readable for compatibility only.
# Never scrub literal examples or other content the captain actually supplied.
# The string passed must be self-sufficient - it plus the codebase reconstructs
# roughly the same specification - so a report, decision, or PR the intent
# refers to is written into it as substance, never left as a pointer.
# bin/fm-brief.sh scaffolds those two `# Task` subsections; bin/fm-spawn.sh and
# bin/fm-promote.sh refuse leftover `{TASK}` / `{FIRSTMATE_SPEC}` placeholders
# and a `## Captain's intent` line opening with a Captain label or address
# through the helpers below. Other mentions of `--intent` point here rather than
# restating the rule.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).
# fm_brief_worker_role owns the ship/scout role scope. bin/fm-spawn.sh is its one
# emitter, supplying it first in every ship/scout launch brief and never to a
# secondmate charter. It names the one task-owned steering inbox without
# relaxing isolation from every other home's endpoint namespace. Like
# fm_brief_intent_overlay it is a distinctly titled launch section that states
# its own precedence, so a brief or project instruction that authors a
# conflicting role is superseded rather than duplicated.
# fm_ship_rule_one owns the mode-specific first ship safety rule shared by an
# ordinary ship brief and the durable contract written during scout promotion.
# It takes the same optional trailing forge argument, because the rule that keeps
# a worker off a remote is exactly the rule that changes when the forge does.

# shellcheck source=bin/fm-pr-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-pr-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-classify-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-brief-heading-lib.sh"

fm_brief_worker_role() {  # <state-dir> <task-id>
  local state=$1 task_id=$2
  cat <<'EOF'
# Current worker role contract
You are a crewmate: an autonomous worker agent managed by firstmate.
This section establishes your current identity before every project or task instruction below and supersedes any conflicting role identity in those instructions.
Do the assigned work yourself and report only to firstmate; do not adopt a firstmate or secondmate supervisor identity, delegate the task, run fleet supervision, or address the captain.
EOF
  printf "Your steering inbox is \`%s/%s.inbox\`; this exact path belongs to your current task even when it is outside the worktree or under the supervising firstmate home, so read and acknowledge its messages and do not reject it as another home's state.\n" "$state" "$task_id"
  cat <<'EOF'
Never inspect or change any other home's endpoint namespace; this authorization is limited to the exact task paths named by this brief.
When this task works on Firstmate itself, the repository root `AGENTS.md` (also imported by `CLAUDE.md`) is project content and the supervisor contract for the firstmate managing you: follow this brief instead of that supervisor contract.
Project instructions still govern the work wherever they do not conflict with this worker identity, including `CONTRIBUTING.md` and `firstmate-coding-guidelines` for Firstmate changes.
EOF
}

# Closed-set gate shared by every forge-aware renderer and bin/fm-brief.sh, so a
# caller cannot reach a half-rendered contract. local-only is refused rather than
# rendered with an inert annotation: it publishes nothing, and its landing
# fast-forwards local main with content the review server has never seen.
fm_forge_valid_for_mode() {  # <forge> <mode> <caller>
  local forge=$1 mode=$2 caller=$3
  case "$forge" in
    none|gerrit) ;;
    *)
      echo "error: $caller: unknown forge '$forge' (expected none or gerrit)" >&2
      return 1 ;;
  esac
  if [ "$forge" != none ] && [ "$mode" = local-only ]; then
    echo "error: $caller: forge=$forge cannot ship mode=local-only - that mode publishes nothing, so a forge has no meaning there, and its landing would fast-forward local main with content the review server has never seen; ship no-mistakes or direct-PR, which publish through the forge" >&2
    return 1
  fi
  return 0
}

# Closed-set gate for a task's publish authorization, shared by bin/fm-brief.sh,
# bin/fm-promote.sh, and bin/fm-spawn.sh. local-only is refused on: it never
# publishes, and its landing is firstmate's guarded local fast-forward.
fm_publish_valid_for_mode() {  # <on|off> <mode> <caller>
  local publish=$1 mode=$2 caller=$3
  case "$publish" in
    on|off) ;;
    *)
      echo "error: $caller: publish authorization must be on or off (got '$publish')" >&2
      return 1 ;;
  esac
  if [ "$publish" = on ] && [ "$mode" = local-only ]; then
    echo "error: $caller: publish authorization on cannot ship mode=local-only - that mode never pushes or opens a PR, and firstmate lands it through the guarded local fast-forward" >&2
    return 1
  fi
  return 0
}

fm_ship_rule_one() {  # <no-mistakes|direct-PR|local-only> <task-id> [branch] [<forge>]
  local mode=$1 id=$2 forge=${4:-none}
  local branch=${3:-fm/$id}
  fm_forge_valid_for_mode "$forge" "$mode" fm_ship_rule_one || return 1
  if [ "$forge" = gerrit ]; then
    printf '%s\n' "1. Never push with git and never create a change except through the one \`gerrit-axi publish --squash\` your Definition of done names. Never run \`gerrit-axi submit\`, never vote or review a change by any path, including \`gerrit review\` or a label option on a push, and never abandon one: a human reviewer approves and submits it on the server."
    return 0
  fi
  case "$mode" in
    direct-PR)
      printf '%s\n' "1. Never push to the default branch (push only your \`$branch\` branch). Never merge a PR."
      ;;
    local-only)
      printf '%s\n' "1. Never push to any remote and never open a PR. Work only on your \`$branch\` branch; firstmate handles the merge into local \`main\`."
      ;;
    no-mistakes)
      printf '%s\n' '1. Never push to the default branch. Never merge a PR.'
      ;;
    *)
      echo "error: fm_ship_rule_one: unknown delivery mode '$mode'" >&2
      return 1
      ;;
  esac
}

# Return 0 when a Task subsection still consists only of its scaffold
# placeholder. A missing file and legacy briefs carry no such placeholders.
fm_brief_task_placeholders_present() {  # <file>
  local file=$1 intent spec
  [ -f "$file" ] || return 1
  intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
  spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
  [ "$(printf '%s' "$intent" | tr -d '[:space:]')" = '{TASK}' ] && return 0
  [ "$(printf '%s' "$spec" | tr -d '[:space:]')" = '{FIRSTMATE_SPEC}' ] && return 0
  return 1
}

# Print the words of every provenance-marked line in a legacy `# Task` body.
# The marker is read the way bin/fm-brief-heading-lib.sh reads a heading: a
# line inside a ``` or ~~~ fenced block, or indented four spaces or a tab as an
# indented example, is never a marked line, so a fenced `Captain:` sample cannot
# pass the provenance gate as the ship contract's intent (issue 3608).
fm_brief_marked_captain_words() {  # <task-body>
  printf '%s\n' "$1" | awk '
    {
      scan = $0
      spaces = 0
      while (spaces < 3 && substr(scan, 1, 1) == " ") {
        scan = substr(scan, 2)
        spaces++
      }
      marker = substr(scan, 1, 1)
      marker_len = 0
      if (marker == "`" || marker == "~") {
        while (substr(scan, marker_len + 1, 1) == marker) marker_len++
      }
      if (marker_len >= 3) {
        if (!fenced) {
          fenced = 1
          fence_marker = marker
          fence_len = marker_len
        } else if (marker == fence_marker && marker_len >= fence_len && substr(scan, marker_len + 1) ~ /^[[:space:]]*$/) {
          fenced = 0
        }
        next
      }
      if (fenced || substr(scan, 1, 1) ~ /^[ \t]$/) next
      if (match(scan, /^(\[captain\]|Captain('\''s (words|ask|intent))?:)[[:space:]]*/)) {
        words = substr(scan, RLENGTH + 1)
        if (words ~ /[^[:space:]]/) print words
      }
    }
  '
}

fm_brief_intent_overlay() {  # <captain-intent>
  cat <<'EOF'

# Current no-mistakes intent contract
This section supersedes every earlier brief instruction about constructing `--intent`, but not later clarifications actually supplied by the captain.
Use everything under `## Captain intent authorized for --intent` through the end of this brief, including any nested subheadings but excluding that heading, plus any later words the captain actually supplied as `--intent`; never include Firstmate specification or other mixed Task content.
Preserve those words without adding speaker labels or direct address.
Firstmate-authored constraints, acceptance criteria, implementation details, decisions, and tradeoffs are specification, not captain intent.
The Definition of done's rule that `--intent` must be self-sufficient still governs the string you pass: resolve any report, decision, or PR the intent below refers to into its substance rather than passing the pointer.

## Captain intent authorized for --intent
EOF
  printf '%s\n' "$1"
}

# Accept the current two-subsection contract only when both bodies have content;
# briefs predating that contract remain valid when their # Task body has content.
fm_brief_task_content_valid() {  # <file>
  local file=$1 intent spec task has_intent=0 has_spec=0
  [ -f "$file" ] && [ -r "$file" ] || return 1
  fm_brief_task_heading_present "$file" "## Captain's intent" && has_intent=1
  fm_brief_task_heading_present "$file" "## Firstmate spec" && has_spec=1
  if [ "$has_intent" -eq 1 ] || [ "$has_spec" -eq 1 ]; then
    [ "$has_intent" -eq 1 ] && [ "$has_spec" -eq 1 ] || return 1
    intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
    spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
    [ -n "$(printf '%s' "$intent" | tr -d '[:space:]')" ] || return 1
    [ -n "$(printf '%s' "$spec" | tr -d '[:space:]')" ] || return 1
    return 0
  fi
  task=$(fm_brief_heading_body "$file" "# Task")
  [ -n "$(printf '%s' "$task" | tr -d '[:space:]')" ]
}

# Print the first `## Captain's intent` body line that opens with an operator
# address spelling; fail when there is none. The body is never rewritten.
fm_brief_intent_address_line() {  # <file>
  fm_brief_task_heading_body "$1" "## Captain's intent" | awk '
    /^[[:space:]]*(Captain('\''s (words|ask|intent))?:|Captain,)/ { print; found = 1; exit }
    END { exit !found }
  '
}

# The `nm-<run>-<step>` decision key this block mandates is load-bearing beyond
# the brief itself: the watcher binds an open `needs-decision` to the run a
# crew's current state reports by matching exactly that shape
# (wedge_wait_evidence in bin/fm-watch.sh, through
# status_has_open_needs_decision in bin/fm-classify-lib.sh), which is what buys
# a lane parked at a human-owed gate the long recheck cadence instead of a
# wedge escalation. A gate escalated under any other key still reads as a
# suspected wedge.
fm_ask_user_escalation_block() {  # <data-dir> <task-id>
  local data=$1 id=$2
  cat <<EOF
   For a no-mistakes ask-user gate specifically, escalate all ask-user findings as one event plus one snapshot file, using that same shape even when the gate holds only a single ask-user finding: write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority), to \`$data/$id/nm-<run>-findings.txt\`, then report the gate with
   \`needs-decision [at=<epoch>] [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file=$data/$id/nm-<run>-findings.txt\`
   naming every ask-user finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.
EOF
}

# The forge-independent middle of the no-mistakes contract: how a worker drives
# the pipeline, what `--intent` may carry, and the two firstmate-specific rules.
# Written once for the review pass every mode runs; the pass skips the ci step,
# so the green-PR return rule is stated only where a publishing run needs it.
fm_nm_driving_block() {
  cat <<EOF
You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass \`--intent\` as only this brief's \`## Captain's intent\` subsection body, not its heading, plus any later words the captain actually said.
Preserve the actual words without adding speaker labels or direct address; the subsection heading supplies provenance outside the pipeline input.
For a legacy brief with no such subsection, include only words on lines marked \`[captain] \`, excluding that metadata prefix; never copy its mixed \`# Task\` wholesale.
If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include \`## Firstmate spec\`, later Firstmate build constraints, or your own decisions and tradeoffs.
The \`--intent\` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into \`--intent\` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich \`--intent\` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call instead of sitting in one blocking hold your harness will kill, and read its return when it finishes.
Where a harness's own command limit is not established, assume it bounds commands and use that same backgrounded shape.
Whenever a drive call returns without a gate or an outcome - its own wait elapsed, or it was killed or timed out - reattach at once by re-running \`no-mistakes axi run\` without flags, backgrounded the same way; if it refuses because no run is active, read the finished outcome from \`no-mistakes axi status\`.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.
EOF
}

# How a worker on a forge=gerrit project publishes, shared by both publishing
# modes so the one push, the Change-Id rule, and the ready report are written
# once. gerrit-axi owns the squash mechanics; this names the one call and what
# to read back from it. The squash hides the review pass's fix commits, so the
# pipeline-changes note that precedes the ready report is written here too.
fm_gerrit_publish_block() {
  cat <<EOF
Publish from this copy with \`gerrit-axi\`, never with \`git push\`:
1. Run \`git fetch origin\` so the server's branch tip is in this repository; \`gerrit-axi\` reads its base off the server and refuses when that tip is not here.
2. Run \`gerrit-axi publish --squash --json\`, adding \`--branch <b>\` only when the task names a target branch other than the server's default.
   It is one push to \`refs/for/<branch>\` that turns every commit since your branch left the server's branch into ONE change carrying the oldest commit's message, so that message is the review description: make it the one you want reviewed.
   It keeps any \`Change-Id\` a commit already carries and stamps one into the oldest commit when it has none, rewriting your local branch's messages only.
   Never edit, remove, or regenerate a \`Change-Id\`: a different one creates a different change and orphans the first one's review, while the same one adds a patch set to it.
   Never pass \`--stack\`: a stack of changes is not published from this fleet until it can be watched by its membership pinned when its watch is armed, and the watch follows exactly one change.
3. Read the record it prints: \`ok\` must be \`true\`, and the one row of its \`changes\` table is your change. Its \`url\` is the change URL; when \`url\` is null, write \`https://<host>/c/<project>/+/<change>\` from your \`origin\` remote's host and that row's \`project\` and \`change\`.
   A failure prints a typed error record instead; fix what it names and publish again, which updates the same change rather than creating another.
The squashed change carries only the oldest commit's message, so the pipeline's own fix commits never reach the reviewer's description; your report is how they reach the captain.
After publishing and immediately before your ready report, append one line \`note [at=<epoch>]: pipeline changes: {finding} - {fix it made}; {finding} - {fix it made}\` to the status file, one short clause per finding the review pass fixed, taken from the run's \`fixes\` table and the gate findings its drive calls returned (\`no-mistakes axi logs --step <step> --full\` has the detail); write \`note [at=<epoch>]: pipeline changes: none\` when it fixed nothing.
Then append \`done [at=<epoch>]: PR {change url} published for review\` to the status file and stop. You are finished.
That \`done:\` is accepted only when the change's current patch set on the server carries this copy's HEAD tree, so commit nothing after publishing; if you must change the work, commit it and publish again before reporting done.
A \`done:\` whose URL is not the canonical \`https://<host>/c/<project>/+/<number>\` change URL is refused.
There is no pull request, no \`gh-axi\` call, and no forge CI result to report: a human reviewer approves and submits the change on the server, and firstmate relays that outcome.
EOF
}

# The review pass every mode runs before its branch is called ready: the
# pipeline with its three forge-facing steps skipped, then recovery of its fix
# commits, because with push skipped nothing carries them back to the copy.
fm_review_pass_block() {  # <branch>
  local branch=$1
  cat <<EOF
## Review pass
Every change runs the no-mistakes pipeline as a review pass before it is called ready, whatever this task's delivery mode, and that pass pushes and publishes nothing.
Pass \`--skip push,pr,ci\` on every review-pass \`no-mistakes axi run\` for this task, and skip nothing else: \`review\`, \`test\`, \`document\`, and \`lint\` are the whole point of the run.
Those three are the only steps that reach a forge, and skipping them is a supported outcome, not a degraded one.

EOF
  fm_nm_driving_block
  cat <<EOF

Because \`push\` is skipped, the pipeline's fixes DO NOT arrive in your checkout: each fix round commits onto a branch inside no-mistakes' own local gate repository, and with no push nothing carries those commits back to you.
Your tree never goes dirty and nothing interrupts you, so a passed run whose fixes are still in the gate looks exactly like a passed run whose fixes you already have.
You may not report the branch ready or publish it until you have closed that gap:
1. After the run reaches its outcome, read \`branch_sync.next_action\` from \`no-mistakes axi status\`.
2. When its code is \`recover_custody\`, run the exact command that status prints - \`no-mistakes axi sync --recover\` - and confirm \`branch_sync.state\` comes back \`custody_returned\` on a clean tree. The printed command is authoritative if it differs. The \`run_pipeline\` next action status reports after recovery is not an instruction to run again: the recovered head is the one the passed run validated.
3. Confirm with \`git log\` that \`$branch\` now carries every fix commit the run made, whether or not step 2 was needed.
An unrecovered fix round is an unfinished task, never housekeeping: holding or publishing without it is how the UNFIXED code reaches review.
When the run ends failed, fix what it names on \`$branch\`, commit, and start the review pass again; iterate until its outcome is passed, passed-with-skips, or passed-with-override and step 3 holds.
That is the clean pass. Commit nothing after it; if you must change the work, run the review pass again.
The held ready report below is refused while the run still holds your branch, while its outcome is missing or not passing, or while your HEAD's tree differs from the run's result.
EOF
}

# The held stop and the authorization rule. <publish> is on only when this task
# was scaffolded with publishing pre-authorized; off holds the reviewed branch
# until a firstmate steer grants publishing for this task.
fm_publish_gate_block() {  # <branch> <on|off> <publish-noun>
  local branch=$1 publish=$2 noun=$3
  if [ "$publish" = on ]; then
    cat <<EOF

## Publish
Publishing is authorized for this task: after the clean review pass, publish from \`$branch\` as follows without waiting for a further instruction.
EOF
    return 0
  fi
  cat <<EOF

## Hold
Publishing is NOT authorized for this task: do NOT push, do NOT $noun.
After the clean review pass, append \`done [at=<epoch>]: reviewed, ready in branch $branch\` to the status file and stop.
That held \`done:\` is accepted only when the run passed with its fixes recovered and this copy's HEAD is on \`$branch\` in the project's local repository; the branch stays there until the task is cleaned up.

## Publish
Only when a firstmate message in your instruction inbox says publishing is authorized for this task, publish from the held \`$branch\` as follows; acknowledge that message, and run the review pass again first only if you changed the branch since its clean pass.
EOF
}

fm_dod_block() {  # <mode> <task-id> [branch] [<forge>] [<publish>]
  local mode=$1 id=$2 forge=${4:-none} publish=${5:-off}
  local branch=${3:-fm/$id} contract="mode=$1"
  fm_forge_valid_for_mode "$forge" "$mode" fm_dod_block || return 1
  fm_publish_valid_for_mode "$publish" "$mode" fm_dod_block || return 1
  [ "$forge" = none ] || contract="$contract forge=$forge shape=squash"
  case "$mode" in
    no-mistakes|direct-PR|local-only) ;;
    *)
      echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
  cat <<EOF
# Definition of done
Delivery contract: $contract
Ship branch: $branch
Publish authorization: $publish
EOF
  case "$mode:$forge" in
    no-mistakes:gerrit)
      printf '%s\n' "This project's review server is Gerrit: it has no pull requests and no forge CI the pipeline can watch, so once published the change is reviewed there."
      ;;
    no-mistakes:*)
      printf '%s\n' "This task ships **no-mistakes**: the review pass below validates the branch, and publishing, when authorized, runs through the pipeline's own push, pr, and ci steps."
      ;;
    direct-PR:gerrit)
      printf '%s\n' "This task ships **direct-PR** to a Gerrit review server: after the review pass, publishing, when authorized, is yours. Gerrit has no pull requests, so there is nothing to open; publishing creates the change."
      ;;
    direct-PR:*)
      printf '%s\n' "This task ships **direct-PR**: after the review pass, publishing, when authorized, is yours - you push and open the PR without a second pipeline run."
      ;;
    local-only:*)
      printf '%s\n' "This task ships **local-only**: no remote and no PR, ever. Do NOT push, do NOT open a PR, do NOT merge."
      ;;
  esac
  printf '%s\n' "The task is complete only when committed on your branch \`$branch\`."
  case "$mode" in
    no-mistakes)
      cat <<EOF
When you believe it is complete, append \`done [at=<epoch>]: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate; run it as the review pass below.
That first \`done:\` is the handoff that starts the review pass; it is not a request to push or publish.
EOF
      ;;
    *)
      printf '%s\n' "When it is implemented and committed, run the review pass below yourself; no firstmate instruction is needed to start it."
      ;;
  esac
  printf '\n'
  fm_review_pass_block "$branch"
  case "$mode:$forge" in
    local-only:*)
      cat <<EOF

## Hold
Keep your branch a clean fast-forward onto the current default branch: rebase onto an advanced \`main\` before a review pass, never after its clean pass.
After the clean review pass, append \`done [at=<epoch>]: reviewed, ready in branch $branch\` to the status file and stop.
That held \`done:\` is accepted only when the run passed with its fixes recovered and this copy's HEAD is on \`$branch\` in the project's local repository.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    *:gerrit)
      fm_publish_gate_block "$branch" "$publish" "publish a change"
      fm_gerrit_publish_block
      ;;
    direct-PR:*)
      fm_publish_gate_block "$branch" "$publish" "open a PR"
      cat <<EOF
Push \`$branch\` and open a PR with \`gh-axi\` that is ready for review, not a draft.
Before you report done, read the PR back from the forge and confirm it is not a draft (\`gh pr view <url> --json isDraft\` must print false); if it is a draft, mark it ready with \`gh-axi pr ready\`.
A draft cannot be merged, so a done report on one leaves the merge unasked.
Then append \`done [at=<epoch>]: PR {url}\` to the status file and stop.
That \`done:\` is accepted only when this copy's HEAD - your latest commit - is pushed to your PR branch; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append \`paused [at=<epoch>]: {why the draft is held}\` instead of done.
The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    no-mistakes:*)
      fm_publish_gate_block "$branch" "$publish" "open a PR"
      cat <<EOF
Start a publishing run on \`$branch\` with the same \`--intent\`, skipping only the steps the clean review pass already ran: \`no-mistakes axi run --intent "<intent>" --skip review,test,document,lint\`.
Its push, pr, and ci steps then publish the reviewed head; the pipeline owns that push, so never push from this copy.
Drive it exactly as the review pass above, including the ask-user and \`--yes\` rules, with one addition for its ci step:
Only a drive call's return reports the green PR: \`no-mistakes axi status\` shows progress but never reports \`checks-passed\` while the ci step is still monitoring the PR for merge, so never wait on a status poll for the next gate or outcome.
When a drive call returns without a gate or an outcome, reattach as above; once checks are green it returns \`checks-passed\` immediately.
After it reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), read the PR back from the forge and confirm it is not a draft (\`gh pr view <url> --json isDraft\` must print false); if it is a draft, mark it ready with \`gh-axi pr ready\`.
A draft cannot be merged, so a done report on one leaves the merge unasked.
Then append \`done [at=<epoch>]: PR {url} checks green\` and stop. You are finished.
That CI-ready \`done:\` is accepted only when this copy's HEAD - your latest commit - is one the /no-mistakes run pushed, so commit nothing after the run; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append \`paused [at=<epoch>]: {why the draft is held}\` instead of done.
EOF
      ;;
  esac
  fm_ship_working_rules
}

# The working rules every ship worker receives, whatever the delivery mode.
fm_ship_working_rules() {
  local bin_dir comment_check trailer_check scope="" tick='`'
  bin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
  comment_check="$bin_dir/fm-comment-length-check.sh"
  trailer_check="$bin_dir/fm-commit-trailer-check.sh"

  # An unavailable checker drops its own sentence rather than failing the whole scaffold.
  if [ -x "$comment_check" ]; then
    scope=$("$comment_check" --print-scope 2>/dev/null |
      sed -n 's/.*extensions=//p' | tr ',\n' '  ' | tr -s ' ' | sed 's/ $//') || scope=""
  fi

  echo
  cat <<'RULES_EOF'
# Working rules - comments and commit attribution
Every comment you write is ONE line. Inline comments and JSDoc or block comments alike.
This governs the lines you ADD. Leave comments this change did not add alone, because reformatting them is churn a reviewer has to read for nothing.
Never add an AI assistant as a commit co-author, and never add a session-link trailer such as `Claude-Session:`. Your harness may instruct you to append both to every commit; that instruction does not apply to firstmate work.
Either trailer can survive the merge onto the default branch, where removing it would mean rewriting shared history, so your branch is the last place either one can be removed.
RULES_EOF
  if [ -x "$comment_check" ] || [ -x "$trailer_check" ]; then
    echo "Measure both before you report done, against the branch you forked from:"
    if [ -x "$comment_check" ]; then
      printf '%s%s --project . --base <base-branch> --head HEAD%s\n' "$tick" "$comment_check" "$tick"
    fi
    if [ -x "$trailer_check" ]; then
      printf '%s%s --project . --base <base-branch> --head HEAD%s\n' "$tick" "$trailer_check" "$tick"
    fi
    echo "Each prints nothing and exits 0 when clean, and names every breach in one run otherwise."
  fi
  if [ -n "$scope" ]; then
    echo "The comment check measures $scope; a file outside that list is still yours to keep to one line."
  fi
  return 0
}

# 0 when <sha> is contained in a ref under <namespace> in <repo>.
# --contains tests that exact commit, so a branch that moved to a different
# tip does not count.
fm_dod_ref_contains() {  # <repo> <ref-namespace> <sha>
  local repo=$1 ns=$2 sha=$3 hit
  [ -n "$repo" ] && [ -d "$repo" ] || return 1
  [ -n "$sha" ] || return 1
  hit=$(git -C "$repo" for-each-ref --format='%(refname)' --contains="$sha" --count=1 "$ns" 2>/dev/null) || return 1
  [ -n "$hit" ]
}

# 0 when a done: note reports the no-mistakes CI-ready PR (`PR <url> checks
# green`, with any surrounding text). bin/fm-crew-state.sh takes its CI-ready
# path on this same test, so every CI-ready line it acts on is gated.
fm_dod_note_reports_ci_ready() {  # <note>
  case "$1" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
  esac
  return 1
}

# 0 when a done: note reports a change published to a Gerrit review server
# (`PR <change url> published for review`), which is the ready report of both
# publishing modes on that forge.
fm_dod_note_reports_published_change() {  # <note>
  case "$1" in
    *PR*"published for review"*) return 0 ;;
  esac
  return 1
}

# 0 when a done: note reports a reviewed branch held after its clean review
# pass (`reviewed, ready in branch <branch>`), the ready report every mode gives
# when publishing is not authorized. A legacy local-only `ready in branch` note
# without "reviewed" predates the review pass and keeps its reachability gate.
fm_dod_note_reports_held_branch() {  # <note>
  case "$1" in
    *"reviewed, ready in branch"*) return 0 ;;
  esac
  return 1
}

# 0 when this ship done: is one the named-head gate must accept or refuse.
# no-mistakes pre-validation done: is the pipeline handoff and is not gated.
# Empty mode is treated as no-mistakes, the unregistered-project default.
fm_dod_should_gate_ship_done() {  # <kind> <mode> <line>
  local note
  [ "$1" = ship ] || return 1
  [ "$(status_line_verb "$3")" = "done" ] || return 1
  note=$(status_line_note "$3")
  case "$2" in
    direct-PR|local-only) return 0 ;;
    no-mistakes|'')
      fm_dod_note_reports_ci_ready "$note" || fm_dod_note_reports_published_change "$note" \
        || fm_dod_note_reports_held_branch "$note" ;;
    *) return 1 ;;
  esac
}

# The PR/MR URL from a `done: PR <url>...` note, or empty.
fm_dod_pr_url_from_done_note() {  # <note>
  local note=$1 url
  case "$note" in
    PR\ https://*|PR\ http://*) ;;
    *) return 1 ;;
  esac
  url=${note#PR }
  url=${url%% *}
  printf '%s\n' "$url"
}

# The last recorded <key>= value in <meta>, or empty.
fm_dod_meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

# 0 when the forge's head for a PR is the head the done names. In no-mistakes
# mode the pipeline pushes it, possibly with commits the worker clone never
# fetched. A direct-PR worker pushes from its own copy, so its named head stays
# that copy's HEAD and a later unpushed commit is refused.
fm_dod_forge_head_is_named_head() {  # <mode>
  case "$1" in
    no-mistakes|'') return 0 ;;
  esac
  return 1
}

# 0 when <url> is the task's recorded pr= and the forge holds its head:
# bin/fm-pr-check.sh recorded the forge's pr_head= for it in no-mistakes mode,
# or the merge poll recorded it merged (<state>/<id>.pr-poll-merge-notified,
# bin/fm-pr-lib.sh). That head is stored outside the worker copy even when
# this clone never fetched it or fleet sync pruned its branch after a squash
# merge. A recorded Gerrit change needs neither: its pr= is written only after
# the live published-tree check accepted it.
fm_dod_recorded_pr_on_forge() {  # <state> <id> <meta> <mode> <url>
  local state=$1 id=$2 meta=$3 mode=$4 url=$5
  [ -n "$meta" ] && [ -f "$meta" ] || return 1
  [ "$(fm_dod_meta_value "$meta" pr)" = "$url" ] || return 1
  if fm_dod_forge_head_is_named_head "$mode" && [ -n "$(fm_dod_meta_value "$meta" pr_head)" ]; then
    return 0
  fi
  ( fm_pr_url_parse "$url" \
    && { [ "$FM_PR_PROVIDER" = gerrit ] \
      || fm_pr_poll_merge_already_notified "$state" "$id" \
        "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; } )
}

# 0 when <url> names a Gerrit change whose current patch set carries the tree of
# the worktree's HEAD. The revision is read live and bounded, because the server
# is the only place a refs/for/ push leaves it, and it must already be an object
# in the worktree - the publish that made it ran there - so a patch set pushed
# from elsewhere matches only once this copy holds it.
fm_dod_gerrit_change_carries_head() {  # <worktree> <url>
  local wt=$1 url=$2 revision head_tree revision_tree lib
  fm_pr_url_parse "$url" || return 1
  [ "$FM_PR_PROVIDER" = gerrit ] || return 1
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-pr-lib.sh"
  # shellcheck disable=SC2016  # The inner script expands after bash -c receives positional args.
  revision=$(fm_run_timed 10 bash -c '
    . "$1"
    fm_pr_gerrit_read_revision "$2" "$3" || exit 1
    printf "%s\n" "$FM_PR_RECORD_REVISION"
  ' _ "$lib" "$FM_PR_HOST" "$FM_PR_NUMBER" 2>/dev/null) || return 1
  fm_pr_head_valid "$revision" || return 1
  head_tree=$(git -C "$wt" rev-parse --verify --quiet 'HEAD^{tree}' 2>/dev/null) || return 1
  revision_tree=$(git -C "$wt" rev-parse --verify --quiet "$revision^{tree}" 2>/dev/null) || return 1
  [ -n "$head_tree" ] && [ "$head_tree" = "$revision_tree" ]
}

# 0 when the worker copy holds the result of its own passed no-mistakes run:
# the run's outcome is passed, passed-with-skips or passed-with-override (the
# passing set bin/fm-crew-state.sh reads), that pipeline owns no unreturned work (branch_sync.next_action.code is neither
# recover_custody nor continue_active_run) and HEAD's tree equals the tree of the
# pipeline's current head resolved in this copy. On a Gerrit project push is
# skipped, so a fix round's commits stay in the gate until custody is recovered,
# and a copy that publishes before recovering has a server patch set that agrees
# with its own unfixed HEAD - the published-tree check alone accepts it. Trees
# are compared rather than ancestry because the publish stamps a Change-Id and
# rewrites the branch's messages. An unreadable status refuses, as an unreadable
# change does. 1 when refused; stdout then holds a one-line reason.
fm_dod_nm_custody_returned() {  # <worktree>
  local wt=$1 out outcome code pipeline_head head_tree pipeline_tree
  if ! out=$(fm_nm_run_checked "$wt" 15 axi status) || ! printf '%s\n' "$out" | grep -q '^run:'; then
    printf '%s\n' "the no-mistakes run for this copy could not be read, so its fixes cannot be proven recovered"
    return 1
  fi
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
  case "$outcome" in
    passed|passed-with-skips|passed-with-override) ;;
    *)
      printf '%s\n' "the no-mistakes run for this copy has outcome ${outcome:-(none)}, not a pass, so the published work is not validated"
      return 1 ;;
  esac
  code=$(fm_nm_branch_sync_nested "$out" next_action code)
  case "$code" in
    recover_custody|continue_active_run)
      printf '%s\n' "the no-mistakes run still holds this copy's branch (next action $code), so its fixes are not recovered into the published work"
      return 1 ;;
  esac
  pipeline_head=$(fm_nm_branch_sync_nested "$out" pipeline current_head)
  [ -n "$pipeline_head" ] || pipeline_head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head_sha)")
  head_tree=$(git -C "$wt" rev-parse --verify --quiet 'HEAD^{tree}' 2>/dev/null) || head_tree=
  pipeline_tree=
  if fm_pr_head_valid "$pipeline_head"; then
    pipeline_tree=$(git -C "$wt" rev-parse --verify --quiet "$pipeline_head^{tree}" 2>/dev/null) || pipeline_tree=
  fi
  if [ -z "$head_tree" ] || [ -z "$pipeline_tree" ] || [ "$head_tree" != "$pipeline_tree" ]; then
    printf '%s\n' "this copy's HEAD does not carry the no-mistakes run's result ${pipeline_head:-(unknown head)}, so the pipeline's fixes are not in the published work"
    return 1
  fi
  return 0
}

# 0 when <sha> is reachable from a ref that survives the disposable worktree:
# any remote-tracking ref, or - for local-only - heads in the project clone.
fm_dod_named_head_reachable_outside_worktree() {  # <worktree> <project> <mode> <sha>
  local wt=$1 project=$2 mode=$3 sha=$4
  fm_dod_ref_contains "$wt" refs/remotes "$sha" && return 0
  fm_dod_ref_contains "$project" refs/remotes "$sha" && return 0
  [ "$mode" = local-only ] && fm_dod_ref_contains "$project" refs/heads "$sha"
}

# 0 when <line> is not a ship done: to gate, when it names the task's recorded
# PR whose head the forge holds, when it names a Gerrit change whose current
# patch set carries the worker copy's HEAD tree, or otherwise when its named
# head - the worker copy's HEAD - is reachable outside that disposable copy. A
# published-for-review report that names no Gerrit change is refused.
# There is no free-text SHA scan: a SHA that happens to appear in the note is
# not the named head. 1 when
# the claim is refused; stdout then holds a one-line reason and no other
# output. <state> <id> <meta> supply pr=,
# pr_head=, and the merge-notified marker; <meta> may be a captured copy
# (bin/fm-fleet-snapshot.sh), so the marker is read from <state>.
fm_dod_accept_ship_done() {  # <kind> <mode> <worktree> <project> <line> [<state> <id> <meta>]
  local kind=$1 mode=$2 wt=$3 project=$4 line=$5 state=${6:-} id=${7:-} meta=${8:-} url sha gerrit
  fm_dod_should_gate_ship_done "$kind" "$mode" "$line" || return 0
  if url=$(fm_dod_pr_url_from_done_note "$(status_line_note "$line")") \
    && fm_dod_recorded_pr_on_forge "$state" "$id" "$meta" "$mode" "$url"; then
    return 0
  fi
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf '%s\n' "named head cannot be verified: worktree missing"
    return 1
  fi
  if ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    printf '%s\n' "named head cannot be verified: worktree is not a git copy"
    return 1
  fi
  sha=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || {
    printf '%s\n' "named head could not be resolved"
    return 1
  }
  if fm_dod_note_reports_held_branch "$(status_line_note "$line")"; then
    fm_dod_nm_custody_returned "$wt" || return 1
    if fm_dod_named_head_reachable_outside_worktree "$wt" "$project" local-only "$sha"; then
      return 0
    fi
    printf '%s\n' "held named head $sha is not on a branch of the project's local repository"
    return 1
  fi
  gerrit=0
  [ -n "$url" ] && fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = gerrit ] && gerrit=1
  if [ "$gerrit" = 0 ] && fm_dod_note_reports_published_change "$(status_line_note "$line")"; then
    printf '%s\n' "the published-for-review report does not name a Gerrit change in the canonical https://<host>/c/<project>/+/<number> form"
    return 1
  fi
  if [ "$gerrit" = 1 ]; then
    case "$mode" in
      no-mistakes|'')
        fm_dod_nm_custody_returned "$wt" || return 1 ;;
    esac
    if fm_dod_gerrit_change_carries_head "$wt" "$url"; then
      return 0
    fi
    printf '%s\n' "named head $sha is not the published content of $url: the change's current patch set does not carry this copy's HEAD tree, or it could not be read"
    return 1
  fi
  if fm_dod_named_head_reachable_outside_worktree "$wt" "$project" "$mode" "$sha"; then
    return 0
  fi
  printf '%s\n' "named head $sha is unreachable outside the worker copy"
  return 1
}
