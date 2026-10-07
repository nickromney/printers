#!/usr/bin/env bash
# lucky.sh — "I'm feeling lucky"
#
# Auto-diagnoses your printer, fixes problems if found, then proves printing works
# by sending a colour test page. No flags required — just run it.
#
# Usage:
#   ./hp/lucky.sh
#   ./hp/lucky.sh --host 192.168.1.42
#
# What it does:
#   1. Finds your printer automatically (or uses --host if given)
#   2. Checks if anything looks wrong
#   3. Tries to fix it if so (clears stuck jobs, resets cloud connection)
#   4. Sends a test page with black and colour ink to prove the printer works

set -u
set -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EXPLICIT_HOST=""

usage() {
  cat <<'EOF'
Usage: ./hp/lucky.sh [--host HOST]

Auto-diagnoses your printer, runs repair if needed, then proves printing works.
No flags are required — just run it.

Options:
  --host HOST   Printer hostname or IP (detected automatically if not given).
  -h, --help    Show this help text.
EOF
}

parse_args() {
  local parse_error=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --host)
        [ "$#" -ge 2 ] || { parse_error="--host requires a value"; shift; continue; }
        EXPLICIT_HOST="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        parse_error="Unknown option: $1"
        shift
        ;;
    esac
  done

  if [ -n "$parse_error" ]; then
    printf 'ERROR: %s\n' "$parse_error" >&2
    exit 2
  fi
}

# Read KEY from diagnostics --plain output.
plain_field() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

# "stuck"    — job is trapped in the print engine (most common cause of "it just stopped")
# "degraded" — the printer has logged internal errors
# "degraded" mac_queue — the CUPS queue is disabled on this Mac
needs_repair() {
  local print_engine_health="$1"
  local mac_queue_health="$2"

  case "$print_engine_health:$mac_queue_health" in
    stuck:*|degraded:*|*:degraded) return 0 ;;
  esac
  return 1
}

main() {
  local diag_output queue host_ip print_engine_health
  local host_args=()

  parse_args "$@"
  [ -z "$EXPLICIT_HOST" ] || host_args=(--host "$EXPLICIT_HOST")

  printf '\nChecking your printer...\n'

  diag_output="$("$script_dir/diagnostics.sh" --plain ${host_args[@]+"${host_args[@]}"} 2>/dev/null)" || {
    printf 'ERROR: Could not find your printer. Is it turned on and connected to the network?\n' >&2
    exit 1
  }

  queue="$(plain_field "$diag_output" queue)"
  host_ip="$(plain_field "$diag_output" ipv4)"
  print_engine_health="$(plain_field "$diag_output" print_engine_health)"

  printf '  Found: %s\n' "${queue:-unknown}"
  if [ "${host_ip:-unknown}" != "unknown" ]; then
    printf '  Network address: %s\n' "$host_ip"
    # Pin later calls to the address diagnostics resolved, unless --host was given.
    [ -n "$EXPLICIT_HOST" ] || host_args=(--host "$host_ip")
  fi

  if needs_repair "$print_engine_health" "$(plain_field "$diag_output" mac_queue_health)"; then
    printf '\n  Found a problem with the printer (%s). Trying to fix it...\n' "$print_engine_health"
    # --plain suppresses technical prose while still running all repair actions.
    "$script_dir/repair.sh" --execute --plain ${host_args[@]+"${host_args[@]}"} >/dev/null 2>&1 || true
    printf '  Repair attempted. The test page below will help check whether printing works.\n'
  elif [ "$print_engine_health" = "unknown" ]; then
    printf '  Printer status could not be read. The test page below checks printing.\n'
  else
    printf '  Everything looks OK.\n'
  fi

  printf '\n'
  "$script_dir/prove-print.sh" ${host_args[@]+"${host_args[@]}"}
}

main "$@"
