#!/usr/bin/env bash
set -euo pipefail

# Mutation testing runner for one bash script against its mapped bats suites.
#
# For every generated mutant: swap it over the working-tree file, run the
# suite, restore immediately. INT and TERM restore and then exit; a plain EXIT
# trap restores as the shell leaves.
#
# This comment used to promise that "a killed run cannot leave a mutated script
# behind". It cannot promise that, and it no longer tries. SIGKILL runs no trap
# at all, by design and in any program, so a hard kill mid-mutant leaves the
# mutant on disk. What the traps buy is that INT and TERM stop the run instead
# of restoring one file and mutating the next -- which is what they used to do.
# If a run is killed hard, diff the target before trusting it.
#
# A mutant is killed when the suite fails or times out. Survivors are listed
# with their diff so weak assertions can be strengthened where they are weak.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable so a run can be pointed at another checkout and keep its
# bookkeeping there. Left unset this resolves to the runner's own repo, which is
# what put a cross-repo run's killed.tsv and survived.tsv under this one.
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/shell-cli.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/mutation.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/timeout.sh"

usage() {
  cat <<'EOF' | sed "s|@SCRIPT_NAME@|${0##*/}|g"
Usage: @SCRIPT_NAME@ --script PATH [--bats PATH]... [--timeout SECONDS]
                    [--max-mutants N] [--report-dir DIR] [--no-fail]

Generate bash mutants for exactly one script and run its mapped bats suites
against each mutant. Mutations are applied to the working-tree file one at a
time and restored after every run.

Mutation operators:
  LOGICAL_AND_OR    && <-> ||
  NUMERIC_COMPARE   -eq <-> -ne
  BOUNDARY_CHECK    -lt <-> -le, -gt <-> -ge
  STRING_COMPARE    == <-> !=
  BOOLEAN_LITERAL   true <-> false
  RETURN_CODE       return 0 <-> return 1
  NEGATION_DROP     standalone ! removed
  ARITH_STEP        ++ <-> --

Options:
  --script PATH     Script to mutate (required, exactly one)
  --bats PATH       Bats suite to run as the oracle; repeatable. Defaults to
                    tests/<script-stem>*.bats under the repo root
  --timeout SECONDS Per-suite timeout, a timeout counts as killed (default 60)
  --max-mutants N   Safety cap on generated mutants (default 400)
  --report-dir DIR  Work and report directory (default .run/mutation/<stem>)
  --no-fail         Exit 0 even when mutants survive
  --dry-run         Generate and summarize mutants without running suites
  --execute         Run the mutation cycle
  -h, --help        Show this message
EOF
}

SCRIPT_ARG=""
REPORT_DIR_ARG=""
TIMEOUT_SECS=60
MAX_MUTANTS=400
NO_FAIL=0
declare -a BATS_ARGS=()

TARGET=""
TARGET_REL=""
STEM=""
WORKDIR=""
BACKUP=""
SOURCE=""
declare -a SUITES=()

die() {
  printf '%s: %s\n' "$(shell_cli_script_name)" "$1" >&2
  exit 2
}

resolve_path() {
  local p="$1"
  if [ -f "${p}" ]; then
    printf '%s\n' "${p}"
    return 0
  fi
  if [ -f "${REPO_ROOT}/${p}" ]; then
    printf '%s\n' "${REPO_ROOT}/${p}"
    return 0
  fi
  return 1
}

discover_suites() {
  local candidate
  declare -a discovered=()
  for candidate in "${REPO_ROOT}"/tests/"${STEM}"*.bats; do
    [ -f "${candidate}" ] || continue
    discovered+=("${candidate}")
  done
  if [ "${#discovered[@]}" -eq 0 ]; then
    return 1
  fi
  SUITES=("${discovered[@]}")
}

