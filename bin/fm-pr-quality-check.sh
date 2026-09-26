#!/usr/bin/env bash
# fm-pr-quality-check.sh - measure a branch and a PR body against the
# PR quality check a project's own GitHub workflow configures, before that body
# ever reaches a forge.
#
# A pipeline-generated or agent-generated PR body fails that check by default:
# it is long, it cites many files, and it repeats vocabulary a project may
# block. This script measures the same quantities locally so a breach is caught
# on the branch instead of on the captain's PR.
#
# Usage:
#   fm-pr-quality-check.sh --project <dir> --base <ref> [--head <ref>] [--body <file>] [--title <text>]
#   fm-pr-quality-check.sh --project <dir> --body <file> [--title <text>]
#   fm-pr-quality-check.sh --project <dir> --print-limits [--action <owner/name>]
#   fm-pr-quality-check.sh --help
#
#   --project <dir>   the project working tree to measure. Required.
#   --base <ref>      the branch the PR would target. Enables the diff rules,
#                     measured over <base>...<head> (merge-base to head), which
#                     is what a pull request diff contains.
#   --head <ref>      the branch being proposed. Defaults to HEAD.
#   --body <file>     the PR description to measure. Enables the body rules.
#   --title <text>    the PR title. The emoji rule counts title and body
#                     together, so without this the title's emoji go unmeasured
#                     and the emoji line says so.
#   --print-limits    print the project's configured limits as KEY=VALUE lines
#                     and exit, measuring nothing. This is the one parser for
#                     that workflow, so callers that need the numbers (for
#                     example bin/fm-brief.sh) read them from here.
#   --action <ref>    the GitHub Action whose step carries the limits, as
#                     owner/name. Defaults to the one line in
#                     <home>/config/pr-quality-action (see WHICH ACTION IT READS).
#
# At least one of --base or --body is required: with neither there is nothing to
# measure. Rules that the given inputs cannot measure print as SKIP with the
# reason, so a rule is never silently treated as passing.
#
# Exit codes:
#   0  every measured rule is within its limit, or the project configures no
#      PR quality check at all (reported as not applicable)
#   1  at least one measured rule breaches its limit; every breach is named
#   2  the check could not be performed: bad usage, an unresolvable ref, or a
#      workflow that names the configured PR quality action but cannot be parsed
#
# It never stops at the first breach. One run names every breach, so a body is
# revised once rather than resubmitted rule by rule.
#
# WHICH ACTION IT READS
# The action is a private per-home setting, never named in tracked code: the
# first non-blank line of config/pr-quality-action under $FM_CONFIG_OVERRIDE,
# else $FM_HOME/config, else this checkout's config/, as owner/name (any
# @version suffix is ignored). --action overrides it. With no action
# configured every project is reported as not applicable and exits 0.
# docs/configuration.md "PR quality action" owns the setting.
#
# WHICH WORKFLOW IT READS
# Every file under <project>/.github/workflows/ is scanned for a step whose
# `uses:` names the configured PR quality action. No filename is assumed and no limit is
# hardcoded: the configured values come from that step's `with:` block, and any
# input the step leaves unset falls back to the action's own documented default.
# A project with no such step is reported as not applicable and exits 0. A file
# that names the action but cannot be parsed exits 2 rather than reporting a
# pass, and so does more than one PR quality step, whose limits could disagree.
#
# WHAT IT MEASURES, AND HOW FAITHFULLY
# The reference is release v0.3.0 of the action this script was written for
# (commit 57858eead489d08b255fab2af45a506c2ca6eab2). Its check implementations and its
# input defaults were read from that tag, and the rules below reproduce them
# rather than approximate them:
#
#   max-changed-files       one entry per file in `git diff --name-only
#                           <base>...<head>`, matching the file list a pull
#                           request reports.
#   max-changed-lines       additions plus deletions from `git diff --numstat`
#                           over the same range. A binary file contributes 0,
#                           as it does on the forge.
#   description-empty       the body with all whitespace removed is non-empty.
#   description-max-length  the body's length in UTF-16 code units, which is
#                           what the action's JavaScript `String.length`
#                           counts. An emoji outside the basic plane therefore
#                           counts as 2, not 1.
#   emoji-count             code points matching \p{Extended_Pictographic},
#                           plus `:shortcode:` spellings, over title and body.
#   blocked-terms           case-sensitive substring search over the body with
#                           HTML comments removed first, counting how many
#                           distinct configured terms appear.
#   code-references         the action's three patterns, summed independently:
#                           file-path-like tokens, `Foo::bar()` and `$foo->bar()`
#                           method calls, and `name()` function calls. A single
#                           token matching two patterns counts twice, exactly as
#                           it does upstream.
#   blocked-paths           a changed file whose name equals a configured
#                           pattern, or begins with it when the pattern ends in
#                           `/`, compared case-insensitively.
#   max-commit-message-length
#                           each commit message this branch adds, in UTF-16 code
#                           units, which is what the action's JavaScript
#                           `String.length` counts. The action lists the pull
#                           request's commits and drops the ones inherited from
#                           the default branch; `<base>..<head>` (two dots, a
#                           commit list, NOT the three-dot diff range the size
#                           rules use) is the local equivalent. A trailing
#                           newline is stripped first, because the API's
#                           `commit.message` does not carry one and `git log
#                           --format=%B` does. A limit of 0 disables the rule.
#
# WHERE IT DELIBERATELY ERRS STRICT
# A false pass is the failure that costs the captain a rejected PR, so every
# unavoidable divergence errs toward reporting a breach:
#
#   - Any breach exits non-zero. The action instead fails only once its failure
#     count reaches `max-failures`, so a project with the default of 4 tolerates
#     3 failures. This script measures a subset of the action's rules and cannot
#     know how many of the rest are failing, so it treats one breach as a
#     breach. The configured `max-failures` is printed for context.
#   - Line endings are normalized to CRLF before the body is measured, because a
#     forge stores a description that way and counts it that way. A body written
#     locally with bare newlines is therefore measured one character longer per
#     line than the file on disk.
#   - Exemptions are not modeled. Author association, bot authorship, labels,
#     milestones and draft state can all exempt a real pull request; this script
#     measures the content regardless.
#
# WHAT IT DOES NOT MEASURE
# The action also checks conventional-commit format, commit authorship, branch
# names, file extensions, final newlines, added comment volume, linked issues,
# pull request templates, and the author's account history. Those are outside
# this script's inputs. A clean run here means the measured rules pass, not that
# the whole action will.
#
# The action's defaults are read from the version this script was calibrated
# against. When a project pins a different version, the run still measures every
# rule but prints a warning naming the pinned reference, because a default this
# script did not observe may have moved.
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

