#!/usr/bin/env bats

load test_helper

setup() {
  setup_mock_printer_env
}

@test "--cancel-connecting disables HP web services and clears the panel warning path" {
  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --cancel-connecting --output-dir "$MOCK_OUTPUT_DIR"

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "Cancel connecting HTTP code: 200"
  assert_output_contains "$output" "ePrint registration-state: unregistered"
  assert_output_contains "$output" "Cloud/Instant Ink: disabled (HP web services are intentionally disabled while subscription cartridges remain installed)"
  assert_output_contains "$output" "Pre-action ProductStatusDyn status-category: subscribedPagesLow"
  assert_output_contains "$output" "Post-action ProductStatusDyn status-category: ready"
}

@test "--cancel-connecting sends only the writable ePrint fields" {
  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --cancel-connecting --output-dir "$MOCK_OUTPUT_DIR"

  [ "$status" -eq 0 ]
  [ -f "${MOCK_STATE_DIR}/last_eprint_put_payload.xml" ]
  assert_file_contains "${MOCK_STATE_DIR}/last_eprint_put_payload.xml" "<ep:EmailService>disabled</ep:EmailService>"
  assert_file_contains "${MOCK_STATE_DIR}/last_eprint_put_payload.xml" "<ep:SipService>disabled</ep:SipService>"
  assert_file_contains "${MOCK_STATE_DIR}/last_eprint_put_payload.xml" "<ep:MobileAppsService>disabled</ep:MobileAppsService>"
  assert_file_contains "${MOCK_STATE_DIR}/last_eprint_put_payload.xml" "<ep:RegistrationState>unregistered</ep:RegistrationState>"
  assert_file_contains "${MOCK_STATE_DIR}/last_eprint_put_payload.xml" "<ep:XMPPConnectionState>disconnected</ep:XMPPConnectionState>"
  assert_file_contains "${MOCK_STATE_DIR}/last_eprint_put_payload.xml" "<ep:BeaconState>disabled</ep:BeaconState>"
  assert_file_not_contains "${MOCK_STATE_DIR}/last_eprint_put_payload.xml" "<ep:PrinterID>"
  assert_file_not_contains "${MOCK_STATE_DIR}/last_eprint_put_payload.xml" "<ep:SignalingConnectionState>"
}

@test "--cancel-connecting saves pre and post raw captures" {
  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --cancel-connecting --output-dir "$MOCK_OUTPUT_DIR"

  [ "$status" -eq 0 ]
  [ -f "${MOCK_OUTPUT_DIR}/52-cancel-connecting-pre-eprint-config.xml" ]
  [ -f "${MOCK_OUTPUT_DIR}/56-cancel-connecting-post-eprint-config.xml" ]
  [ -f "${MOCK_OUTPUT_DIR}/57-cancel-connecting-post-product-status.xml" ]
  [ -f "${MOCK_OUTPUT_DIR}/58-cancel-connecting-post-subscription.xml" ]
  assert_file_contains "${MOCK_OUTPUT_DIR}/55-cancel-connecting-http-response.txt" "http_code=200"
  assert_file_contains "${MOCK_OUTPUT_DIR}/52-cancel-connecting-pre-eprint-config.xml" "<ep:RegistrationState>registered</ep:RegistrationState>"
  assert_file_contains "${MOCK_OUTPUT_DIR}/56-cancel-connecting-post-eprint-config.xml" "<ep:RegistrationState>unregistered</ep:RegistrationState>"
  assert_file_contains "${MOCK_OUTPUT_DIR}/57-cancel-connecting-post-product-status.xml" "<pscat:StatusCategory>ready</pscat:StatusCategory>"
}