resolve_inputs() {
  [ -n "${SCRIPT_ARG}" ] || die "--script is required (exactly one)"
  TARGET="$(resolve_path "${SCRIPT_ARG}")" || die "no such script: ${SCRIPT_ARG}"
  TARGET_REL="${TARGET#"${REPO_ROOT}/"}"
  STEM="$(basename "${TARGET}")"
  STEM="${STEM%.sh}"

  if [ "${#BATS_ARGS[@]}" -eq 0 ]; then
    discover_suites || die "no tests/${STEM}*.bats match; pass --bats explicitly"
  else
    local suite
    declare -a resolved=()
    for suite in "${BATS_ARGS[@]}"; do
      resolve_path "${suite}" >/dev/null || die "no such bats file: ${suite}"
      resolved+=("$(resolve_path "${suite}")")
    done
    SUITES=("${resolved[@]}")
  fi

  WORKDIR="${REPORT_DIR_ARG:-${REPO_ROOT}/.run/mutation/${STEM}}"
  BACKUP="${WORKDIR}/orig.sh"
  SOURCE="${WORKDIR}/source.sh"
}

suite_label() {
  local suite
  local out=""
  for suite in "${SUITES[@]}"; do
    out="${out}${out:+ }${suite#"${REPO_ROOT}/"}"
  done
  printf '%s\n' "${out}"
}

generate_mutants() {
  mkdir -p "${WORKDIR}/mutants"
  cp "${TARGET}" "${BACKUP}"
  cp "${BACKUP}" "${SOURCE}"

  : >"${WORKDIR}/seen.tsv"
  : >"${WORKDIR}/manifest.tsv"
  mutation_list_functions "${SOURCE}" >"${WORKDIR}/functions.tsv"

  local lineno=0 id=0 in_heredoc=0
  local line="" candidate="" tag_record="" heredoc_tag="" heredoc_dash=""
  local func=""

  # Body only writes mutants/, manifests, and stats; SOURCE is read-only.
  # shellcheck disable=SC2094
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

    func="$(awk -F'\t' -v ln="${lineno}" '$2 <= ln && ln <= $3 {print $1; exit}' \
      "${WORKDIR}/functions.tsv")"
    [ -n "${func}" ] || func="(top-level)"

    while IFS=$'\t' read -r op mutated; do
      [ -n "${op}" ] || continue
      if grep -Fqx "${func}"$'\t'"${mutated}" "${WORKDIR}/seen.tsv"; then
        continue
      fi
      if [ "${id}" -ge "${MAX_MUTANTS}" ]; then
        printf '%s: mutant cap %s reached; raising --max-mutants\n' \
          "$(shell_cli_script_name)" "${MAX_MUTANTS}" >&2
        break 2
      fi
      id=$((id + 1))
      local mutant_id
      mutant_id="$(printf '%04d' "${id}")"
      # Reads the pristine copy; writes a distinct mutants/<id>.sh file.
      # shellcheck disable=SC2094
      awk -v ln="${lineno}" -v repl="${mutated}" \
        'NR == ln { print repl; next } { print }' \
        "${SOURCE}" >"${WORKDIR}/mutants/${mutant_id}.sh" ||
        die "failed to write mutant ${mutant_id}"
      printf '%s\n' "${mutated}" >"${WORKDIR}/mutants/${mutant_id}.line"
      printf '%s\t%s\t%s\t%s\n' "${mutant_id}" "${func}" "${lineno}" "${op}" \
        >>"${WORKDIR}/manifest.tsv"
      printf '%s\t%s\n' "${func}" "${mutated}" >>"${WORKDIR}/seen.tsv"
    done < <(mutation_generate_line_mutants "${line}")

    tag_record="$(mutation_heredoc_tag "${line}")"
    if [ -n "${tag_record}" ]; then
      heredoc_tag="${tag_record%%$'\t'*}"
      heredoc_dash="${tag_record##*$'\t'}"
      in_heredoc=1
    fi
  done <"${SOURCE}"

  printf '%s\n' "${id}"
}

filter_invalid_mutants() {
  : >"${WORKDIR}/valid_ids.txt"
  : >"${WORKDIR}/invalid.tsv"
  local id func lineno op
  while IFS=$'\t' read -r id func lineno op; do
    [ -n "${id}" ] || continue
    if bash -n "${WORKDIR}/mutants/${id}.sh" 2>/dev/null; then
      printf '%s\n' "${id}" >>"${WORKDIR}/valid_ids.txt"
    else
      printf '%s\t%s\n' "${func}" "${id}" >>"${WORKDIR}/invalid.tsv"
    fi
  done <"${WORKDIR}/manifest.tsv"
}

