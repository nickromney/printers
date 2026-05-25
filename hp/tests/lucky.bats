#!/usr/bin/env bats

load test_helper

setup() {
  setup_mock_printer_env
}

@test "lucky finds the printer and reports it in friendly language" {
  run "$LUCKY_UNDER_TEST"

  [ "$status" -eq 0 ]
  # Queue name must appear — confirms auto-detection worked
  assert_output_contains "$output" "HP_Test_Series__ABC123_"
  # Must have sent a test print — confirms the full lucky flow completed
  [ -f "${MOCK_STATE_DIR}/last_lp_file.ps" ]
  # Technical jargon must not be the opening message
  assert_output_not_contains "$output" "ProductStatusDyn"
  assert_output_not_contains "$output" "ePrint"
}

@test "lucky reports printer is healthy without running repair" {
  # Default mock state: status_mode=warning → print_engine_health=active
  # Set status_mode to ready to get a healthy state
  printf 'ready\n' > "${MOCK_STATE_DIR}/status_mode"
  printf 'clean\n' > "${MOCK_STATE_DIR}/product_logs_mode"
  printf 'disabled\n' > "${MOCK_STATE_DIR}/eprint_mode"

  run "$LUCKY_UNDER_TEST"

  [ "$status" -eq 0 ]
  # Should not trigger repair
  assert_output_not_contains "$output" "Soft PJL reset"
  assert_output_not_contains "$output" "Found processing jobs"
  # Should still prove printing works
  assert_output_contains "$output" "test page"
}

@test "lucky runs repair when print engine is not healthy" {
  printf 'processing\n' > "${MOCK_STATE_DIR}/job_list_mode"
  printf 'warning\n' > "${MOCK_STATE_DIR}/status_mode"
  printf 'registered\n' > "${MOCK_STATE_DIR}/eprint_mode"

  # Pass --host explicitly to bypass DNS-SD resolution and make the test reliable.
  # (DNS-SD auto-detection is tested via the diagnostics tests; here we focus on
  # what lucky.sh does when it detects a stuck print engine.)
  run "$LUCKY_UNDER_TEST" --host 192.0.2.25

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "problem"
  [ -f "${MOCK_STATE_DIR}/last_nc_args.txt" ]
}

@test "lucky always sends a test print at the end" {
  run "$LUCKY_UNDER_TEST"

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "test page"
  [ -f "${MOCK_STATE_DIR}/last_lp_file.ps" ]
}

@test "lucky shows a friendly summary of what it found and did" {
  run "$LUCKY_UNDER_TEST"

  [ "$status" -eq 0 ]
  # Should not show technical jargon as the top-level message
  assert_output_not_contains "$output" "ProductStatusDyn"
  assert_output_not_contains "$output" "XMPP"
  assert_output_not_contains "$output" "ePrint"
}

@test "lucky test print PostScript contains both ink directives" {
  run "$LUCKY_UNDER_TEST"

  [ "$status" -eq 0 ]
  [ -f "${MOCK_STATE_DIR}/last_lp_file.ps" ]
  assert_file_contains "${MOCK_STATE_DIR}/last_lp_file.ps" "black ink"
  assert_file_contains "${MOCK_STATE_DIR}/last_lp_file.ps" "colour ink"
}