die() { echo "error: $*" >&2; exit 2; }

PROJECT=
BASE=
HEAD=HEAD
BODY=
TITLE=
PRINT_LIMITS=0
ACTION=
ACTION_SET=0
TITLE_SET=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) [ "$#" -ge 2 ] || die "--project requires a value"; PROJECT=$2; shift 2 ;;
    --project=*) PROJECT=${1#--project=}; shift ;;
    --base) [ "$#" -ge 2 ] || die "--base requires a value"; BASE=$2; shift 2 ;;
    --base=*) BASE=${1#--base=}; shift ;;
    --head) [ "$#" -ge 2 ] || die "--head requires a value"; HEAD=$2; shift 2 ;;
    --head=*) HEAD=${1#--head=}; shift ;;
    --body) [ "$#" -ge 2 ] || die "--body requires a value"; BODY=$2; shift 2 ;;
    --body=*) BODY=${1#--body=}; shift ;;
    --title) [ "$#" -ge 2 ] || die "--title requires a value"; TITLE=$2; TITLE_SET=1; shift 2 ;;
    --title=*) TITLE=${1#--title=}; TITLE_SET=1; shift ;;
    --print-limits) PRINT_LIMITS=1; shift ;;
    --action) [ "$#" -ge 2 ] || die "--action requires a value"; ACTION=$2; ACTION_SET=1; shift 2 ;;
    --action=*) ACTION=${1#--action=}; ACTION_SET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$PROJECT" ] || die "--project <dir> is required"
[ -d "$PROJECT" ] || die "--project is not a directory: $PROJECT"
PROJECT=$(CDPATH='' cd -- "$PROJECT" 2>/dev/null && pwd -P) || die "--project cannot be resolved: $PROJECT"

if [ "$PRINT_LIMITS" -eq 0 ]; then
  [ -n "$BASE" ] || [ -n "$BODY" ] || die "nothing to measure: pass --base <ref> for the branch rules, --body <file> for the description rules, or both"
fi
if [ -n "$BODY" ] && [ ! -f "$BODY" ]; then
  die "--body file does not exist: $BODY"
fi

command -v perl >/dev/null 2>&1 || die "perl is required to parse the workflow and measure the description"

# --- resolve the configured action -----------------------------------------
if [ "$ACTION_SET" -eq 0 ]; then
  SELF_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd -P) || SELF_ROOT=
  ACTION_FILE="${FM_CONFIG_OVERRIDE:-${FM_HOME:-$SELF_ROOT}/config}/pr-quality-action"
  if [ -f "$ACTION_FILE" ]; then
    ACTION=$(awk 'NF { print $1; exit }' "$ACTION_FILE" 2>/dev/null) || ACTION=
  fi