count_for() {
  local func="$1"
  local file="$2"
  awk -F'\t' -v f="${func}" '$1 == f' "${file}" 2>/dev/null | wc -l | tr -d ' '
}

restore_target() {
  if [ -f "${BACKUP:-}" ] && [ -f "${TARGET:-}" ] && ! cmp -s "${TARGET}" "${BACKUP}"; then
    cp "${BACKUP}" "${TARGET}"
    printf '%s: restored %s\n' "$(shell_cli_script_name)" "${TARGET_REL}" >&2
  fi
}

# Restoring is not aborting, and the mutation loop needs both.
#
# restore_target returns, so a trap that only calls it hands control straight
# back to the `while read id` loop, which copies the next mutant over the target
# and carries on. Signalling a run therefore did nothing at all: measured on this
# repo, SIGTERM after four mutants was followed by seven more and the run went to
# completion. Whatever kills it for real then lands with a mutant on disk --
# TERM followed by KILL three seconds later, which is what a supervisor or a tool
# timeout does, left `[[ -n "${raw}" ]] || return 1` flipped to `&& return 1` in
# scripts/lib/host-port-listeners.sh.
#
# So INT and TERM restore and then exit; EXIT stays a plain restore hook, since
# by then the shell is already leaving. 130 is the conventional SIGINT status.
on_interrupt() {
  restore_target
  exit 130
}

run_suite() {
  # MUTATION_BATS_FLAGS is split on purpose, e.g. "--jobs 8".
  # shellcheck disable=SC2086
  run_with_timeout "${TIMEOUT_SECS}" bats ${MUTATION_BATS_FLAGS:-} ${SUITES[@]+"${SUITES[@]}"} \
    >"${WORKDIR}/run.log" 2>&1
}

preview_plan() {
  if [ -z "${SCRIPT_ARG}" ]; then
    shell_cli_print_dry_run_summary \
      "would plan bash mutants for one script against its mapped bats suites; pass --script PATH"
    return 0
  fi
  resolve_inputs
  rm -rf "${WORKDIR}"
  local total
  total="$(generate_mutants)"
  filter_invalid_mutants
  local valid
  valid="$(wc -l <"${WORKDIR}/valid_ids.txt" | tr -d ' ')"
  local invalid
  invalid="$(wc -l <"${WORKDIR}/invalid.tsv" | tr -d ' ')"

  printf 'Mutation plan for %s\n' "${TARGET_REL}"
  printf '  suites:   %s\n' "$(suite_label)"
  printf '  workdir:  %s\n' "${WORKDIR#"${REPO_ROOT}/"}"
  printf 'INFO dry-run: %s mutants total, %s valid, %s invalid (syntax); re-run with --execute to kill them\n' \
    "${total}" "${valid}" "${invalid}"
}

report_survivors() {
  local id func before after
  local rline="" rop=""
  while IFS=$'\t' read -r func id; do
    [ -n "${id}" ] || continue
    IFS=$'\t' read -r _ _ rline rop \
      < <(awk -F'\t' -v i="${id}" '$1 == i' "${WORKDIR}/manifest.tsv")
    before="$(sed -n "${rline}p" "${BACKUP}")"
    after="$(cat "${WORKDIR}/mutants/${id}.line")"
    printf '  SURVIVED %-16s %s:%s\n' "${rop}" "${TARGET_REL}" "${rline}"
    printf '    - %s\n' "${before}"
    printf '    + %s\n' "${after}"
  done <"${WORKDIR}/survived.tsv"
}

