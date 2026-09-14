#!/usr/bin/env bats
#
# Golden tests for the full prose report. The fixtures pin every section so a
# changed label, a dropped line, or a flipped interpretation rule shows up as a
# diff. Regenerate a fixture only after reading that diff:
#
#   UPDATE_FIXTURES=1 bats hp/tests/prose-report.bats

load test_helper

setup() {
  setup_mock_printer_env
}

assert_report_matches() {
  local fixture="${BATS_TEST_DIRNAME}/fixtures/$1"

  if [ -n "${UPDATE_FIXTURES:-}" ]; then
    scrub_output "$output" > "$fixture"
  fi
  assert_scrubbed_output_equals_file "$output" "$fixture"
}

add_finished_page_to_queue_detail() {
  sed -i.bak 's#^\tAlerts: none$#\tAlerts: none\n\tFinished page 1#' "${MOCK_BIN}/lpstat"
}

@test "diagnose report with Bonjour discovery and an active HP status" {
  add_finished_page_to_queue_detail

  run "$SCRIPT_UNDER_TEST"

  [ "$status" -eq 0 ]
  assert_report_matches "prose-diagnose-discovered.expected"
}

@test "diagnose report for a full spool with no subscription cartridges" {
  set_mock_state ipp_mode spool-full
  set_mock_state job_list_mode processing
  set_mock_state status_mode ready
  set_mock_state product_logs_mode single-line-error
  set_mock_state consumable_mode plain

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25

  [ "$status" -eq 0 ]
  assert_report_matches "prose-diagnose-spool-full.expected"
}

@test "repair report shows every recipe section" {
  set_mock_state job_list_mode processing

  run "$REPAIR_SCRIPT_UNDER_TEST" --execute --host 192.0.2.25 --output-dir "$MOCK_OUTPUT_DIR"

  [ "$status" -eq 0 ]
  assert_report_matches "prose-repair-execute.expected"
}

@test "cloud health is healthy when subscription cartridges have a connected cloud path" {
  set_mock_state signaling_state connected

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "Cloud/Instant Ink: healthy (Instant Ink cloud path is fully connected)"
  assert_output_not_contains "$output" "ePrint signaling is not connected"
}

@test "cloud health detail mentions installed subscription cartridges only when present" {
  set_mock_state eprint_mode disabled

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25
  assert_output_contains "$output" "Cloud/Instant Ink: disabled (HP web services are intentionally disabled while subscription cartridges remain installed)"

  set_mock_state consumable_mode plain
  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25
  assert_output_contains "$output" "Cloud/Instant Ink: disabled (HP web services are intentionally disabled)"
  assert_output_contains "$output" "panel prompts should stay cleared."
}

@test "an unresolvable printer skips network probes" {
  set_mock_device_uri "usb://HP/Test"

  run "$SCRIPT_UNDER_TEST"

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "Host: unknown"
  assert_output_contains "$output" "IPv4: unknown"
  assert_output_contains "$output" "WARN: IPP query did not return data"
  assert_output_contains "$output" "SNMP status query: unavailable or no IPv4 address resolved"
  assert_output_contains "$output" "SNMP supply summary: unavailable"
  assert_output_contains "$output" "Cloud/Instant Ink: unknown (cloud state not available)"
  assert_file_not_exists "${MOCK_STATE_DIR}/ipp_uris.txt"
}

@test "a hostname that dns-sd cannot resolve is not reported as the IPv4 address" {
  run "$SCRIPT_UNDER_TEST" --host printer.invalid

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "Host: printer.invalid"
  assert_output_contains "$output" "IPv4: unknown"
  assert_output_contains "$output" "SNMP status query: unavailable"
  assert_file_contains "${MOCK_STATE_DIR}/ipp_uris.txt" "ipp://printer.invalid/ipp/print"
}

@test "CUPS errors are split into the last 24 hours and older" {
  {
    printf 'E [%s] recent failure\n' "$(date -v-1H '+%d/%b/%Y:%H:%M:%S %z')"
    printf 'W [%s] ancient warning\n' "$(date -v-48H '+%d/%b/%Y:%H:%M:%S %z')"
    printf 'I [%s] info is ignored\n' "$(date -v-1H '+%d/%b/%Y:%H:%M:%S %z')"
  } > "$CUPS_ERROR_LOG_PATH"

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --output-dir "$MOCK_OUTPUT_DIR"

  [ "$status" -eq 0 ]
  recent="${output#*Recent CUPS errors/warnings (last 24 hours):}"
  recent="${recent%%Older CUPS errors*}"
  older="${output#*Older CUPS errors/warnings (before the last 24 hours):}"
  older="${older%%== IPP ==*}"
  assert_output_contains "$recent" "recent failure"
  assert_output_not_contains "$recent" "ancient warning"
  assert_output_contains "$older" "ancient warning"
  assert_output_not_contains "$older" "recent failure"
  assert_output_not_contains "$output" "info is ignored"
  assert_file_contains "${MOCK_OUTPUT_DIR}/06-cups-errors.txt" "recent failure"
  assert_file_not_contains "${MOCK_OUTPUT_DIR}/06-cups-errors.txt" "ancient warning"
}

@test "an unreadable CUPS_ERROR_LOG_PATH is reported" {
  export CUPS_ERROR_LOG_PATH="${TEST_ROOT}/missing.log"

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "WARN: CUPS_ERROR_LOG_PATH is set but not readable: ${TEST_ROOT}/missing.log"
}

@test "save-raw without an output dir writes a timestamped directory" {
  cd "$TEST_ROOT"

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --save-raw

  [ "$status" -eq 0 ]
  captures=(diagnostics-output/*/21-product-status.xml)
  [ -f "${captures[0]}" ]
}

@test "diagnose without save-raw writes no captures" {
  cd "$TEST_ROOT"

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25

  [ "$status" -eq 0 ]
  assert_file_not_exists "${TEST_ROOT}/diagnostics-output"
  assert_output_not_contains "$output" "Raw output directory"
  assert_output_not_contains "$output" "During Printing Monitor"
}

@test "plain mode with an output dir keeps the stable summary and writes no report captures" {
  set_mock_state status_mode ready
  set_mock_state product_logs_mode single-line-error

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --plain --output-dir "$MOCK_OUTPUT_DIR"

  [ "$status" -eq 0 ]
  assert_output_equals_file "$output" "${BATS_TEST_DIRNAME}/fixtures/plain-diagnostics.expected"
  assert_file_not_exists "${MOCK_OUTPUT_DIR}/21-product-status.xml"
}
