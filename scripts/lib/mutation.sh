#!/usr/bin/env bash
# shellcheck shell=bash
#
# Mutation testing engine for bash functions: pure generation and parsing
# helpers. Applying mutants to the working tree and running test suites lives
# in scripts/mutation-test.sh.
#
# Bash 3.2 compatible on purpose (macOS stock bash): no associative arrays,
# no mapfile, no namerefs, no case-modification expansions.

_MUTATION_TAB="$(printf '\t')"

# Print the line truncated at the start of an unquoted comment, if any.
# A '#' opens a comment only at a word boundary, so ${var#prefix} and $#
# survive; quoted hashes survive too.
mutation_strip_comment() {
  local line="$1"
  local len=${#line}
  local i=0
  local ch="" prev="" quote=""

  while [ "${i}" -lt "${len}" ]; do
    ch="${line:${i}:1}"
    if [ -n "${quote}" ]; then
      if [ "${quote}" = "'" ]; then
        if [ "${ch}" = "'" ]; then
          quote=""
        fi
        i=$((i + 1))
        continue
      fi
      if [ "${ch}" = "\\" ]; then
        i=$((i + 2))
        continue
      fi
      if [ "${ch}" = '"' ]; then
        quote=""
      fi
      i=$((i + 1))
      continue
    fi

    case "${ch}" in
      "'"|'"')
        quote="${ch}"
        ;;
      "\\")
        i=$((i + 2))
        continue
        ;;
      '#')
        if [ -z "${prev}" ] || [ "${prev}" = " " ] || [ "${prev}" = "${_MUTATION_TAB}" ]; then
          printf '%s\n' "${line:0:${i}}"
          return 0
        fi
        ;;
    esac
    prev="${ch}"
    i=$((i + 1))
  done

  printf '%s\n' "${line}"
}