write_report() {
  local out="$1"
  local total_killed total_survived total_invalid
  total_killed="$(wc -l <"${WORKDIR}/killed.tsv" | tr -d ' ')"
  total_survived="$(wc -l <"${WORKDIR}/survived.tsv" | tr -d ' ')"
  total_invalid="$(wc -l <"${WORKDIR}/invalid.tsv" | tr -d ' ')"

  {
    printf '# Mutation report: %s\n\n' "${TARGET_REL}"
    printf 'Suites: %s\n\n' "$(suite_label)"
    printf '| Function | Killed | Survived | Invalid | Score |\n'
    printf '|---|---|---|---|---|\n'

    local func k s i score
    while IFS=$'\t' read -r func _start _end; do
      [ -n "${func}" ] || continue
      k="$(count_for "${func}" "${WORKDIR}/killed.tsv")"
      s="$(count_for "${func}" "${WORKDIR}/survived.tsv")"
      i="$(count_for "${func}" "${WORKDIR}/invalid.tsv")"
      if [ "$((k + s))" -eq 0 ]; then
        score="n/a"
      else
        score="$(awk -v k="${k}" -v s="${s}" 'BEGIN{printf "%d%%", (k * 100) / (k + s)}')"
      fi
      printf '| %s | %s | %s | %s | %s |\n' "${func}" "${k}" "${s}" "${i}" "${score}"
    done <"${WORKDIR}/functions.tsv"

    k="$(count_for "(top-level)" "${WORKDIR}/killed.tsv")"
    s="$(count_for "(top-level)" "${WORKDIR}/survived.tsv")"
    i="$(count_for "(top-level)" "${WORKDIR}/invalid.tsv")"
    if [ "$((k + s))" -gt 0 ]; then
      score="$(awk -v k="${k}" -v s="${s}" 'BEGIN{printf "%d%%", (k * 100) / (k + s)}')"
      printf '| (top-level) | %s | %s | %s | %s |\n' "${k}" "${s}" "${i}" "${score}"
    fi

    if [ "$((total_killed + total_survived))" -eq 0 ]; then
      score="n/a"
    else
      score="$(awk -v k="${total_killed}" -v s="${total_survived}" \
        'BEGIN{printf "%d%%", (k * 100) / (k + s)}')"
    fi
    printf '\nOverall: %s killed, %s survived, %s invalid; mutation score %s.\n' \
      "${total_killed}" "${total_survived}" "${total_invalid}" "${score}"
    printf 'Timeouts count as killed. Syntax-invalid mutants are excluded from the score.\n'
  } >"${out}"
}

execute_run() {
  resolve_inputs
  rm -rf "${WORKDIR}"
  mkdir -p "${WORKDIR}"

  local total
  total="$(generate_mutants)"
  filter_invalid_mutants
  local valid
  valid="$(wc -l <"${WORKDIR}/valid_ids.txt" | tr -d ' ')"

  if [ "${valid}" -eq 0 ]; then
    printf 'No valid mutants generated for %s; nothing to test.\n' "${TARGET_REL}"
    return 0
  fi

  printf 'Baseline suite run...\n'
  if ! run_suite; then
    sed -n '1,40p' "${WORKDIR}/run.log" >&2
    restore_target
    die "baseline suite fails on unmutated ${TARGET_REL}; fix tests before mutating"
  fi

  : >"${WORKDIR}/killed.tsv"
  : >"${WORKDIR}/survived.tsv"
  trap restore_target EXIT
  trap on_interrupt INT TERM

  local started
  started="$(date +%s)"
  local id rc safe_func
  while IFS= read -r id; do
    [ -n "${id}" ] || continue
    cp "${WORKDIR}/mutants/${id}.sh" "${TARGET}"
    rc=0
    run_suite || rc=$?
    cp "${BACKUP}" "${TARGET}"
    safe_func="$(awk -F'\t' -v i="${id}" '$1 == i {print $2}' "${WORKDIR}/manifest.tsv")"
    if [ "${rc}" -eq 0 ]; then
      printf '%s\t%s\n' "${safe_func}" "${id}" >>"${WORKDIR}/survived.tsv"
      printf '  %s SURVIVED\n' "${id}"
    else
      printf '%s\t%s\n' "${safe_func}" "${id}" >>"${WORKDIR}/killed.tsv"
      if [ "${rc}" -eq 124 ]; then
        printf '  %s killed (timeout)\n' "${id}"
      else
        printf '  %s killed\n' "${id}"
      fi
    fi
  done <"${WORKDIR}/valid_ids.txt"
  trap - EXIT INT TERM

  if ! cmp -s "${TARGET}" "${BACKUP}"; then
    restore_target
    die "target did not match backup after run; restored original"
  fi

  # Every valid mutant must have been recorded exactly once, as killed or as
  # survived. Without this the score is computed from whatever the two files
  # happen to hold and is printed with no indication that anything is missing:
  # a real run reported "72 valid mutants, 16 killed, 6 survived" -- 22
  # accounted for, 50 silently dropped -- and a score derived from the 22 as
  # though it were the whole run. A wrong score is worse than no score here,
  # because the entire question being asked is whether the assertions bite.
  #
  # Concurrent runs sharing a report directory are one way to get here:
  # killed.tsv and survived.tsv are truncated at the start of the loop, so a
  # second run resets the first one's bookkeeping underneath it. That needs the
  # same --report-dir, which for the default means the same script stem, since
  # the default is .run/mutation/<stem>. Cross-repo runs collide most easily,
  # because REPO_ROOT decides whose .run/ is used.
  local recorded_killed recorded_survived expected_valid
  recorded_killed="$(wc -l <"${WORKDIR}/killed.tsv" | tr -d ' ')"
  recorded_survived="$(wc -l <"${WORKDIR}/survived.tsv" | tr -d ' ')"
  expected_valid="$(wc -l <"${WORKDIR}/valid_ids.txt" | tr -d ' ')"
  if ! mutation_counts_reconcile "${recorded_killed}" "${recorded_survived}" "${expected_valid}"; then
    die "bookkeeping does not reconcile: ${expected_valid} valid mutant(s) but $((recorded_killed + recorded_survived)) recorded (${recorded_killed} killed, ${recorded_survived} survived) in ${WORKDIR}. Refusing to report a score from partial results; a concurrent run sharing this report directory is the usual cause."
  fi

  local elapsed=$(( $(date +%s) - started ))
  local report="${WORKDIR}/report.md"
  write_report "${report}"

  local survived
  survived="$(wc -l <"${WORKDIR}/survived.tsv" | tr -d ' ')"
  printf '\nDone in %ss: %s valid mutants, %s killed, %s survived.\n' \
    "${elapsed}" "${valid}" "$(wc -l <"${WORKDIR}/killed.tsv" | tr -d ' ')" "${survived}"
  if [ "${survived}" -gt 0 ]; then
    report_survivors
  fi
  printf 'Report: %s\n' "${report#"${REPO_ROOT}/"}"

  if [ "${survived}" -gt 0 ] && [ "${NO_FAIL}" -ne 1 ]; then
    exit 1
  fi
}

