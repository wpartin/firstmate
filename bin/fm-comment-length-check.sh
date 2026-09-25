#!/usr/bin/env bash
# fm-comment-length-check.sh - find multi-line comment runs in the lines a
# branch ADDS, so a worker collapses them before the branch is handed over.
#
# The captain's rule: every comment a firstmate worker writes is one line.
# Inline comments and JSDoc or block comments alike. The rule is about the
# comments a change ADDS: a pre-existing multi-line comment in a touched file is
# not in scope, and reformatting one would be exactly the unrequested churn the
# rule exists to reduce.
#
# WHY IT MEASURES A BRANCH INSTEAD OF AUDITING A MERGED TREE
# Collapsing a comment on the branch costs nothing. Catching the same comment
# after review costs a force-push on an open pull request and a reviewer seeing
# churn that has nothing to do with the change. The branch is the cheap moment,
# so this fires there. bin/fm-change-range-lib.sh owns the range contract.
#
# Usage:
#   fm-comment-length-check.sh --project <dir> --base <ref> [--head <ref>]
#   fm-comment-length-check.sh --print-scope
#   fm-comment-length-check.sh --help
#
#   --project <dir>   the project working tree to measure. Required.
#   --base <ref>      the branch this one will land on. Required.
#   --head <ref>      the branch being measured. Defaults to HEAD.
#   --print-scope     print the measured languages as KEY=VALUE lines and exit,
#                     measuring nothing. This is the one owner of the language
#                     scope, so a caller that needs to state it (for example
#                     bin/fm-brief.sh) reads it from here rather than repeating
#                     a list that would drift.
#
# Exit codes:
#   0  no multi-line comment run touches an added line. Nothing is printed on
#      stdout, so a clean run is silent and scriptable.
#   1  at least one run was found. Every one is named, with file and line range,
#      in a single run: a branch is revised once, not run by run.
#   2  the check could not be performed: bad usage, an unresolvable ref, a file
#      that is not valid UTF-8, or source this script cannot lex with confidence.
#      Never 0, because a clean exit reads as a clean branch.
#
# WHAT COUNTS AS A MULTI-LINE COMMENT RUN
# A line belongs to a comment region when its only content is a comment, or when
# a block comment spans across it. Two or more consecutive region lines are a
# run, and a run is reported when at least one of its lines is one this branch
# adds. So all three of these are one run:
#
#   // first line          /** a          code();  /* opened after code
#   // second line          * second      more();  */
#
# and none of these is a run, because neither line's content is only a comment:
#
#   const a = 1; // why    const b = 2; // why
#
# A blank line ends a run, because two comments separated by a blank line are
# two one-line comments. A blank line INSIDE a block comment does not, because
# the block is still one comment.
#
# LANGUAGE SCOPE, AND WHY IT STOPS WHERE IT DOES
# Handling a language correctly means lexing it: a `#` or `//` inside a string,
# a heredoc, or a template literal is not a comment, and treating one as a
# comment start desynchronizes the scan for the rest of the file. A regex that
# half works across five languages reports runs that are not there and misses
# ones that are, which is worse than not measuring a file at all.
#
#   MEASURED
#     JavaScript and TypeScript (.js .jsx .mjs .cjs .ts .tsx .mts .cts)
#       Full lexer: line comments, block comments including JSDoc, single and
#       double quoted strings, template literals with nested ${} interpolation,
#       and regex literals.
#     YAML (.yml .yaml)
#       `#` comments, with block scalars (`|`, `>`) and multi-line quoted
#       scalars excluded, so literal text that begins with `#` is not read as a
#       comment. YAML has no block comment, so a run there is consecutive
#       comment lines.
#
#   NOT MEASURED, DELIBERATELY
#     HCL and Terraform. Three comment forms (`#`, `//`, `/* */`) plus heredocs
#       and `${}` interpolation. A partial lexer would read heredoc bodies as
#       comments. Worth adding as its own lexer, not as a widened regex.
#     Shell. `#` is ambiguous inside parameter expansion (`${v#p}`, `$#`),
#       inside heredocs, and inside the quoted program text shell scripts embed
#       (the perl and awk in this repo's own bin/). Deciding those needs a shell
#       parser. Firstmate's own bin/*.sh convention is also a deliberate
#       multi-line header block, which this rule is not meant to reformat.
#     Everything else. Not implemented rather than guessed.
#
# An added file this script does not measure is NAMED on stderr with its
# extension, so the boundary is visible to the worker rather than silent. That
# note is on stderr and not stdout so a clean run still prints nothing to a
# caller reading stdout.
#
# WHERE IT ERRS, AND IN WHICH DIRECTION
# A false report costs a worker a look at a line that was fine. A false pass
# costs exactly what this script exists to prevent. So:
#   - Anything the lexer cannot finish - an unterminated block comment or
#     template literal at end of file, invalid UTF-8, a tab indenting YAML -
#     exits 2 naming the file and line, rather than reporting the file clean.
#   - A quote or regex literal that does not close on its own line is recovered
#     from by treating the character as ordinary text and rescanning the rest of
#     that line. Those constructs cannot span lines in either language, so the
#     opening was a misread; recovery is bounded to one line and can only cause
#     a missed comment, never an invented one. JSX prose such as `<p>don't</p>`
#     is the common case and must not become a parse failure.
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

