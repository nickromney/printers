#!/usr/bin/env bash
# shellcheck shell=bash
#
# Cyclomatic complexity for bash functions.
#
# McCabe's measure counts the linearly independent paths through a function:
# one for the straight line, plus one for every point the flow can branch. The
# number is a review prompt, not a verdict -- a function scoring 14 is telling
# you it holds fourteen paths a reader has to keep straight, and that a name is
# probably hiding in there.
#
# Function discovery and comment stripping are not reimplemented here.
# scripts/lib/mutation.sh already resolves function ranges and strips comments
# without being fooled by heredocs, `${var#prefix}` or a quoted hash, and a
# second parser would only drift from the first.
#
# Bash 3.2 compatible on purpose (macOS stock bash): no associative arrays,
# no mapfile, no namerefs.

# shellcheck source=scripts/lib/mutation.sh
. "${BASH_SOURCE[0]%/*}/mutation.sh"

# Branch keywords. `else` is absent deliberately: it introduces no new
# condition, it is the path an existing `if` already accounted for. `elif`
# does introduce one. `case` is counted through its arms, not its head.
_COMPLEXITY_KEYWORDS="if elif while until for"

# Written by complexity_blank_quoted; see the note on its definition.
COMPLEXITY_QUOTE=""
COMPLEXITY_BLANKED=""

# Blank the contents of quoted spans, preserving length so offsets still line
# up. Shell scripts here embed awk and sed programs as quoted arguments, and
# those programs have their own `for`, `if` and `||`. Counting them would
# measure the embedded language rather than the bash function holding it --
# scripts/lib/semver.sh scored 2 on the strength of a `for` belonging to an awk
# BEGIN block. Inflation like that is systematic in this repo, not incidental.
#
# The quote itself is kept, so a `case` arm written as 'x') still reads as an arm.
#
# Quote state carries between lines through COMPLEXITY_QUOTE, because the
# programs that matter here open on one line and close many lines later --
# scripts/lib/semver.sh opens an awk program on line 9 and the `for` that was
# being miscounted sits on line 15. So this writes its result to a global
# instead of printing it: a command substitution would run it in a subshell and
# discard the carried state.
complexity_blank_quoted() {
  local line="$1"
  local len=${#line}
  local i=0
  local out="" ch=""
  local quote="${COMPLEXITY_QUOTE}"

  while [ "${i}" -lt "${len}" ]; do
    ch="${line:${i}:1}"
    if [ -n "${quote}" ]; then
      if [ "${ch}" = "${quote}" ]; then
        quote=""
        out="${out}${ch}"
      elif [ "${ch}" = "\\" ] && [ "${quote}" = '"' ]; then
        # Escaped character inside double quotes: blank both halves.
        out="${out}  "
        i=$((i + 1))
      else
        out="${out} "
      fi
      i=$((i + 1))
      continue
    fi

    case "${ch}" in
      "'"|'"')
        quote="${ch}"
        out="${out}${ch}"
        ;;
      *)
        out="${out}${ch}"
        ;;
    esac
    i=$((i + 1))
  done

  COMPLEXITY_QUOTE="${quote}"
  COMPLEXITY_BLANKED="${out}"
}

# Count decision points on a line that has ALREADY been blanked and had its
# comment stripped. Private, because getting that wrong returns a plausible
# number rather than an error: an unblanked line silently counts whatever awk
# or sed program it carries, and a line still holding its comment counts a
# `# && something` remark. The public entry point below blanks for you, so the
# only callers that have to hold this contract live in this file.
_complexity_count_points() {
  local line="$1"
  local points=0
  local keyword="" pos=""

  for keyword in ${_COMPLEXITY_KEYWORDS}; do
    for pos in $(mutation_scan_plain "${line}" "${keyword}"); do
      if mutation_word_boundary_ok "${line}" "${pos}" "${#keyword}"; then
        points=$((points + 1))
      fi
    done
  done

  # `&&` and `||` each add a path, and neither can be confused for an
  # identifier, so they need no boundary check. A single `&` or `|` is a
  # pipeline or a background job, not a branch, and `mutation_scan_plain`
  # matching the two-character needle already excludes them.
  for pos in $(mutation_scan_plain "${line}" "&&"); do
    points=$((points + 1))
  done
  for pos in $(mutation_scan_plain "${line}" "||"); do
    points=$((points + 1))
  done

  # A case arm is a branch. Match `pattern)` at the end of a line, which is
  # how every arm in this repo is written, and skip `;;`-only and `esac`
  # lines. `(pattern)` with a leading paren is the same arm, one style apart.
  if [[ "${line}" =~ ^[[:space:]]*\(?[^\(\)]+\)[[:space:]]*$ ]] &&
    [[ ! "${line}" =~ ^[[:space:]]*(esac|\;\;)[[:space:]]*$ ]]; then
    points=$((points + 1))
  fi

  printf '%s\n' "${points}"
}

# Count decision points on one line of shell, blanking quoted spans first.
# Safe to call on raw source. Single-line use starts from whatever quote state
# is current, which for a standalone call is none.
complexity_line_points() {
  complexity_blank_quoted "$1"
  _complexity_count_points "${COMPLEXITY_BLANKED}"
}

# Cyclomatic complexity of the line range [start,end] of a file: one for the
# entry path, plus every decision point inside it.
complexity_score_range() {
  local file="$1"
  local start="$2"
  local end="$3"
  local score=1
  local lineno=0
  local line="" stripped=""

  COMPLEXITY_QUOTE=""
  COMPLEXITY_BLANKED=""

  while IFS= read -r line || [ -n "${line}" ]; do
    lineno=$((lineno + 1))
    if [ "${lineno}" -lt "${start}" ]; then
      continue
    fi
    if [ "${lineno}" -gt "${end}" ]; then
      break
    fi
    complexity_blank_quoted "${line}"
    stripped="$(mutation_strip_comment "${COMPLEXITY_BLANKED}")"
    score=$((score + $(_complexity_count_points "${stripped}")))
  done <"${file}"

  printf '%s\n' "${score}"
}

# Print `name<TAB>score<TAB>start<TAB>end` for every function in a file, in
# source order.
complexity_report_file() {
  local file="$1"
  local name="" start="" end="" score=""

  mutation_list_functions "${file}" | while IFS="${_MUTATION_TAB}" read -r name start end; do
    [ -n "${name}" ] || continue
    score="$(complexity_score_range "${file}" "${start}" "${end}")"
    printf '%s\t%s\t%s\t%s\n' "${name}" "${score}" "${start}" "${end}"
  done
}
