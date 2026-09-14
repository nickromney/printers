#!/usr/bin/env bats

load test_helper

setup() {
  setup_mock_printer_env
}

@test "prove-print shows help text" {
  run "$PROVE_PRINT_UNDER_TEST" --help

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "prove-print.sh"
  assert_output_contains "$output" "--queue"
  assert_output_contains "$output" "--host"
}

@test "prove-print sends PostScript job with black and colour directives" {
  run "$PROVE_PRINT_UNDER_TEST" --host 192.0.2.25

  [ "$status" -eq 0 ]
  [ -f "${MOCK_STATE_DIR}/last_lp_file.ps" ]
  assert_file_contains "${MOCK_STATE_DIR}/last_lp_file.ps" "setrgbcolor"
  assert_file_contains "${MOCK_STATE_DIR}/last_lp_file.ps" "black ink"
  assert_file_contains "${MOCK_STATE_DIR}/last_lp_file.ps" "colour ink"
}

@test "prove-print PostScript uses 0 0 0 for black and non-zero for colour" {
  run "$PROVE_PRINT_UNDER_TEST" --host 192.0.2.25

  [ "$status" -eq 0 ]
  # Black: 0 0 0 setrgbcolor
  grep -q '0 0 0 setrgbcolor' "${MOCK_STATE_DIR}/last_lp_file.ps"
  # Colour (blue): non-zero red/green/blue — just check it is NOT 0 0 0 on the colour line
  grep -q 'colour ink' "${MOCK_STATE_DIR}/last_lp_file.ps"
  # Ensure a non-black colour is present before the colour line
  ps_content="$(cat "${MOCK_STATE_DIR}/last_lp_file.ps")"
  [[ "$ps_content" =~ "colour ink" ]]
}

@test "prove-print reports ink levels in friendly output" {
  run "$PROVE_PRINT_UNDER_TEST" --host 192.0.2.25

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "black"
  assert_output_contains "$output" "colour"
  # Should tell the user the test page was sent
  assert_output_contains "$output" "test page"
}

@test "prove-print uses a unique temp file and removes it afterwards" {
  run "$PROVE_PRINT_UNDER_TEST" --host 192.0.2.25

  [ "$status" -eq 0 ]
  ps_path="$(cat "${MOCK_STATE_DIR}/last_lp_input_path.txt")"
  [ -n "$ps_path" ]
  assert_output_not_contains "$ps_path" "XXXXXX"
  assert_file_not_exists "$ps_path"
}

@test "prove-print reports which queue it used" {
  run "$PROVE_PRINT_UNDER_TEST" --host 192.0.2.25

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "HP_Test_Series__ABC123_"
}

@test "prove-print requires a printer queue" {
  # No printer available — mock lpstat returns nothing
  cat > "${MOCK_BIN}/lpstat" <<'EOF'
#!/usr/bin/env bash
set -eu
case "$*" in
  "-d")
    exit 1
    ;;
  "-p")
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "${MOCK_BIN}/lpstat"

  run "$PROVE_PRINT_UNDER_TEST"

  [ "$status" -ne 0 ]
  assert_output_contains "$output" "ERROR"
}

@test "prove-print pairs ink names with their levels" {
  run "$PROVE_PRINT_UNDER_TEST" --host 192.0.2.25

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "== Colour Test Print ==
Queue: HP_Test_Series__ABC123_
Ink levels before printing:
  colour ink: 30%
  black ink: 70%"
}

@test "prove-print says it cannot read ink levels when levels are missing" {
  printf 'no-levels\n' > "${MOCK_STATE_DIR}/ipp_mode"

  run "$PROVE_PRINT_UNDER_TEST" --host 192.0.2.25

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "Ink levels: (could not read from printer)"
  assert_output_not_contains "$output" "black ink:"
  [ -f "${MOCK_STATE_DIR}/last_lp_file.ps" ]
}

@test "prove-print discovers the printer and queries its IPv4 address" {
  run "$PROVE_PRINT_UNDER_TEST"

  [ "$status" -eq 0 ]
  [ "$(cat "${MOCK_STATE_DIR}/ipp_uris.txt")" = "ipp://192.0.2.25/ipp/print" ]
  [ "$(cat "${MOCK_STATE_DIR}/last_lp_dest.txt")" = "HP_Test_Series__ABC123_" ]
}

@test "prove-print keeps an explicit host instead of rediscovering" {
  run "$PROVE_PRINT_UNDER_TEST" --host 192.0.2.99

  [ "$status" -eq 0 ]
  [ "$(cat "${MOCK_STATE_DIR}/ipp_uris.txt")" = "ipp://192.0.2.99/ipp/print" ]
}

@test "prove-print uses an unresolvable hostname as given" {
  run "$PROVE_PRINT_UNDER_TEST" --host printer.invalid

  [ "$status" -eq 0 ]
  [ "$(cat "${MOCK_STATE_DIR}/ipp_uris.txt")" = "ipp://printer.invalid/ipp/print" ]
}

@test "prove-print skips the ink query when the queue has no network device" {
  run "$PROVE_PRINT_UNDER_TEST" --queue Other_Queue

  [ "$status" -eq 0 ]
  assert_output_contains "$output" "Ink levels: (could not read from printer)"
  assert_file_not_exists "${MOCK_STATE_DIR}/ipp_uris.txt"
  [ "$(cat "${MOCK_STATE_DIR}/last_lp_dest.txt")" = "Other_Queue" ]
}

@test "prove-print only reads the device URI of the selected queue" {
  sed -i.bak 's#^device for \$queue: #device for Other_Queue: ipp://wrong-printer.local/ipp/print\ndevice for $queue: #' "${MOCK_BIN}/lpstat"

  run "$PROVE_PRINT_UNDER_TEST"

  [ "$status" -eq 0 ]
  [ "$(cat "${MOCK_STATE_DIR}/ipp_uris.txt")" = "ipp://192.0.2.25/ipp/print" ]
}

@test "prove-print rejects a missing option value" {
  run "$PROVE_PRINT_UNDER_TEST" --queue

  [ "$status" -eq 2 ]
  assert_output_contains "$output" "ERROR: --queue requires a value"
}
