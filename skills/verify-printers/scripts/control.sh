#!/usr/bin/env bash
# shellcheck disable=SC2034 # VK_* settings are read by the sourced verify-lib.sh
set -euo pipefail

VK_SCRIPT="$0"
VK_APP="printers"
VK_DESCRIPTION="Read-only verification harness for HP printer diagnostics."
VK_DEFAULT_BASE_DIR="${TMPDIR:-/tmp}/verify-printers"
VK_DEFAULT_EVIDENCE_ROOT="${TMPDIR:-/tmp}/verify-printers-evidence"
# shellcheck source=verify-lib.sh disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/verify-lib.sh"

vk_commands_help() {
  cat <<'HELP'
  launch                 create an isolated diagnostics run
  doctor                 check required local printer CLI tools
  diagnose               run read-only HP diagnostics and capture the summary
  cleanup                remove this run's state; evidence is kept
HELP
}
vk_sample_commands() { printf '%s\n' verify launch doctor diagnose cleanup; }
vk_paths() {
  STATE="$VK_BASE_DIR/$VK_RUN_ID/state"
  EVIDENCE="$VK_EVIDENCE_ROOT/$VK_RUN_ID"
  APP_ROOT="$VK_ROOT"
}

vk_plan() {
  case "$1" in
    verify) vk_plan_line "check tools, run hp/diagnostics.sh --plain (read-only), assert summary, cleanup; evidence in $EVIDENCE" ;;
    launch) vk_plan_line "create $STATE and $EVIDENCE; mark run $VK_RUN_ID current" ;;
    doctor) vk_plan_line "check bash, lpstat, curl, and network diagnostic utilities (read-only)" ;;
    diagnose) vk_plan_line "run $APP_ROOT/hp/diagnostics.sh --plain; capture summary in $EVIDENCE/diagnostics.txt" ;;
    cleanup) vk_plan_line "remove $STATE; keep $EVIDENCE" ;;
    *) vk_unknown_command ;;
  esac
}

cmd_launch() {
  mkdir -p "$STATE" "$EVIDENCE"
  vk_mark_current
  vk_record_revision "$EVIDENCE/revision.txt"
  vk_say "ready run=$VK_RUN_ID state=$STATE evidence=$EVIDENCE"
}
cmd_doctor() {
  [ -d "$STATE" ] || { vk_fail "no app state for run $VK_RUN_ID; launch first"; return 1; }
  local tool
  for tool in bash lpstat curl; do
    command -v "$tool" >/dev/null || { vk_fail "$tool is required"; return 1; }
  done
  vk_say "OK diagnostics prerequisites available"
}
cmd_diagnose() {
  "$APP_ROOT/hp/diagnostics.sh" --plain > "$EVIDENCE/diagnostics.txt" 2>&1 || {
    cat "$EVIDENCE/diagnostics.txt"
    vk_fail "read-only diagnostics failed; see $EVIDENCE/diagnostics.txt"
    return 1
  }
  cat "$EVIDENCE/diagnostics.txt"
}
cmd_cleanup() {
  rm -rf "${STATE:?}"
  rmdir "$VK_BASE_DIR/$VK_RUN_ID" 2>/dev/null || true
  vk_clear_current
  vk_say "removed state for run=$VK_RUN_ID; evidence kept at $EVIDENCE"
}
vk_verify_recipes() {
  cmd_diagnose
  vk_expect_contains "$EVIDENCE/diagnostics.txt" "command=diagnose"
  grep -E -q '^print_engine_health=(stuck|active|degraded|unknown|healthy)$' "$EVIDENCE/diagnostics.txt" || {
    vk_fail "print_engine_health is missing or has an unexpected value; see $EVIDENCE/diagnostics.txt"
    return 1
  }
  grep -E -q '^cloud_health=(disabled|healthy|degraded|not-in-use|unknown)$' "$EVIDENCE/diagnostics.txt" || {
    vk_fail "cloud_health is missing or has an unexpected value; see $EVIDENCE/diagnostics.txt"
    return 1
  }
  vk_say "PASS: diagnostic health fields have recognized values"
}

vk_dispatch() {
  local cmd="$1"
  shift
  case "$cmd" in
    launch) cmd_launch ;;
    doctor) cmd_doctor ;;
    diagnose) cmd_diagnose ;;
    cleanup) cmd_cleanup ;;
    *) vk_unknown_command ;;
  esac
}
vk_main "$@"