require_value() {
  local flag="$1"
  shift
  [ $# -gt 0 ] || {
    shell_cli_missing_value "$(shell_cli_script_name)" "${flag}" >&2
    exit 1
  }
}

is_positive_int() {
  [[ "${1}" =~ ^[1-9][0-9]*$ ]]
}

main() {
  shell_cli_init_standard_flags
  while [ $# -gt 0 ]; do
    if shell_cli_handle_standard_flag usage "$1"; then
      shift
      continue
    fi
    case "$1" in
      --script)
        require_value "$1" "$@"
        shift
        SCRIPT_ARG="$1"
        ;;
      --bats)
        require_value "$1" "$@"
        shift
        BATS_ARGS+=("$1")
        ;;
      --timeout)
        require_value "$1" "$@"
        shift
        is_positive_int "$1" || die "--timeout wants a positive integer, got: $1"
        TIMEOUT_SECS="$1"
        ;;
      --max-mutants)
        require_value "$1" "$@"
        shift
        is_positive_int "$1" || die "--max-mutants wants a positive integer, got: $1"
        [ "$1" -le 9999 ] || die "--max-mutants caps at 9999"
        MAX_MUTANTS="$1"
        ;;
      --report-dir)
        require_value "$1" "$@"
        shift
        REPORT_DIR_ARG="$1"
        ;;
      --no-fail)
        NO_FAIL=1
        ;;
      --)
        shift
        break
        ;;
      -*)
        shell_cli_unknown_flag "$(shell_cli_script_name)" "$1"
        exit 1
        ;;
      *)
        shell_cli_unexpected_arg "$(shell_cli_script_name)" "$1"
        exit 1
        ;;
    esac
    shift
  done
  [ $# -eq 0 ] || {
    shell_cli_unexpected_arg "$(shell_cli_script_name)" "$1"
    exit 1
  }

  shell_cli_maybe_execute_or_preview usage preview_plan
  execute_run
}

main "$@"