# Print the 0-based offset of every literal occurrence of needle in hay,
# one per line, left to right.
mutation_scan_plain() {
  local hay="$1"
  local needle="$2"
  local off=0
  local rest="" trimmed=""

  [ -n "${needle}" ] || return 0
  while :; do
    rest="${hay:${off}}"
    [ -n "${rest}" ] || return 0
    trimmed="${rest#*"${needle}"}"
    if [ "${trimmed}" = "${rest}" ]; then
      return 0
    fi
    printf '%s\n' $((off + ${#rest} - ${#trimmed} - ${#needle}))
    off=$((off + ${#rest} - ${#trimmed}))
  done
}

# Succeed when the token at pos..pos+len in hay has non-word neighbors.
mutation_word_boundary_ok() {
  local hay="$1"
  local pos="$2"
  local len="$3"
  local before="" after=""

  if [ "${pos}" -gt 0 ]; then
    before="${hay:$((pos - 1)):1}"
    if [ -n "${before}" ] && [[ "${before}" =~ [A-Za-z0-9_-] ]]; then
      return 1
    fi
  fi
  after="${hay:$((pos + len)):1}"
  if [ -n "${after}" ] && [[ "${after}" =~ [A-Za-z0-9_] ]]; then
    return 1
  fi
  return 0
}

# Append "op<TAB>mutated_line" records to MUTATION_RECORDS for every
# occurrence of `from`, replaced one at a time by `to`. mode is plain|word.
mutation_emit_swaps() {
  local line="$1"
  local from="$2"
  local to="$3"
  local op="$4"
  local mode="${5:-plain}"
  local off=0
  local rest="" trimmed="" mutant=""
  local rel=0 pos=0

  [ -n "${from}" ] || return 0
  while :; do
    rest="${line:${off}}"
    [ -n "${rest}" ] || return 0
    trimmed="${rest#*"${from}"}"
    if [ "${trimmed}" = "${rest}" ]; then
      return 0
    fi
    rel=$((${#rest} - ${#trimmed} - ${#from}))
    pos=$((off + rel))
    if [ "${mode}" = "word" ]; then
      if ! mutation_word_boundary_ok "${line}" "${pos}" "${#from}"; then
        off=$((pos + ${#from}))
        continue
      fi
    fi
    mutant="${line:0:${pos}}${to}${line:$((pos + ${#from}))}"
    MUTATION_RECORDS="${MUTATION_RECORDS}${op}"$'\t'"${mutant}"$'\n'
    off=$((pos + ${#from}))
  done
}

# Append NEGATION_DROP records deleting each standalone '!' token.
mutation_emit_negation_drops() {
  local line="$1"
  local off=0
  local rest="" trimmed="" before="" after=""
  local rel=0 pos=0 nxt=0

  while :; do
    rest="${line:${off}}"
    [ -n "${rest}" ] || return 0
    trimmed="${rest#*'!'}"
    if [ "${trimmed}" = "${rest}" ]; then
      return 0
    fi
    rel=$((${#rest} - ${#trimmed} - 1))
    pos=$((off + rel))
    nxt=$((pos + 1))
    if [ "${pos}" -gt 0 ]; then
      before="${line:$((pos - 1)):1}"
    fi
    after="${line:${nxt}:1}"
    if { [ -z "${before}" ] || [ "${before}" = " " ] || [ "${before}" = "${_MUTATION_TAB}" ]; } \
      && { [ -z "${after}" ] || [ "${after}" = " " ] || [ "${after}" = "${_MUTATION_TAB}" ]; }; then
      MUTATION_RECORDS="${MUTATION_RECORDS}NEGATION_DROP"$'\t'"${line:0:${pos}}${line:${nxt}}"$'\n'
    fi
    off=$((pos + 1))
  done
}

mutation_heredoc_tag() {
  local line="$1"
  local pos="" rest="" tag="" quote=""

  pos="$(mutation_scan_plain "${line}" '<<' | head -n 1)"
  [ -n "${pos}" ] || return 0
  case "${line:${pos}:3}" in
    '<<<') return 0 ;;
  esac
  rest="${line:$((pos + 2))}"
  local dash="nodash"
  case "${rest}" in
    '-'*)
      dash="dash"
      rest="${rest#-}"
      ;;
  esac
  case "${rest}" in
    "'"*)
      quote="'"
      rest="${rest#\'}"
      ;;
    '"'*)
      quote='"'
      rest="${rest#\"}"
      ;;
  esac
  tag=""
  local len=${#rest}
  local i=0 ch=""
  while [ "${i}" -lt "${len}" ]; do
    ch="${rest:${i}:1}"
    if [ -n "${quote}" ]; then
      if [ "${ch}" = "${quote}" ]; then
        break
      fi
    else
      case "${ch}" in
        ""|" "|"${_MUTATION_TAB}"|";"|"&"|"|"|"("|")"|"<"|">"|"'"|'"') break ;;
      esac
    fi
    tag="${tag}${ch}"
    i=$((i + 1))
  done
  [ -n "${tag}" ] || return 0
  printf '%s\t%s\n' "${tag}" "${dash}"
}

# Emit "name<TAB>start<TAB>end" for every top-level function in file.
# Recognizes `name() {` and `function name {` with the brace on the same or
# next line. Heredoc bodies are skipped so a lone `}` inside them does not
# close a function early. Nested function definitions are treated as body.
mutation_list_functions() {
  local file="$1"
  local lineno=0
  local line="" candidate=""
  local in_heredoc=0 heredoc_tag="" heredoc_dash=""
  local cur_name="" cur_start=0 pend_name="" pend_line=0
  local fn_re='^[[:space:]]*(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\([[:space:]]*\)([[:space:]]*\{)?[[:space:]]*$'
  local open_re='^[[:space:]]*\{[[:space:]]*$'
  local close_re='^[[:space:]]*\}[[:space:]]*$'

  while IFS= read -r line || [ -n "${line}" ]; do
    lineno=$((lineno + 1))

    if [ "${in_heredoc}" -eq 1 ]; then
      candidate="${line}"
      if [ "${heredoc_dash}" = "dash" ]; then
        candidate="${candidate#"${candidate%%[!"${_MUTATION_TAB}"]*}"}"
      fi
      if [ "${candidate}" = "${heredoc_tag}" ]; then
        in_heredoc=0
      fi
      continue
    fi

    if [ -z "${cur_name}" ]; then
      if [[ "${line}" =~ ${fn_re} ]]; then
        cur_name="${BASH_REMATCH[2]}"
        cur_start="${lineno}"
        if [ -z "${BASH_REMATCH[3]}" ]; then
          pend_name="${cur_name}"
          pend_line="${lineno}"
          cur_name=""
        fi
      elif [ -n "${pend_name}" ] && [[ "${line}" =~ ${open_re} ]]; then
        cur_name="${pend_name}"
        cur_start="${pend_line}"
        pend_name=""
      fi
      if [ -n "${cur_name}" ] || [ -n "${pend_name}" ]; then
        continue
      fi
    elif [[ "${line}" =~ ${close_re} ]]; then
      printf '%s\t%s\t%s\n' "${cur_name}" "${cur_start}" "${lineno}"
      cur_name=""
      cur_start=0
      continue
    fi

    local tag_record=""
    tag_record="$(mutation_heredoc_tag "${line}")"
    if [ -n "${tag_record}" ]; then
      heredoc_tag="${tag_record%%$'\t'*}"
      heredoc_dash="${tag_record##*$'\t'}"
      in_heredoc=1
    fi
  done <"${file}"
}

# Print deduped "op<TAB>mutated_line" records for every mutation site on the
# given line. Comment-only lines yield nothing.
mutation_generate_line_mutants() {
  local line
  line="$(mutation_strip_comment "$1")"
  local stripped="${line//" "/}"
  stripped="${stripped//"${_MUTATION_TAB}"/}"
  [ -n "${stripped}" ] || return 0

  MUTATION_RECORDS=""
  mutation_emit_swaps "${line}" '&&' '||' LOGICAL_AND_OR plain
  mutation_emit_swaps "${line}" '||' '&&' LOGICAL_AND_OR plain
  mutation_emit_swaps "${line}" '-eq' '-ne' NUMERIC_COMPARE word
  mutation_emit_swaps "${line}" '-ne' '-eq' NUMERIC_COMPARE word
  mutation_emit_swaps "${line}" '-lt' '-le' BOUNDARY_CHECK word
  mutation_emit_swaps "${line}" '-le' '-lt' BOUNDARY_CHECK word
  mutation_emit_swaps "${line}" '-gt' '-ge' BOUNDARY_CHECK word
  mutation_emit_swaps "${line}" '-ge' '-gt' BOUNDARY_CHECK word
  mutation_emit_swaps "${line}" '==' '!=' STRING_COMPARE plain
  mutation_emit_swaps "${line}" '!=' '==' STRING_COMPARE plain
  mutation_emit_swaps "${line}" 'true' 'false' BOOLEAN_LITERAL word
  mutation_emit_swaps "${line}" 'false' 'true' BOOLEAN_LITERAL word
  mutation_emit_swaps "${line}" 'return 0' 'return 1' RETURN_CODE word
  mutation_emit_swaps "${line}" 'return 1' 'return 0' RETURN_CODE word
  mutation_emit_swaps "${line}" '++)' '--)' ARITH_STEP plain
  mutation_emit_swaps "${line}" '--)' '++)' ARITH_STEP plain
  mutation_emit_negation_drops "${line}"

  [ -n "${MUTATION_RECORDS}" ] || return 0
  printf '%s' "${MUTATION_RECORDS}" | awk '!seen[$0]++'
}

# Every valid mutant must be recorded exactly once, as killed or as survived.
# Returns non-zero when the books do not balance, so the caller can refuse to
# report a score rather than compute one from whatever the files happen to hold.
#
# A real run reported "72 valid mutants, 16 killed, 6 survived": 22 accounted
# for, 50 silently dropped, and a percentage derived from the 22 as though it
# were the whole run. A wrong score is worse than no score here, because the
# question being asked is whether the assertions bite.
mutation_counts_reconcile() {
  local killed="$1"
  local survived="$2"
  local valid="$3"

  [ "$((killed + survived))" -eq "${valid}" ]
}
