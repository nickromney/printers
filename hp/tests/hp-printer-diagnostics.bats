#!/usr/bin/env bats

load test_helper

setup() {
  setup_mock_printer_env
}

@test "diagnose reports ProductLogs ErrorLog blocks without XML residue" {
  printf 'ready\n' > "${MOCK_STATE_DIR}/status_mode"
  printf 'single-line-error\n' > "${MOCK_STATE_DIR}/product_logs_mode"

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --output-dir "$MOCK_OUTPUT_DIR"

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "ProductStatusDyn status-category: ready"
  assert_output_contains "$output" "ProductLogsDyn hidden error log:"
  assert_output_contains "$output" "paper jam & cover open"
  assert_output_contains "$output" "Print engine: degraded (hidden HP error log is non-empty)"
  assert_output_contains "$output" "Hidden HP errors were found in ProductLogsDyn.xml."
  assert_output_not_contains "$output" "</pldyn:ErrorLog>"
  assert_file_not_exists "${MOCK_STATE_DIR}/last_job_cancel_payload.xml"
  assert_file_not_exists "${MOCK_STATE_DIR}/last_eprint_put_payload.xml"
}

@test "diagnostics rejects repair actions after the split" {
  for repair_flag in --execute --fix; do
    run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 "$repair_flag"

    [ "$status" -eq 2 ]
    assert_output_contains "$output" "repair actions are available in repair.sh"
  done
}

@test "diagnostics rejects hidden repair flags as unknown options" {
  for repair_flag in --soft-reset-pjl --experimental-clear-jobs --cancel-connecting; do
    run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 "$repair_flag"

    [ "$status" -eq 2 ]
    assert_output_contains "$output" "Unknown option: $repair_flag"
  done
}

@test "diagnostics help keeps the read-only contract" {
  run "$SCRIPT_UNDER_TEST" --help

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "./diagnostics.sh diagnose [options]"
  assert_output_not_contains "$output" "./repair.sh [options]"
}

@test "diagnostics plain output is stable" {
  printf 'ready\n' > "${MOCK_STATE_DIR}/status_mode"
  printf 'single-line-error\n' > "${MOCK_STATE_DIR}/product_logs_mode"

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --plain

  [ "$status" -eq 0 ]
  assert_output_equals_file "$output" "${BATS_TEST_DIRNAME}/fixtures/plain-diagnostics.expected"
}

@test "repair help is the default" {
  run "$REPAIR_SCRIPT_UNDER_TEST"

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "./repair.sh --execute [options]"
  assert_output_contains "$output" "--execute, --fix"
  assert_output_not_contains "$output" "--soft-reset-pjl"
  assert_output_not_contains "$output" "--experimental-clear-jobs"
  assert_output_not_contains "$output" "--cancel-connecting"
}

@test "repair help keeps the mutation contract" {
  run "$REPAIR_SCRIPT_UNDER_TEST" --help

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "./repair.sh --execute [options]"
  assert_output_contains "$output" "./repair.sh --fix [options]"
  assert_output_not_contains "$output" "./diagnostics.sh diagnose [options]"
  assert_output_not_contains "$output" "--soft-reset-pjl"
  assert_output_not_contains "$output" "--experimental-clear-jobs"
  assert_output_not_contains "$output" "--cancel-connecting"
}

@test "repair rejects internal-only repair flags" {
  for repair_flag in --soft-reset-pjl --experimental-clear-jobs --cancel-connecting; do
    run "$REPAIR_SCRIPT_UNDER_TEST" "$repair_flag"

    [ "$status" -eq 2 ]
    assert_output_contains "$output" "Unknown option: $repair_flag"
  done
}