PROJECT=
BASE=
HEAD=HEAD
PRINT_SCOPE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) [ "$#" -ge 2 ] || die "--project requires a value"; PROJECT=$2; shift 2 ;;
    --project=*) PROJECT=${1#--project=}; shift ;;
    --base) [ "$#" -ge 2 ] || die "--base requires a value"; BASE=$2; shift 2 ;;
    --base=*) BASE=${1#--base=}; shift ;;
    --head) [ "$#" -ge 2 ] || die "--head requires a value"; HEAD=$2; shift 2 ;;
    --head=*) HEAD=${1#--head=}; shift ;;
    --print-scope) PRINT_SCOPE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# The one owner of the language scope, answerable before any project or ref is known.
if [ "$PRINT_SCOPE" -eq 1 ]; then
  echo "language=javascript-typescript extensions=.cjs,.cts,.js,.jsx,.mjs,.mts,.ts,.tsx"
  echo "language=yaml extensions=.yaml,.yml"
  exit 0
fi

[ -n "$PROJECT" ] || die "--project <dir> is required"
[ -n "$BASE" ] || die "--base <ref> is required: there is nothing to measure without the branch this one will land on"
command -v perl >/dev/null 2>&1 || die "perl is required to lex the changed files"

PROJECT=$(fm_range_resolve_project "$PROJECT") || exit 2
fm_range_verify "$PROJECT" "$BASE" "$HEAD" || exit 2

HEAD_SHA=$(git -C "$PROJECT" rev-parse --verify --quiet "$HEAD^{commit}") ||
  die "head ref does not resolve in $PROJECT: $HEAD"

# lang_for_path <path>: the scanner for this file, or empty when its extension is out of scope.
lang_for_path() {
  case "$1" in
    *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.mts|*.cts) printf 'jsts\n' ;;
    *.yml|*.yaml) printf 'yaml\n' ;;
    *) printf '\n' ;;
  esac
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-comment-length.XXXXXX") || die "cannot create a working directory"
trap 'rm -rf "$WORK"' EXIT INT TERM

MANIFEST="$WORK/manifest"
: > "$MANIFEST"

SKIPPED_EXTS=""
MEASURED=0
INDEX=0

