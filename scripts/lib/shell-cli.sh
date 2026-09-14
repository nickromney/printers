#!/usr/bin/env bash
# shellcheck shell=bash

shell_cli_script_name() {
  if [[ -n "${SHELL_CLI_SCRIPT_NAME_OVERRIDE:-}" ]]; then
    printf '%s\n' "${SHELL_CLI_SCRIPT_NAME_OVERRIDE}"
    return 0
  fi

  basename "$0"
}

shell_cli_usage_line() {
  local suffix="${1:-}"

  printf 'Usage: %s%s\n' "$(shell_cli_script_name)" "${suffix}"
}

shell_cli_unknown_flag() {
  local script_name="$1"
  local flag="$2"

  printf '%s: unknown flag: %s\n' "${script_name}" "${flag}" >&2
}

shell_cli_unexpected_arg() {
  local script_name="$1"
  local arg="$2"

  printf '%s: unexpected argument: %s\n' "${script_name}" "${arg}" >&2
}

shell_cli_missing_value() {
  local script_name="$1"
  local flag="$2"

  printf '%s: missing value for %s\n' "${script_name}" "${flag}" >&2
}

shell_cli_print_command() {
  local first=1
  local arg=""

  for arg in "$@"; do
    if [[ "${first}" -eq 0 ]]; then
      printf ' '
    fi
    printf '%q' "${arg}"
    first=0
  done
}

shell_cli_print_dry_run_command() {
  printf 'INFO dry-run: '
  shell_cli_print_command "$@"
  printf '\n'
}

shell_cli_print_dry_run_summary() {
  printf 'INFO dry-run: %s\n' "$*"
}

shell_cli_json_string() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '"%s"' "${value}"
}

shell_cli_entrypoint_descriptor() {
  local script_path="$0"

  printf '{"schema_version":"shell-entrypoint/v1","name":'
  shell_cli_json_string "$(shell_cli_script_name)"
  printf ',"path":'
  shell_cli_json_string "${script_path}"
  printf ',"supports":["--help","--dry-run","--execute"],"default_mode":"dry-run"}\n'
}

shell_cli_standard_options() {
  cat <<'EOF'
Options:
  --dry-run  Show a summary and exit before side effects
  --execute  Execute the script body; without it the script prints help and/or preview output
  --shell-entrypoint-descriptor
             Print machine-readable entrypoint contract metadata
  -h, --help Show this message
EOF
}

shell_cli_init_standard_flags() {
  SHELL_CLI_DRY_RUN=0
  SHELL_CLI_EXECUTE=0
}

shell_cli_handle_standard_flag() {
  local usage_fn="$1"
  local arg="$2"

  case "${arg}" in
    -h|--help)
      "${usage_fn}"
      exit 0
      ;;
    --dry-run)
      SHELL_CLI_DRY_RUN=1
      return 0
      ;;
    --execute)
      SHELL_CLI_EXECUTE=1
      return 0
      ;;
    --shell-entrypoint-descriptor)
      shell_cli_entrypoint_descriptor
      exit 0
      ;;
  esac

  return 1
}

shell_cli_parse_standard_only() {
  local usage_fn="$1"
  local script_name

  shift
  script_name="$(shell_cli_script_name)"
  shell_cli_init_standard_flags
  SHELL_CLI_ARGS=()
  SHELL_CLI_ARG_COUNT=0

  while [[ $# -gt 0 ]]; do
    if shell_cli_handle_standard_flag "${usage_fn}" "$1"; then
      shift
      continue
    fi

    case "$1" in
      --)
        shift
        break
        ;;
      -*)
        shell_cli_unknown_flag "${script_name}" "$1"
        return 1
        ;;
      *)
        break
        ;;
    esac
    shift
  done

  SHELL_CLI_ARGS=("$@")
  SHELL_CLI_ARG_COUNT=$#
}

shell_cli_maybe_execute_or_preview() {
  local usage_fn="$1"
  local preview_fn="$2"

  if [[ "${SHELL_CLI_DRY_RUN}" -eq 1 ]]; then
    "${preview_fn}"
    exit 0
  fi

  if [[ "${SHELL_CLI_EXECUTE}" -ne 1 ]]; then
    "${usage_fn}"
    "${preview_fn}"
    exit 0
  fi
}

shell_cli_maybe_execute_or_preview_summary() {
  local usage_fn="$1"
  local dry_run_summary="$2"

  if [[ "${SHELL_CLI_DRY_RUN}" -eq 1 ]]; then
    shell_cli_print_dry_run_summary "${dry_run_summary}"
    exit 0
  fi

  if [[ "${SHELL_CLI_EXECUTE}" -ne 1 ]]; then
    "${usage_fn}"
    shell_cli_print_dry_run_summary "${dry_run_summary}"
    exit 0
  fi
}

shell_cli_require_no_args() {
  local script_name

  script_name="$(shell_cli_script_name)"
  if [[ "$#" -gt 0 ]]; then
    shell_cli_unexpected_arg "${script_name}" "$1"
    return 1
  fi
}

shell_cli_handle_standard_no_args() {
  local usage_fn="$1"
  local dry_run_summary="$2"

  shift 2
  shell_cli_parse_standard_only "${usage_fn}" "$@" || exit 1
  if [[ "${SHELL_CLI_ARG_COUNT}" -gt 0 ]]; then
    shell_cli_require_no_args "${SHELL_CLI_ARGS[@]}" || exit 1
  fi

  shell_cli_maybe_execute_or_preview_summary "${usage_fn}" "${dry_run_summary}"
}
