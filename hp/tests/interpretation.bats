#!/usr/bin/env bats
#
# Boundary and combination checks for the prose interpretation and health
# rules that the golden reports do not pin on their own.

load test_helper

setup() {
  setup_mock_printer_env
}

spool_note="The printer is still holding at least one print job open internally while reporting spool-area-full-report."

@test "spool note needs processing jobs on both IPP and the HP job list" {
  set_mock_state ipp_mode spool-full
  set_mock_state job_list_mode processing
  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25
  assert_output_contains "$output" "$spool_note"
}

@test "spool note is absent when only IPP has a processing job" {
  set_mock_state ipp_mode spool-full
  set_mock_state job_list_mode completed
  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25
  [ "$status" -eq 0 ]
  assert_output_not_contains "$output" "$spool_note"
}

@test "spool note is absent when only the HP job list has a processing job" {
  set_mock_state ipp_mode spool-full-no-jobs
  set_mock_state job_list_mode processing
  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25
  [ "$status" -eq 0 ]
  assert_output_not_contains "$output" "$spool_note"
}

@test "processing jobs without a full spool do not produce the spool note" {
  set_mock_state job_list_mode processing
  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25
  [ "$status" -eq 0 ]
  assert_output_not_contains "$output" "$spool_note"
}

@test "an uptime of exactly 900 seconds is not a recent reboot" {
  set_mock_state ipp_uptime 900
  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25
  assert_output_not_contains "$output" "suggests a recent reboot"

  set_mock_state ipp_uptime 899
  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25
  assert_output_contains "$output" "The printer uptime is only 899s, which suggests a recent reboot."
}

@test "zero mispick events are not reported" {
  set_mock_state mispick_events 0
  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25
  [ "$status" -eq 0 ]
  assert_output_not_contains "$output" "paper mispick events"

  set_mock_state mispick_events 1
  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25
  assert_output_contains "$output" "lifetime history of 1 paper mispick events"
}

@test "a connected cloud path without subscription cartridges is not-in-use" {
  set_mock_state consumable_mode plain
  set_mock_state signaling_state connected
  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25
  [ "$status" -eq 0 ]
  assert_output_contains "$output" "Cloud/Instant Ink: not-in-use (no subscription cartridges detected)"
}