# Every changed file but the deleted ones, which have no head content and add no lines.
while IFS= read -r -d '' file; do
  [ -n "$file" ] || continue
  lang=$(lang_for_path "$file")
  if [ -z "$lang" ]; then
    case "$file" in
      *.*) ext=".${file##*.}" ;;
      *) ext="(no extension)" ;;
    esac
    case " $SKIPPED_EXTS " in
      *" $ext "*) : ;;
      *) SKIPPED_EXTS="$SKIPPED_EXTS $ext" ;;
    esac
    continue
  fi

  # This branch's added lines, as inclusive new-file line ranges.
  added=$(git -C "$PROJECT" diff --no-color --no-ext-diff -U0 "$BASE...$HEAD" -- "$file" | awk '
    /^@@/ {
      plus = $3
      sub(/^\+/, "", plus)
      split(plus, p, ",")
      start = p[1] + 0
      count = (2 in p) ? p[2] + 0 : 1
      if (count > 0) {
        printf "%s%d-%d", sep, start, start + count - 1
        sep = ","
      }
    }
  ') || die "git diff failed for $file in $PROJECT"
  [ -n "$added" ] || continue

  INDEX=$((INDEX + 1))
  src="$WORK/$INDEX.src"
  git -C "$PROJECT" show "$HEAD_SHA:$file" > "$src" 2>/dev/null ||
    die "cannot read $file at $HEAD in $PROJECT"

  printf '%s\t%s\t%s\t%s\0' "$lang" "$src" "$added" "$file" >> "$MANIFEST"
  MEASURED=$((MEASURED + 1))
done < <(git -C "$PROJECT" diff --name-only -z --diff-filter=d "$BASE...$HEAD")

if [ -n "$SKIPPED_EXTS" ]; then
  echo "note: not measured (outside this script's language scope, see --help):$SKIPPED_EXTS" >&2
fi

if [ "$MEASURED" -eq 0 ]; then
  exit 0
fi

# Built with `read -r -d ''` because a heredoc inside a command substitution breaks whole-file parsing under Bash 3.2 (tests/fm-brief.test.sh owns that class).
IFS= read -r -d '' SCAN_PERL <<'PERL_EOF' || true
use strict;
use warnings;
use Encode qw(decode FB_CROAK);

my ($manifest) = @ARGV;

# Records are NUL-terminated with tab-separated fields and the path LAST, so a tab or newline in a path cannot be read as a boundary.
open(my $mf, '<:raw', $manifest) or do {
    print "FATAL\t0\tcannot read the work manifest: $!\t\n";
    exit 2;
};

my $failed = 0;

# A `/` opens a regex only where a value may begin: after punctuation, or after one of the keywords a value may follow.
my %REGEX_KEYWORD = map { $_ => 1 }
    qw(return typeof case in of do else yield await delete void instanceof new throw);

sub regex_allowed {
    my ($sig, $word) = @_;
    return 1 if $sig eq '';
    return 1 if $sig eq 'w' && $REGEX_KEYWORD{$word};
    return 1 if $sig =~ /^[(,=:\[!&|?{;}+\-*%~^<>]$/;
    return 0;
}

# The closing quote of a JavaScript string on one line, honoring backslash escapes, or undef when it does not close there.
sub js_quote_end {
    my ($line, $from, $q) = @_;
    my $len = length($line);
    my $i = $from;
    while ($i < $len) {
        my $c = substr($line, $i, 1);
        if ($c eq "\\") { $i += 2; next }
        return $i if $c eq $q;
        $i++;
    }
    return undef;
}

# JavaScript and TypeScript. Returns per-line comment-region flags, plus a line and message when the lex could not finish.
sub scan_jsts {
    my ($lines) = @_;
    my $n = scalar @$lines;
    my @region = (0) x $n;
    my $state = 'code';
    my $block_start = 0;
    my $template_start = 0;
    my @tmpl_stack;
    my $last_sig = '';
    my $last_word = '';

    for (my $li = 0; $li < $n; $li++) {
        my $line = $lines->[$li];
        $line =~ s/\r\z//;
        my $len = length($line);
        my $i = 0;
        my $code_seen = 0;
        my $comment_seen = 0;
        my $opened_in_block = ($state eq 'block') ? 1 : 0;

        while ($i < $len) {
            if ($state eq 'block') {
                my $p = index($line, '*/', $i);
                $comment_seen = 1;
                if ($p >= 0) { $i = $p + 2; $state = 'code' }
                else { $i = $len }
                next;
            }
            if ($state eq 'template') {
                my $c = substr($line, $i, 1);
                if ($c eq "\\") { $code_seen = 1; $i += 2; next }
                if ($c eq '`') { $code_seen = 1; $state = 'code'; $i++; next }
                if ($c eq '$' && substr($line, $i + 1, 1) eq '{') {
                    push @tmpl_stack, 0;
                    $state = 'code';
                    $code_seen = 1;
                    $i += 2;
                    next;
                }
                $code_seen = 1 if $c !~ /\s/;
                $i++;
                next;
            }

            my $c = substr($line, $i, 1);
            if ($c =~ /\s/) { $i++; next }

            if ($c eq '/') {
                my $nx = substr($line, $i + 1, 1);
                if ($nx eq '/') { $comment_seen = 1; $i = $len; next }
                if ($nx eq '*') {
                    $state = 'block';
                    $block_start = $li + 1;
                    $comment_seen = 1;
                    $i += 2;
                    next;
                }
                if (regex_allowed($last_sig, $last_word)) {
                    pos($line) = $i;
                    if ($line =~ m{\G/(?:[^/\\\[]|\\.|\[(?:[^\]\\]|\\.)*\])+/[A-Za-z]*}gc) {
                        $code_seen = 1;
                        $last_sig = '/';
                        $last_word = '';
                        $i = pos($line);
                        next;
                    }
                }
                $code_seen = 1;
                $last_sig = '/';
                $last_word = '';
                $i++;
                next;
            }

            if ($c eq '"' || $c eq "'") {
                my $close = js_quote_end($line, $i + 1, $c);
                $code_seen = 1;
                $last_sig = $c;
                $last_word = '';
                # An unterminated quote was a misread, usually an apostrophe in JSX prose; step over it as text.
                $i = defined $close ? $close + 1 : $i + 1;
                next;
            }

            if ($c eq '`') {
                $state = 'template';
                $template_start = $li + 1;
                $code_seen = 1;
                $last_sig = '`';
                $last_word = '';
                $i++;
                next;
            }

            if ($c eq '{') {
                $tmpl_stack[-1]++ if @tmpl_stack;
                $code_seen = 1;
                $last_sig = '{';
                $last_word = '';
                $i++;
                next;
            }

            if ($c eq '}') {
                if (@tmpl_stack) {
                    if ($tmpl_stack[-1] == 0) {
                        pop @tmpl_stack;
                        $state = 'template';
                        $code_seen = 1;
                        $i++;
                        next;
                    }
                    $tmpl_stack[-1]--;
                }
                $code_seen = 1;
                $last_sig = '}';
                $last_word = '';
                $i++;
                next;
            }

            $code_seen = 1;
            if ($c =~ /[A-Za-z0-9_\$]/) {
                pos($line) = $i;
                $line =~ m/\G[A-Za-z0-9_\$]+/gc;
                $last_word = substr($line, $i, pos($line) - $i);
                $last_sig = 'w';
                $i = pos($line);
            } else {
                $last_sig = $c;
                $last_word = '';
                $i++;
            }
        }

        # A block comment covers every line it runs through, whatever else shares them.
        $region[$li] = 1 if $opened_in_block || $state eq 'block';
        $region[$li] = 1 if $comment_seen && !$code_seen;
    }

    return (\@region, $block_start, 'unterminated block comment') if $state eq 'block';
    return (\@region, $template_start, 'unterminated template literal')
        if $state eq 'template' || @tmpl_stack;
    return (\@region, 0, '');
}

# The closing quote of a YAML quoted scalar: single quotes escape by doubling, double quotes with a backslash.
sub yaml_quote_end {
    my ($line, $from, $q) = @_;
    my $len = length($line);
    my $i = $from;
    while ($i < $len) {
        my $c = substr($line, $i, 1);
        if ($q eq "'") {
            if ($c eq "'") {
                return $i if substr($line, $i + 1, 1) ne "'";
                $i += 2;
                next;
            }
            $i++;
            next;
        }
        if ($c eq "\\") { $i += 2; next }
        return $i if $c eq '"';
        $i++;
    }
    return undef;
}

# YAML has no block comment, so a region line is one whose only content is a `#` comment outside any block scalar or multi-line quoted scalar.
sub scan_yaml {
    my ($lines) = @_;
    my $n = scalar @$lines;
    my @region = (0) x $n;
    my $in_quote = '';
    my $quote_start = 0;
    my $in_block = 0;
    my $block_indent = 0;

    for (my $li = 0; $li < $n; $li++) {
        my $line = $lines->[$li];
        $line =~ s/\r\z//;
        my $len = length($line);
        my $i = 0;
        my $code_seen = 0;
        my $comment_seen = 0;
        my $code_end = $len;

        if ($in_quote ne '') {
            my $close = yaml_quote_end($line, 0, $in_quote);
            if (!defined $close) { next }
            $in_quote = '';
            $code_seen = 1;
            $i = $close + 1;
        } elsif ($in_block) {
            next if $line !~ /\S/;
            my ($ws) = $line =~ /^([ ]*)/;
            next if length($ws) > $block_indent;
            $in_block = 0;
        }

        if ($i == 0 && $line =~ /^[ ]*\t/) {
            return (\@region, $li + 1, 'the file indents with a tab, which YAML forbids');
        }

        while ($i < $len) {
            my $c = substr($line, $i, 1);
            if ($c =~ /[ \t]/) { $i++; next }

            if ($c eq '#') {
                my $prev = $i > 0 ? substr($line, $i - 1, 1) : '';
                if ($i == 0 || $prev =~ /[ \t]/) {
                    $comment_seen = 1;
                    $code_end = $i;
                    last;
                }
                $code_seen = 1;
                $i++;
                next;
            }

            if ($c eq '"' || $c eq "'") {
                # A quote opens a scalar only where one may begin; elsewhere it is an apostrophe in a plain scalar.
                my $prev = '';
                for (my $k = $i - 1; $k >= 0; $k--) {
                    my $pc = substr($line, $k, 1);
                    next if $pc =~ /[ \t]/;
                    $prev = $pc;
                    last;
                }
                if ($prev eq '' || $prev =~ /^[:,\[\{\-]$/) {
                    my $close = yaml_quote_end($line, $i + 1, $c);
                    $code_seen = 1;
                    if (defined $close) { $i = $close + 1; next }
                    $in_quote = $c;
                    $quote_start = $li + 1;
                    $i = $len;
                    next;
                }
                $code_seen = 1;
                $i++;
                next;
            }

            $code_seen = 1;
            $i++;
        }

        $region[$li] = 1 if $comment_seen && !$code_seen;

        # A block scalar's body is literal text: every following line indented deeper than the line that introduced it.
        if ($in_quote eq '' && !$in_block) {
            my $codepart = substr($line, 0, $code_end);
            $codepart =~ s/\s+\z//;
            if ($codepart =~ /(?:^|[\s:])[|>][0-9]*[-+]?\z/) {
                $in_block = 1;
                my ($ws) = $line =~ /^([ ]*)/;
                $block_indent = length($ws);
            }
        }
    }

    return (\@region, $quote_start, 'unterminated quoted scalar') if $in_quote ne '';
    return (\@region, 0, '');
}

{
    local $/ = "\0";
    while (my $rec = <$mf>) {
        chomp $rec;
        next if $rec eq '';
        my ($lang, $srcfile, $added, $path) = split(/\t/, $rec, 4);

        my @ranges;
        for my $r (split(/,/, $added)) {
            my ($a, $b) = split(/-/, $r, 2);
            push @ranges, [ $a + 0, $b + 0 ];
        }
        my %is_added;
        for my $r (@ranges) {
            $is_added{$_} = 1 for $r->[0] .. $r->[1];
        }

        my $bytes = '';
        if (open(my $fh, '<:raw', $srcfile)) {
            local $/;
            $bytes = <$fh>;
            close($fh);
            $bytes = '' unless defined $bytes;
        } else {
            print "FILEERR\t0\tcannot read the file content\t$path\n";
            $failed = 1;
            next;
        }

        my $text = eval { decode('UTF-8', $bytes, FB_CROAK) };
        if ($@) {
            print "FILEERR\t0\tnot valid UTF-8\t$path\n";
            $failed = 1;
            next;
        }

        $text =~ s/\r\n/\n/g;
        my @lines = split(/\n/, $text, -1);
        pop @lines if @lines && $lines[-1] eq '';

        my ($region, $errline, $errmsg) =
            $lang eq 'yaml' ? scan_yaml(\@lines) : scan_jsts(\@lines);

        if ($errmsg ne '') {
            print "FILEERR\t$errline\t$errmsg\t$path\n";
            $failed = 1;
            next;
        }

        my $n = scalar @lines;
        my $i = 0;
        while ($i < $n) {
            if (!$region->[$i]) { $i++; next }
            my $start = $i;
            $i++ while $i < $n && $region->[$i];
            my $end = $i - 1;
            if ($end > $start) {
                my $added_count = 0;
                for my $l ($start + 1 .. $end + 1) {
                    $added_count++ if $is_added{$l};
                }
                if ($added_count > 0) {
                    printf("RUN\t%d\t%d\t%d\t%s\n", $start + 1, $end + 1, $added_count, $path);
                }
            }
        }
    }
}

close($mf);
exit($failed ? 2 : 0);
PERL_EOF

SCAN_OUT=$(perl -e "$SCAN_PERL" -- "$MANIFEST")
SCAN_RC=$?

RUNS=0
ERRORS=0
REPORT=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  tag=${line%%$'\t'*}
  rest=${line#*$'\t'}
  case "$tag" in
    RUN)
      start=${rest%%$'\t'*}; rest=${rest#*$'\t'}
      end=${rest%%$'\t'*}; rest=${rest#*$'\t'}
      count=${rest%%$'\t'*}; path=${rest#*$'\t'}
      REPORT="$REPORT$(printf '%s:%s-%s  %s-line comment run (%s added)' \
        "$path" "$start" "$end" "$((end - start + 1))" "$count")
"
      RUNS=$((RUNS + 1))
      ;;
    FILEERR|FATAL)
      errline=${rest%%$'\t'*}; rest=${rest#*$'\t'}
      msg=${rest%%$'\t'*}; path=${rest#*$'\t'}
      if [ "$errline" = 0 ] || [ -z "$errline" ]; then
        echo "error: ${path:-the work manifest}: $msg" >&2
      else
        echo "error: $path:$errline: $msg" >&2
      fi
      ERRORS=$((ERRORS + 1))
      ;;
    *)
      die "unrecognized record from the comment scanner: $tag"
      ;;
  esac
done <<EOF
$SCAN_OUT
EOF

if [ "$ERRORS" -gt 0 ] || [ "$SCAN_RC" -ne 0 ]; then
  echo "error: the branch was NOT measured cleanly; fix the files named above and run this again" >&2
  exit 2
fi

if [ "$RUNS" -eq 0 ]; then
  exit 0
fi

printf '%s' "$REPORT" | sort
echo
echo "FAILED: $RUNS multi-line comment run(s) in lines this branch adds. Every comment must be one line."
echo "Collapse each one on the branch. Leave comments this branch did not add alone."
exit 1
