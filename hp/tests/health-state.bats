#!/usr/bin/env bats
#
# Health-state decision tests
#
# These test the interpretation logic that maps raw printer signals to the
# print_engine_health, cloud_health, and mac_queue_health values emitted
# by --plain output. This is the "deep" logic in the codebase — the only
# place that turns collected data into a human-meaningful verdict.
#
# Tests use --plain mode and the --host flag to bypass DNS-SD lookup,
# confirming each health state via the machine-readable summary.

load test_helper

setup() {
  setup_mock_printer_env
}

# ---- print_engine_health ----

@test "print_engine_health is healthy when printer is ready and logs are clean" {
  printf 'ready\n'  > "${MOCK_STATE_DIR}/status_mode"
  printf 'clean\n'  > "${MOCK_STATE_DIR}/product_logs_mode"
  printf 'completed\n' > "${MOCK_STATE_DIR}/job_list_mode"

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --plain

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "print_engine_health=healthy"
}

@test "print_engine_health is degraded when HP error log is non-empty" {
  printf 'ready\n'           > "${MOCK_STATE_DIR}/status_mode"
  printf 'single-line-error\n' > "${MOCK_STATE_DIR}/product_logs_mode"
  printf 'completed\n'      > "${MOCK_STATE_DIR}/job_list_mode"

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --plain

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "print_engine_health=degraded"
}

@test "print_engine_health is active when status is not ready" {
  # status_mode=warning gives StatusCategory=subscribedPagesLow (not ready)
  printf 'warning\n' > "${MOCK_STATE_DIR}/status_mode"
  printf 'clean\n'   > "${MOCK_STATE_DIR}/product_logs_mode"
  printf 'completed\n' > "${MOCK_STATE_DIR}/job_list_mode"

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --plain

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "print_engine_health=active"
}

@test "print_engine_health is stuck when HP has processing job but IPP reports idle" {
  # HP job list has a Processing job; IPP mock always returns idle/no jobs
  printf 'processing\n' > "${MOCK_STATE_DIR}/job_list_mode"
  printf 'warning\n'    > "${MOCK_STATE_DIR}/status_mode"

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --plain

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "print_engine_health=stuck"
}

# ---- cloud_health ----

@test "cloud_health is disabled when all ePrint services are off and unregistered" {
  printf 'disabled\n' > "${MOCK_STATE_DIR}/eprint_mode"
  printf 'ready\n'    > "${MOCK_STATE_DIR}/status_mode"

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --plain

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "cloud_health=disabled"
  assert_output_contains "$output" "eprint_registration_state=unregistered"
}

@test "cloud_health is degraded when subscription cartridges are installed but cloud not connected" {
  # eprint_mode=registered gives: registered + connected XMPP + disconnected signaling
  printf 'registered\n' > "${MOCK_STATE_DIR}/eprint_mode"
  # Consumable mock has 2 subscription cartridges
  # Signaling is disconnected → cloud_health=degraded

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --plain

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "cloud_health=degraded"
}

# ---- mac_queue_health ----

@test "mac_queue_health is healthy when queue is enabled and idle" {
  # Default mock: lpstat reports "is idle, enabled"
  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --plain

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "mac_queue_health=healthy"
}

@test "mac_queue_health is degraded when CUPS queue is disabled" {
  # Override mock lpstat to report a disabled queue
  cat > "${MOCK_BIN}/lpstat" <<'EOF'
#!/usr/bin/env bash
queue="HP_Test_Series__ABC123_"
case "$*" in
  "-d")   printf 'system default destination: %s\n' "$queue" ;;
  "-p")   printf 'printer %s disabled since Sun Mar 22 21:17:15 2026 -\n\t(reason: paused)\n' "$queue" ;;
  "-p -d -v")
    printf 'printer %s disabled since Sun Mar 22 21:17:15 2026 -\n\t(reason: paused)\n' "$queue"
    printf 'system default destination: %s\n' "$queue"
    printf 'device for %s: dnssd://HP%%20Test%%20Series%%20%%5BABC123%%5D._ipp._tcp.local./?uuid=11111111-2222-3333-4444-555555555555\n' "$queue"
    ;;
  "-l -p HP_Test_Series__ABC123_")
    printf 'printer %s disabled since Sun Mar 22 21:17:15 2026 -\n\t(reason: paused)\n\tDescription: HP Test Series [ABC123]\n' "$queue" ;;
  "-W all -o HP_Test_Series__ABC123_"|"-W not-completed -o HP_Test_Series__ABC123_")
    exit 0 ;;
  *)
    printf 'unexpected lpstat args: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
  chmod +x "${MOCK_BIN}/lpstat"

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --plain

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "mac_queue_health=degraded"
}
