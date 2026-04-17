#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HP_COMMAND_MODE=repair exec "$script_dir/lib/printer-common.sh" "$@"