@test "repair execute and fix aliases run the full repair recipe" {
  for repair_flag in --execute --fix; do
    printf 'processing\n' > "${MOCK_STATE_DIR}/job_list_mode"
    printf 'warning\n' > "${MOCK_STATE_DIR}/status_mode"
    printf 'registered\n' > "${MOCK_STATE_DIR}/eprint_mode"
    printf 'connectNowWarning\n' > "${MOCK_STATE_DIR}/subscription_status"

    run "$REPAIR_SCRIPT_UNDER_TEST" --host 192.0.2.25 "$repair_flag" --output-dir "$MOCK_OUTPUT_DIR"

    [ "$status" -eq 0 ]
    assert_output_contains "$output" "Soft PJL reset sent:"
    assert_output_contains "$output" "Found processing jobs:"
    assert_output_contains "$output" "PUT /Jobs/JobList/10 -> 200"
    assert_output_contains "$output" "Cancel connecting action sent:"
    assert_output_contains "$output" "Cancel connecting HTTP code: 200"
    [ -f "${MOCK_STATE_DIR}/last_nc_args.txt" ]
    [ -f "${MOCK_STATE_DIR}/last_job_cancel_payload.xml" ]
    [ -f "${MOCK_STATE_DIR}/last_eprint_put_payload.xml" ]
  done
}

@test "repair plain output is stable" {
  printf 'processing\n' > "${MOCK_STATE_DIR}/job_list_mode"

  run "$REPAIR_SCRIPT_UNDER_TEST" --host 192.0.2.25 --execute --plain

  [ "$status" -eq 0 ]
  assert_output_equals_file "$output" "${BATS_TEST_DIRNAME}/fixtures/plain-repair-execute.expected"
}

@test "repair execute saves the full recipe raw captures" {
  printf 'processing\n' > "${MOCK_STATE_DIR}/job_list_mode"

  run "$REPAIR_SCRIPT_UNDER_TEST" --host 192.0.2.25 --execute --output-dir "$MOCK_OUTPUT_DIR"

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "Found processing jobs:"
  assert_output_contains "$output" "/Jobs/JobList/10"
  assert_output_contains "$output" "PUT /Jobs/JobList/10 -> 200"
  assert_output_contains "$output" "Cancel connecting action sent:"
  assert_output_contains "$output" "Soft PJL reset sent:"
  [ -f "${MOCK_OUTPUT_DIR}/07-soft-reset-pjl.txt" ]
  [ -f "${MOCK_OUTPUT_DIR}/48-experimental-clear-jobs.txt" ]
  [ -f "${MOCK_OUTPUT_DIR}/49-post-action-jobs-joblist.xml" ]
  [ -f "${MOCK_OUTPUT_DIR}/50-post-action-product-status.xml" ]
  [ -f "${MOCK_OUTPUT_DIR}/51-post-action-ipp-attributes.txt" ]
  [ -f "${MOCK_OUTPUT_DIR}/52-cancel-connecting-pre-eprint-config.xml" ]
  [ -f "${MOCK_OUTPUT_DIR}/53-cancel-connecting-pre-product-status.xml" ]
  [ -f "${MOCK_OUTPUT_DIR}/54-cancel-connecting-pre-subscription.xml" ]
  [ -f "${MOCK_OUTPUT_DIR}/55-cancel-connecting-http-response.txt" ]
  [ -f "${MOCK_OUTPUT_DIR}/56-cancel-connecting-post-eprint-config.xml" ]
  [ -f "${MOCK_OUTPUT_DIR}/57-cancel-connecting-post-product-status.xml" ]
  [ -f "${MOCK_OUTPUT_DIR}/58-cancel-connecting-post-subscription.xml" ]
  assert_file_contains "${MOCK_OUTPUT_DIR}/48-experimental-clear-jobs.txt" "Found processing jobs:"
  assert_file_contains "${MOCK_OUTPUT_DIR}/49-post-action-jobs-joblist.xml" "<j:JobState>Completed</j:JobState>"
  assert_file_contains "${MOCK_OUTPUT_DIR}/52-cancel-connecting-pre-eprint-config.xml" "<ep:RegistrationState>registered</ep:RegistrationState>"
  assert_file_contains "${MOCK_OUTPUT_DIR}/53-cancel-connecting-pre-product-status.xml" "<pscat:StatusCategory>subscribedPagesLow</pscat:StatusCategory>"
  assert_file_contains "${MOCK_OUTPUT_DIR}/55-cancel-connecting-http-response.txt" "http_code=200"
  assert_file_contains "${MOCK_OUTPUT_DIR}/56-cancel-connecting-post-eprint-config.xml" "<ep:RegistrationState>unregistered</ep:RegistrationState>"
  assert_file_contains "${MOCK_OUTPUT_DIR}/57-cancel-connecting-post-product-status.xml" "<pscat:StatusCategory>ready</pscat:StatusCategory>"
}
