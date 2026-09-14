#!/usr/bin/env bats

load test_helper

setup() {
  setup_mock_printer_env
}

sample_lines() {
  printf '%s\n' "$1" | grep -c '^\[<timestamp>\] cups='
}

@test "monitor samples an active job up to the sample limit" {
  set_mock_state job_list_mode processing
  set_mock_state product_logs_mode single-line-error

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --monitor-printing --samples 3 --interval 0 --output-dir "$MOCK_OUTPUT_DIR"

  [ "$status" -eq 0 ]
  monitor="$(scrub_output "${output#*== During Printing Monitor ==}")"
  diff -u "${BATS_TEST_DIRNAME}/fixtures/monitor-active.expected" <(printf '%s\n' "$monitor")
  [ -f "${MOCK_OUTPUT_DIR}/monitor/"003-*/jobs-joblist.xml ]
  [ ! -e "${MOCK_OUTPUT_DIR}/monitor/"004-* ]
}

@test "monitor stops after the first sample when nothing is printing" {
  set_mock_state job_list_mode empty
  set_mock_state status_mode ready

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --monitor-printing --samples 5 --interval 0

  [ "$status" -eq 0 ]
  monitor="$(scrub_output "${output#*== During Printing Monitor ==}")"
  [ "$(sample_lines "$monitor")" -eq 1 ]
  assert_output_contains "$monitor" "Monitor stopping because no active print job was detected on the first sample."
  assert_output_not_contains "$monitor" "hp-job:"
  assert_output_not_contains "$monitor" "raw-sample-dir"
  assert_output_contains "$monitor" "  hp-status: ready"
}

@test "monitor treats queued IPP jobs as activity" {
  set_mock_state ipp_mode spool-full
  set_mock_state status_mode ready

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --monitor-printing --samples 2 --interval 0

  [ "$status" -eq 0 ]
  monitor="$(scrub_output "${output#*== During Printing Monitor ==}")"
  [ "$(sample_lines "$monitor")" -eq 2 ]
  assert_output_contains "$monitor" "queued=1"
  assert_output_contains "$monitor" "  ipp-job: job-id=42 job-name=report.pdf job-state=processing reasons=job-printing impressions=1/3"
  assert_output_not_contains "$monitor" "Monitor stopping"
}

@test "monitor stops once an active printer returns to idle" {
  set_mock_state job_list_mode processing
  set_mock_state status_mode ready
  # The real curl mock flips the job list to completed after one sampled read.
  mv "${MOCK_BIN}/curl" "${MOCK_BIN}/curl-real"
  cat > "${MOCK_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
state_dir="${MOCK_PRINTER_STATE_DIR:?}"
case "$*" in
  */Jobs/JobList*)
    count="$(cat "${state_dir}/joblist_reads" 2>/dev/null || printf 0)"
    count=$((count + 1))
    printf '%s\n' "$count" > "${state_dir}/joblist_reads"
    # Report read + first monitor sample see the job; later samples do not.
    [ "$count" -le 2 ] || printf 'empty\n' > "${state_dir}/job_list_mode"
    ;;
esac
exec "$(dirname "$0")/curl-real" "$@"
EOF
  chmod +x "${MOCK_BIN}/curl"

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --monitor-printing --samples 5 --interval 0

  [ "$status" -eq 0 ]
  monitor="$(scrub_output "${output#*== During Printing Monitor ==}")"
  [ "$(sample_lines "$monitor")" -eq 2 ]
  assert_output_contains "$monitor" "Monitor stopping early because the printer returned to idle after an active print state."
}

@test "monitor honours the sample interval between samples only" {
  set_mock_state job_list_mode processing
  cat > "${MOCK_BIN}/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${MOCK_PRINTER_STATE_DIR}/sleeps.txt"
EOF
  chmod +x "${MOCK_BIN}/sleep"

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --monitor-printing --samples 3 --interval 7

  [ "$status" -eq 0 ]
  [ "$(grep -c '^7$' "${MOCK_STATE_DIR}/sleeps.txt")" -eq 2 ]
}

@test "monitor ignores completed HP job history when deciding activity" {
  set_mock_state job_list_mode completed
  set_mock_state status_mode ready

  run "$SCRIPT_UNDER_TEST" --host 192.0.2.25 --monitor-printing --samples 5 --interval 0

  [ "$status" -eq 0 ]
  monitor="$(scrub_output "${output#*== During Printing Monitor ==}")"
  [ "$(sample_lines "$monitor")" -eq 1 ]
  assert_output_contains "$monitor" "  hp-job: job-url=/Jobs/JobList/10 category=Print state=Completed update=239-42"
  assert_output_contains "$monitor" "Monitor stopping because no active print job was detected on the first sample."
}