fi
ACTION=${ACTION%%@*}
case "$ACTION" in
  "") ;;
  *[!A-Za-z0-9._/-]*|/*|*/) die "the PR quality action must be an owner/name reference: '$ACTION'" ;;
esac
if [ -z "$ACTION" ]; then
  if [ "$PRINT_LIMITS" -eq 1 ]; then
    echo "applicable=no"
  else
    echo "project: $PROJECT"
    echo "not applicable: no PR quality action is configured for this home"
  fi
  exit 0
fi
export FM_PR_QUALITY_ACTION="$ACTION"

# --- locate the PR quality step -----------------------------------------------------------------------------
# No filename is assumed: any workflow file may carry the step, so every one is
# scanned for a `uses:` naming the action.
WORKFLOW_DIR="$PROJECT/.github/workflows"
CANDIDATES=()
if [ -d "$WORKFLOW_DIR" ]; then
  while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    CANDIDATES+=("$wf")
  done < <(find "$WORKFLOW_DIR" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print 2>/dev/null | sort)
fi

MATCHED=()
for wf in ${CANDIDATES+"${CANDIDATES[@]}"}; do
  if grep -qF "$ACTION@" "$wf" 2>/dev/null; then
    MATCHED+=("$wf")
  fi
done

if [ "${#MATCHED[@]}" -eq 0 ]; then
  if [ "$PRINT_LIMITS" -eq 1 ]; then
    echo "applicable=no"
  else
    echo "project: $PROJECT"
    echo "not applicable: this project configures no PR quality check"
  fi
  exit 0
fi
if [ "${#MATCHED[@]}" -gt 1 ]; then
  die "more than one workflow configures the PR quality check, and their limits could disagree: ${MATCHED[*]}"
fi
WORKFLOW=${MATCHED[0]}

# --- the workflow parser and the body measurements --------------------------
# Built with `read -r -d ''` rather than a heredoc inside a command
# substitution: that construct breaks parsing of the whole file under Bash 3.2
# (see tests/fm-brief.test.sh for the class).
IFS= read -r -d '' AS_PERL <<'PERL_EOF' || true
use strict;
use warnings;
use Encode qw(decode FB_CROAK);

# Calibration reference. The defaults below and the check implementations they
# feed were read from this tag of the action.
my $CALIBRATED_VERSION = 'v0.3.0';
my $CALIBRATED_SHA     = '57858eead489d08b255fab2af45a506c2ca6eab2';

my ($workflow, $bodyfile, $title, $title_set) = @ARGV;

sub bail { print "error=$_[0]\n"; exit 2 }

sub slurp {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or bail("cannot read $path: $!");
    local $/;
    my $bytes = <$fh>;
    close($fh);
    $bytes = '' unless defined $bytes;
    my $text = eval { decode('UTF-8', $bytes, FB_CROAK) };
    bail("$path is not valid UTF-8") if $@;
    return $text;
}

# --- workflow parsing -------------------------------------------------------
my $wf = slurp($workflow);
my @raw = split(/\n/, $wf, -1);

# A structural line carries its key indent: the column of its first content
# character, counting a `- ` list marker as indentation of the key it holds.
my @lines;
for my $i (0 .. $#raw) {
    my $l = $raw[$i];
    next if $l =~ /^\s*$/;
    next if $l =~ /^\s*#/;
    bail('the workflow indents with tabs, which YAML forbids') if $l =~ /^[ ]*\t/;
    my ($indent, $item, $rest);
    if ($l =~ /^( *)-( +)(\S.*)$/) {
        $indent = length($1) + 1 + length($2);
        $item   = 1;
        $rest   = $3;
    } elsif ($l =~ /^( *)(\S.*)$/) {
        $indent = length($1);
        $item   = 0;
        $rest   = $2;
    } else {
        next;
    }
    push @lines, { n => $i, indent => $indent, item => $item, rest => $rest };
}

