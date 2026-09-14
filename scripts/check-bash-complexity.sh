#!/usr/bin/env bash
set -euo pipefail
#
# Report cyclomatic complexity per bash function, highest first.
#
# The threshold is a conversation opener, not a build break. This is not wired
# into `make lint` on purpose: three functions in scripts/lib/ sit above the
# default today, and a gate that fails on arrival gets suppressed rather than
# fixed. Ratchet it down as functions get split.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/shell-cli.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/complexity.sh"

MAX_COMPLEXITY="${MAX_COMPLEXITY:-10}"
PATHS=()

# shellcheck disable=SC2329 # invoked by name through the shell_cli_* helpers
usage() {
  cat <<EOF
Usage: ${0##*/} [--max N] [--path PATH]... [--dry-run] [--execute]

Report cyclomatic complexity for every bash function in PATH, highest first.
Defaults to scripts/lib. Exits 1 when a function exceeds --max (default
${MAX_COMPLEXITY}).

$(shell_cli_standard_options)
EOF
}

shell_cli_init_standard_flags
while [[ $# -gt 0 ]]; do
  if shell_cli_handle_standard_flag usage "$1"; then
    shift
    continue
  fi
  case "$1" in
    --max)
      [[ $# -ge 2 ]] || { shell_cli_missing_value "$(shell_cli_script_name)" "--max"; exit 1; }
      MAX_COMPLEXITY="$2"
      shift 2
      ;;
    --path)
      [[ $# -ge 2 ]] || { shell_cli_missing_value "$(shell_cli_script_name)" "--path"; exit 1; }
      PATHS+=("$2")
      shift 2
      ;;
    *)
      shell_cli_unknown_flag "$(shell_cli_script_name)" "$1"
      exit 1
      ;;
  esac
done

preview() {
  # ${#PATHS[@]} not ${#PATHS[@]:-0}: the length form takes no default, and the
  # combination is a bad substitution rather than a fallback. It is safe on an
  # empty array under `set -u` even on bash 3.2, which "${PATHS[@]}" is not --
  # so the count is read here and the array only expanded once it is non-empty.
  shell_cli_print_dry_run_summary \
    "would report cyclomatic complexity above ${MAX_COMPLEXITY} for ${#PATHS[@]} path(s)"
}

main() {
  local file="" name="" score="" start=""
  local over=0
  local report=""

  if [[ "${#PATHS[@]}" -eq 0 ]]; then
    PATHS=("${REPO_ROOT}/hp")
  fi

  report="$(
    for file in $(find "${PATHS[@]}" -type f -name '*.sh' | LC_ALL=C sort); do
      complexity_report_file "${file}" |
        while IFS="$(printf '\t')" read -r name score start _; do
          [[ -n "${name}" ]] || continue
          printf '%s\t%s\t%s:%s\n' "${score}" "${name}" "${file#"${REPO_ROOT}/"}" "${start}"
        done
    done | LC_ALL=C sort -rn
  )"

  [[ -n "${report}" ]] || { echo "no bash functions found"; return 0; }

  printf '%s\n' "${report}" | while IFS="$(printf '\t')" read -r score name where; do
    printf '%4s  %-38s %s\n' "${score}" "${name}" "${where}"
  done

  over="$(printf '%s\n' "${report}" | awk -F'\t' -v max="${MAX_COMPLEXITY}" '$1 > max' | wc -l | tr -d ' ')"
  if [[ "${over}" -gt 0 ]]; then
    printf '\nFAIL %s function(s) above complexity %s\n' "${over}" "${MAX_COMPLEXITY}" >&2
    return 1
  fi
  printf '\nOK   no function above complexity %s\n' "${MAX_COMPLEXITY}"
}

shell_cli_maybe_execute_or_preview usage preview
main
