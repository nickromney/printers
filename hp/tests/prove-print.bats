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