# Find every step whose `uses:` names the configured PR quality action.
my @uses_idx;
for my $j (0 .. $#lines) {
    my $rest = $lines[$j]{rest};
    next unless $rest =~ /^uses:\s*(.*)$/;
    my $val = $1;
    $val =~ s/\s+#.*$//;
    $val =~ s/\s+$//;
    next unless $val =~ m{^\Q$ENV{FM_PR_QUALITY_ACTION}\E\@};
    push @uses_idx, { j => $j, value => $val, comment => ($rest =~ /#\s*(\S.*?)\s*$/ ? $1 : '') };
}

bail('a workflow names the configured PR quality action but no step could be parsed from it')
    if @uses_idx == 0;
bail('more than one PR quality step is configured, and their limits could disagree')
    if @uses_idx > 1;

my $uses = $uses_idx[0];
my $K = $lines[ $uses->{j} ]{indent};

# `with:` is a sibling key of `uses:` inside the same step, so scan outward from
# `uses:` and stop at the step's own boundaries in each direction.
my $with_j;
for my $j ($uses->{j} + 1 .. $#lines) {
    last if $lines[$j]{indent} < $K;
    last if $lines[$j]{item};
    next if $lines[$j]{indent} > $K;
    if ($lines[$j]{rest} =~ /^with:\s*$/) { $with_j = $j; last }
}
if (!defined $with_j) {
    for (my $j = $uses->{j} - 1; $j >= 0; $j--) {
        last if $lines[$j]{indent} < $K;
        if ($lines[$j]{indent} == $K && $lines[$j]{rest} =~ /^with:\s*$/) { $with_j = $j; last }
        last if $lines[$j]{item};
    }
}

# Collect the step's `with:` inputs. A key whose value is a `|` block scalar
# takes the indented lines that follow it.
my %given;
if (defined $with_j) {
    my $W;
    my @block;
    for my $j ($with_j + 1 .. $#lines) {
        last if $lines[$j]{indent} <= $K;
        last if $lines[$j]{item} && $lines[$j]{indent} <= $K;
        $W = $lines[$j]{indent} unless defined $W;
        push @block, $lines[$j];
    }
    my $pending_key;
    my @pending_lines;
    my $pending_indent;
    my $flush = sub {
        return unless defined $pending_key;
        my $text = '';
        if (@pending_lines) {
            my $min;
            for my $bl (@pending_lines) {
                my ($ws) = $raw[ $bl->{n} ] =~ /^( *)/;
                my $len = length($ws);
                $min = $len if !defined $min || $len < $min;
            }
            $min = 0 unless defined $min;
            $text = join("\n", map { my $s = $raw[ $_->{n} ]; substr($s, $min) } @pending_lines);
        }
        $given{$pending_key} = { value => $text, block => 1 };
        $pending_key = undef;
        @pending_lines = ();
    };
    for my $bl (@block) {
        if (defined $pending_key && $bl->{indent} > $pending_indent) {
            push @pending_lines, $bl;
            next;
        }
        $flush->();
        next unless $bl->{indent} == $W;
        my $rest = $bl->{rest};
        if ($rest =~ /^([A-Za-z0-9_.-]+):\s*(.*)$/) {
            my ($key, $val) = ($1, $2);
            if ($val =~ /^[|>][+-]?\s*$/) {
                bail("the PR quality action input '$key' uses a folded block scalar, which this parser does not read")
                    if $val =~ /^>/;
                $pending_key    = $key;
                $pending_indent = $bl->{indent};
                @pending_lines  = ();
                $given{$key}    = { value => '', block => 1 };
                next;
            }
            $val =~ s/\s+#.*$// unless $val =~ /^['"]/;
            $val =~ s/\s+$//;
            if ($val =~ /^'(.*)'$/) { $val = $1; $val =~ s/''/'/g }
            elsif ($val =~ /^"(.*)"$/) { $val = $1 }
            $given{$key} = { value => $val, block => 0 };
        } else {
            bail('an PR quality action input could not be parsed: ' . $rest);
        }
    }
    $flush->();
}

# The action's own documented defaults, for every input left unset.
my %default = (
    'max-failures'           => '4',
    'max-changed-files'      => '50',
    'max-changed-lines'      => '10000',
    'require-description'    => 'true',
    'max-description-length' => '2500',
    'max-emoji-count'        => '2',
    'max-code-references'    => '5',
    'blocked-terms'          => '',
    'blocked-paths'          => '',
    'max-commit-message-length' => '500',
);

sub input_of {
    my ($key) = @_;
    return $given{$key}{value} if exists $given{$key};
    return $default{$key};
}

sub configured { return exists $given{$_[0]} ? 'workflow' : 'default' }

# `parseInt` on a value the workflow supplies; a value that is not a number is a
# malformed workflow rather than a rule to quietly skip.
sub int_input {
    my ($key) = @_;
    my $v = input_of($key);
    $v = '' unless defined $v;
    $v =~ s/^\s+|\s+$//g;
    bail("the PR quality action input '$key' contains a template expression this parser cannot evaluate: $v")
        if $v =~ /\$\{\{/;
    bail("the PR quality action input '$key' is not a number: '$v'") unless $v =~ /^-?\d+$/;
    return $v + 0;
}

sub bool_input {
    my ($key) = @_;
    my $v = input_of($key);
    $v = '' unless defined $v;
    $v =~ s/^\s+|\s+$//g;
    return 1 if $v =~ /^(true|True|TRUE)$/;
    return 0 if $v =~ /^(false|False|FALSE)$/;
    bail("the PR quality action input '$key' is not a boolean: '$v'");
}

# `getMultilineInput`: trim the whole value, split on newlines, drop empty
# lines, then trim each remaining line.
sub list_input {
    my ($key) = @_;
    my $v = input_of($key);
    $v = '' unless defined $v;
    bail("the PR quality action input '$key' contains a template expression this parser cannot evaluate")
        if $v =~ /\$\{\{/;
    $v =~ s/^\s+|\s+$//g;
    my @out;
    for my $line (split(/\n/, $v, -1)) {
        next if $line eq '';
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '';
        push @out, $line;
    }
    return @out;
}

my ($action_ref) = $uses->{value} =~ /\@(\S+)$/;
$action_ref = '' unless defined $action_ref;
my $calibrated =
    ( $action_ref eq $CALIBRATED_VERSION
      || $action_ref eq $CALIBRATED_SHA
      || $uses->{comment} =~ /\Q$CALIBRATED_VERSION\E/ ) ? 'yes' : 'no';

my $max_failures    = int_input('max-failures');
my $max_files       = int_input('max-changed-files');
my $max_lines       = int_input('max-changed-lines');
my $require_desc    = bool_input('require-description');
my $max_desc_length = int_input('max-description-length');
my $max_emoji       = int_input('max-emoji-count');
my $max_code_refs   = int_input('max-code-references');
my $max_commit_msg  = int_input('max-commit-message-length');
my @blocked_terms   = list_input('blocked-terms');
my @blocked_paths   = list_input('blocked-paths');

print "applicable=yes\n";
print "workflow=$workflow\n";
print "action_uses=$uses->{value}\n";
print "action_ref=$action_ref\n";
print "calibrated=$calibrated\n";
print "calibrated_version=$CALIBRATED_VERSION\n";
print "max_failures=$max_failures\n";
print "max_changed_files=$max_files\n";
print "max_changed_files_source=", configured('max-changed-files'), "\n";
print "max_changed_lines=$max_lines\n";
print "max_changed_lines_source=", configured('max-changed-lines'), "\n";
print "require_description=$require_desc\n";
print "max_description_length=$max_desc_length\n";
print "max_description_length_source=", configured('max-description-length'), "\n";
print "max_emoji_count=$max_emoji\n";
print "max_emoji_count_source=", configured('max-emoji-count'), "\n";
print "max_code_references=$max_code_refs\n";
print "max_code_references_source=", configured('max-code-references'), "\n";
print "max_commit_message_length=$max_commit_msg\n";
print "max_commit_message_length_source=", configured('max-commit-message-length'), "\n";
print "blocked_term=$_\n" for @blocked_terms;
print "blocked_path=$_\n" for @blocked_paths;

exit 0 unless defined $bodyfile && $bodyfile ne '';

# --- body measurements ------------------------------------------------------
my $body = slurp($bodyfile);

# A forge stores a description with CRLF line endings and counts it that way, so
# measure the body as it will be stored rather than as it sits on disk.
$body =~ s/\r\n/\n/g;
$body =~ s/\n/\r\n/g;

# JavaScript's String.length counts UTF-16 code units, so a code point outside
# the basic plane counts as two.
my $length = length($body);
$length += () = $body =~ /[\x{10000}-\x{10FFFF}]/g;

my $stripped = $body;
$stripped =~ s/\s//g;
print "body_empty=", (length($stripped) == 0 ? 'yes' : 'no'), "\n";
print "body_length=$length\n";

$title = '' unless defined $title;
$title = eval { decode('UTF-8', $title, FB_CROAK) };
bail('--title is not valid UTF-8') if $@;
my $emoji_text = ($title_set ? "$title " : '') . $body;
my $unicode_emoji = () = $emoji_text =~ /\p{Extended_Pictographic}/g;
my $shortcode_emoji = () = $emoji_text =~ /(?a)(?<!\w):[\w+-]+:(?!\w)/g;
print "emoji_count=", $unicode_emoji + $shortcode_emoji, "\n";
print "emoji_title_included=", ($title_set ? 'yes' : 'no'), "\n";

# The action strips HTML comments, then does a case-sensitive substring search.
my $visible = $body;
$visible =~ s/<!--[\s\S]*?-->//g;
for my $term (@blocked_terms) {
    print "blocked_term_found=$term\n" if index($visible, $term) >= 0;
}

# The action's three inline-code patterns, each counted independently over the
# whole body, so one token matching two patterns is counted twice. ASCII
# semantics are forced with (?a) because the upstream patterns are JavaScript
# regexes without the unicode flag.
my $code_refs = 0;
$code_refs += () = $body =~ m{(?a)(?:[\w@.-]+/)+[\w.-]+\.\w{1,10}}g;
$code_refs += () = $body =~ m{(?a)\w+(?:->|::)\w+\(\)}g;
$code_refs += () = $body =~ m{(?a)\w{3,}\(\)}g;
print "code_references=$code_refs\n";
PERL_EOF

PARSED=$(perl -e "$AS_PERL" -- "$WORKFLOW" "$BODY" "$TITLE" "$TITLE_SET" 2>&1) || {
  case "$PARSED" in
    error=*) die "${WORKFLOW#"$PROJECT"/}: ${PARSED#error=}" ;;
    *) printf '%s\n' "$PARSED" >&2; die "${WORKFLOW#"$PROJECT"/} could not be read" ;;
  esac
}

MAX_FAILURES=; MAX_FILES=; MAX_LINES=; REQUIRE_DESC=
MAX_DESC=; MAX_EMOJI=; MAX_CODE=; MAX_COMMIT_MSG=; ACTION_USES=; ACTION_REF=
CALIBRATED=; CALIBRATED_VERSION=
BODY_EMPTY=; BODY_LENGTH=; EMOJI_COUNT=; EMOJI_TITLE=; CODE_REFS=
SRC_FILES=; SRC_LINES=; SRC_DESC=; SRC_EMOJI=; SRC_CODE=; SRC_COMMIT_MSG=
BLOCKED_TERMS=(); BLOCKED_PATHS=(); TERMS_FOUND=()

while IFS= read -r line; do
  [ -n "$line" ] || continue
  key=${line%%=*}
  val=${line#*=}
  case "$key" in
    error) die "${WORKFLOW#"$PROJECT"/}: $val" ;;
    workflow|applicable) ;;
    action_uses) ACTION_USES=$val ;;
    action_ref) ACTION_REF=$val ;;
    calibrated) CALIBRATED=$val ;;
    calibrated_version) CALIBRATED_VERSION=$val ;;
    max_failures) MAX_FAILURES=$val ;;
    max_changed_files) MAX_FILES=$val ;;
    max_changed_files_source) SRC_FILES=$val ;;
    max_changed_lines) MAX_LINES=$val ;;
    max_changed_lines_source) SRC_LINES=$val ;;
    require_description) REQUIRE_DESC=$val ;;
    max_description_length) MAX_DESC=$val ;;
    max_description_length_source) SRC_DESC=$val ;;
    max_emoji_count) MAX_EMOJI=$val ;;
    max_emoji_count_source) SRC_EMOJI=$val ;;
    max_code_references) MAX_CODE=$val ;;
    max_code_references_source) SRC_CODE=$val ;;
    max_commit_message_length) MAX_COMMIT_MSG=$val ;;
    max_commit_message_length_source) SRC_COMMIT_MSG=$val ;;
    blocked_term) BLOCKED_TERMS+=("$val") ;;
    blocked_path) BLOCKED_PATHS+=("$val") ;;
    blocked_term_found) TERMS_FOUND+=("$val") ;;
    body_empty) BODY_EMPTY=$val ;;
    body_length) BODY_LENGTH=$val ;;
    emoji_count) EMOJI_COUNT=$val ;;
    emoji_title_included) EMOJI_TITLE=$val ;;
    code_references) CODE_REFS=$val ;;
    *) die "unrecognized measurement '$key' from the workflow reader" ;;
  esac
