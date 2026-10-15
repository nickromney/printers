#!/usr/bin/env bats

setup() {
  CONTROL="$BATS_TEST_DIRNAME/../scripts/control.sh"
  CONTROL_BASH="${VERIFY_TEST_BASH:-/bin/bash}"
}

@test "unknown command is refused" {
  run "$CONTROL_BASH" "$CONTROL" --execute invalid-command
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]]
}

@test "diagnose plan explicitly uses the read-only CLI" {
  run "$CONTROL_BASH" "$CONTROL" --dry-run diagnose
  [ "$status" -eq 0 ]
  [[ "$output" == *"diagnostics.sh --plain"* ]]
}
