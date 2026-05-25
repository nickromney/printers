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
PARSE_ERROR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      [ "$#" -ge 2 ] || { PARSE_ERROR="--host requires a value"; shift; continue; }
      EXPLICIT_HOST="$2"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
Usage: ./hp/lucky.sh [--host HOST]

Auto-diagnoses your printer, runs repair if needed, then proves printing works.
No flags are required — just run it.

Options:
  --host HOST   Printer hostname or IP (detected automatically if not given).
  -h, --help    Show this help text.
EOF
      exit 0 ;;
    *)
      PARSE_ERROR="Unknown option: $1"; shift ;;
  esac
done

if [ -n "$PARSE_ERROR" ]; then
  printf 'ERROR: %s\n' "$PARSE_ERROR" >&2
  exit 2
fi

# Build the host argument to pass to sub-scripts.
# If --host was given explicitly, always use it.
# Otherwise, discover the resolved IP from diagnostics output.
HOST_ARG=""
if [ -n "$EXPLICIT_HOST" ]; then
  HOST_ARG="--host $EXPLICIT_HOST"
fi

printf '\nChecking your printer...\n'

# Step 1: Run diagnostics in plain (machine-readable) mode so we can parse the health
# shellcheck disable=SC2086
DIAG_OUTPUT="$("$script_dir/diagnostics.sh" --plain $HOST_ARG 2>/dev/null)" || {
  printf 'ERROR: Could not find your printer. Is it turned on and connected to the network?\n' >&2
  exit 1
}

QUEUE="$(printf '%s\n' "$DIAG_OUTPUT" | grep '^queue=' | sed 's/^queue=//')"
HOST_IP="$(printf '%s\n' "$DIAG_OUTPUT" | grep '^ipv4=' | sed 's/^ipv4=//')"
PRINT_ENGINE_HEALTH="$(printf '%s\n' "$DIAG_OUTPUT" | grep '^print_engine_health=' | sed 's/^print_engine_health=//')"
MAC_QUEUE_HEALTH="$(printf '%s\n' "$DIAG_OUTPUT" | grep '^mac_queue_health=' | sed 's/^mac_queue_health=//')"

printf '  Found: %s\n' "${QUEUE:-unknown}"
if [ -n "$HOST_IP" ] && [ "$HOST_IP" != "unknown" ]; then
  printf '  Network address: %s\n' "$HOST_IP"
fi

# If --host was not given explicitly, derive it from the resolved IP in the
# diagnostics output so subsequent calls hit the same endpoint reliably.
if [ -z "$EXPLICIT_HOST" ] && [ -n "$HOST_IP" ] && [ "$HOST_IP" != "unknown" ]; then
  HOST_ARG="--host $HOST_IP"
fi

# Step 2: Decide if repair is needed
# "stuck"    — job is trapped in the print engine (most common cause of "it just stopped")
# "degraded" — the printer has logged internal errors
# "degraded" mac_queue — the CUPS queue is disabled on this Mac
NEEDS_REPAIR=0
if [ "$PRINT_ENGINE_HEALTH" = "stuck" ] || [ "$PRINT_ENGINE_HEALTH" = "degraded" ]; then
  NEEDS_REPAIR=1
fi
if [ "$MAC_QUEUE_HEALTH" = "degraded" ]; then
  NEEDS_REPAIR=1
fi

if [ "$NEEDS_REPAIR" -eq 1 ]; then
  printf '\n  Found a problem with the printer (%s). Trying to fix it...\n' "$PRINT_ENGINE_HEALTH"

  # Run the full repair recipe silently — we only surface the friendly summary
  # (--plain suppresses technical prose while still running all repair actions)
  # shellcheck disable=SC2086
  "$script_dir/repair.sh" --execute --plain $HOST_ARG >/dev/null 2>&1 || true

  printf '  Done. The printer should be ready now.\n'
else
  printf '  Everything looks OK.\n'
fi

# Step 3: Prove printing works by sending a colour test page
printf '\n'
# shellcheck disable=SC2086
"$script_dir/prove-print.sh" $HOST_ARG