done <<EOF
$PARSED
EOF

[ -n "$MAX_DESC" ] || die "the workflow reader produced no limits"

if [ "$PRINT_LIMITS" -eq 1 ]; then
  printf '%s\n' "$PARSED"
  exit 0
fi

# --- diff measurements ------------------------------------------------------
CHANGED_FILES=
CHANGED_LINES=
CHANGED_NAMES=()
if [ -n "$BASE" ]; then
  git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1 || die "--project is not a git working tree: $PROJECT"
  git -C "$PROJECT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || die "base ref does not resolve in $PROJECT: $BASE"
  git -C "$PROJECT" rev-parse --verify --quiet "$HEAD^{commit}" >/dev/null || die "head ref does not resolve in $PROJECT: $HEAD"
  git -C "$PROJECT" merge-base "$BASE" "$HEAD" >/dev/null 2>&1 || die "base and head share no history in $PROJECT: $BASE and $HEAD"

  while IFS= read -r -d '' name; do
    CHANGED_NAMES+=("$name")
  done < <(git -C "$PROJECT" diff --name-only -z "$BASE...$HEAD")
  CHANGED_FILES=${#CHANGED_NAMES[@]}

  numstat=$(git -C "$PROJECT" diff --numstat "$BASE...$HEAD") || die "git diff failed in $PROJECT"
  CHANGED_LINES=$(printf '%s\n' "$numstat" | awk '
    NF == 0 { next }
    { a = ($1 == "-") ? 0 : $1; d = ($2 == "-") ? 0 : $2; total += a + d }
    END { print total + 0 }
  ')
fi

# --- commit measurements ----------------------------------------------------
COMMIT_COUNT=0
OVERSIZED=()
if [ -n "$BASE" ] && [ "$MAX_COMMIT_MSG" -gt 0 ]; then
  # Two dots, not three: this is a commit list, and the three-dot spelling would
  # be the symmetric difference and drag in the base branch's own commits.
  commit_lengths=$(git -C "$PROJECT" log -z --format='%H%x1f%B' "$BASE..$HEAD" |
    perl -e '
      use strict; use warnings;
      use Encode qw(decode FB_CROAK);
      local $/ = "\0";
      while (my $rec = <STDIN>) {
        chomp $rec;
        next if $rec eq q{};
        my ($sha, $msg) = split(/\x1f/, $rec, 2);
        $msg = q{} unless defined $msg;
        $msg = eval { decode("UTF-8", $msg, FB_CROAK) };
        if ($@) { print "error\n"; exit 2 }
        # The API commit.message carries no trailing newline; git log --format=%B does.
        $msg =~ s/\n+\z//;
        my $len = length($msg);
        # JavaScript String.length counts UTF-16 code units, so an astral code point counts twice.
        $len += () = $msg =~ /[\x{10000}-\x{10FFFF}]/g;
        print "$sha $len\n";
      }
    ') || die "cannot measure the commit messages in $PROJECT"

  while read -r sha len; do
    [ -n "$sha" ] || continue
    [ "$sha" != error ] || die "a commit message in $PROJECT is not valid UTF-8"
    COMMIT_COUNT=$((COMMIT_COUNT + 1))
    if [ "$len" -gt "$MAX_COMMIT_MSG" ]; then
      OVERSIZED+=("$(git -C "$PROJECT" rev-parse --short "$sha") ($len)")
    fi
  done <<COMMITS
$commit_lengths
COMMITS
fi

# --- report -----------------------------------------------------------------
BREACHES=()
rel_workflow=${WORKFLOW#"$PROJECT"/}

echo "project: $PROJECT"
echo "workflow: $rel_workflow"
echo "action: $ACTION_USES"
if [ -n "$BASE" ]; then
  echo "range: $BASE...$HEAD"
fi
if [ -n "$BODY" ]; then
  echo "body: $BODY"
fi
if [ "$CALIBRATED" != yes ]; then
  echo "warning: this project pins the PR quality action at '$ACTION_REF', not the $CALIBRATED_VERSION this script was calibrated against; any limit shown as a default may have moved upstream"
fi
echo

report() {
  local verdict=$1 rule=$2 detail=$3
  printf '%-5s %-24s %s\n' "$verdict" "$rule" "$detail"
  [ "$verdict" = FAIL ] && BREACHES+=("$rule")
  return 0
}

note_source() {
  [ "$1" = default ] && printf ' (action default)' || printf ''
}

# Size rules.
if [ "$MAX_FILES" -gt 0 ]; then
  if [ -z "$BASE" ]; then
    report SKIP max-changed-files "not measured: pass --base <ref>"
  elif [ "$CHANGED_FILES" -gt "$MAX_FILES" ]; then
    report FAIL max-changed-files "$CHANGED_FILES files, limit $MAX_FILES$(note_source "$SRC_FILES")"
  else
    report PASS max-changed-files "$CHANGED_FILES files, limit $MAX_FILES$(note_source "$SRC_FILES")"
  fi
fi
if [ "$MAX_LINES" -gt 0 ]; then
  if [ -z "$BASE" ]; then
    report SKIP max-changed-lines "not measured: pass --base <ref>"
  elif [ "$CHANGED_LINES" -gt "$MAX_LINES" ]; then
    report FAIL max-changed-lines "$CHANGED_LINES lines, limit $MAX_LINES$(note_source "$SRC_LINES")"
  else
    report PASS max-changed-lines "$CHANGED_LINES lines, limit $MAX_LINES$(note_source "$SRC_LINES")"
  fi
fi

# Commit rules.
if [ "$MAX_COMMIT_MSG" -gt 0 ]; then
  if [ -z "$BASE" ]; then
    report SKIP max-commit-message-length "not measured: pass --base <ref>"
  elif [ "${#OVERSIZED[@]}" -gt 0 ]; then
    joined=$(printf '%s, ' "${OVERSIZED[@]}")
    report FAIL max-commit-message-length "${#OVERSIZED[@]} of $COMMIT_COUNT commit messages over $MAX_COMMIT_MSG chars$(note_source "$SRC_COMMIT_MSG"): ${joined%, }"
  else
    report PASS max-commit-message-length "0 of $COMMIT_COUNT commit messages over $MAX_COMMIT_MSG chars$(note_source "$SRC_COMMIT_MSG")"
  fi
fi

# Description rules.
if [ "$REQUIRE_DESC" -eq 1 ]; then
  if [ -z "$BODY" ]; then
    report SKIP description-empty "not measured: pass --body <file>"
  elif [ "$BODY_EMPTY" = yes ]; then
    report FAIL description-empty "the description is empty"
  else
    report PASS description-empty "the description is present"
  fi
fi
if [ "$MAX_DESC" -gt 0 ]; then
  if [ -z "$BODY" ]; then
    report SKIP description-max-length "not measured: pass --body <file>"
  elif [ "$BODY_LENGTH" -gt "$MAX_DESC" ]; then
    report FAIL description-max-length "$BODY_LENGTH chars, limit $MAX_DESC$(note_source "$SRC_DESC")"
  else
    report PASS description-max-length "$BODY_LENGTH chars, limit $MAX_DESC$(note_source "$SRC_DESC")"
  fi
fi
if [ "$MAX_EMOJI" -gt 0 ]; then
  caveat=
  [ "$EMOJI_TITLE" = no ] && caveat=" (title not measured: pass --title)"
  if [ -z "$BODY" ]; then
    report SKIP emoji-count "not measured: pass --body <file>"
  elif [ "$EMOJI_COUNT" -gt "$MAX_EMOJI" ]; then
    report FAIL emoji-count "$EMOJI_COUNT emoji, limit $MAX_EMOJI$(note_source "$SRC_EMOJI")$caveat"
  else
    report PASS emoji-count "$EMOJI_COUNT emoji, limit $MAX_EMOJI$(note_source "$SRC_EMOJI")$caveat"
  fi
fi
if [ "${#BLOCKED_TERMS[@]}" -gt 0 ]; then
  if [ -z "$BODY" ]; then
    report SKIP blocked-terms "not measured: pass --body <file>"
  elif [ "${#TERMS_FOUND[@]}" -gt 0 ]; then
    joined=$(printf '"%s", ' "${TERMS_FOUND[@]}")
    report FAIL blocked-terms "${#TERMS_FOUND[@]} of ${#BLOCKED_TERMS[@]} blocked terms present: ${joined%, }"
  else
    report PASS blocked-terms "0 of ${#BLOCKED_TERMS[@]} blocked terms present"
  fi
fi
if [ "$MAX_CODE" -gt 0 ]; then
  if [ -z "$BODY" ]; then
    report SKIP code-references "not measured: pass --body <file>"
  elif [ "$CODE_REFS" -gt "$MAX_CODE" ]; then
    report FAIL code-references "$CODE_REFS references, limit $MAX_CODE$(note_source "$SRC_CODE")"
  else
    report PASS code-references "$CODE_REFS references, limit $MAX_CODE$(note_source "$SRC_CODE")"
  fi
fi

# File rules.
if [ "${#BLOCKED_PATHS[@]}" -gt 0 ]; then
  if [ -z "$BASE" ]; then
    report SKIP blocked-paths "not measured: pass --base <ref>"
  else
    # A file matching two patterns is still one blocked file, so stop at the
    # first match rather than counting it once per pattern.
    hits=()
    for name in ${CHANGED_NAMES+"${CHANGED_NAMES[@]}"}; do
      lower_name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
      for pattern in "${BLOCKED_PATHS[@]}"; do
        lower_pattern=$(printf '%s' "$pattern" | tr '[:upper:]' '[:lower:]')
        matched=0
        case "$lower_pattern" in
          */) case "$lower_name" in "$lower_pattern"*) matched=1 ;; esac ;;
          *) [ "$lower_name" = "$lower_pattern" ] && matched=1 ;;
        esac
        if [ "$matched" -eq 1 ]; then
          hits+=("$name")
          break
        fi
      done
    done
    if [ "${#hits[@]}" -gt 0 ]; then
      joined=$(printf '%s, ' "${hits[@]}")
      report FAIL blocked-paths "${#hits[@]} changed files in blocked paths: ${joined%, }"
    else
      report PASS blocked-paths "0 changed files in ${#BLOCKED_PATHS[@]} blocked paths"
    fi
  fi
fi

echo
if [ "${#BREACHES[@]}" -gt 0 ]; then
  joined=$(printf '%s, ' "${BREACHES[@]}")
  echo "FAILED: ${#BREACHES[@]} rule(s) breached: ${joined%, }"
  echo "This project's check fails a pull request once ${MAX_FAILURES} rule(s) fail, and it checks rules this script does not measure, so treat any breach here as a breach."
  exit 1
fi
echo "PASSED: every measured rule is within its limit."
exit 0
