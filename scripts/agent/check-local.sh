#!/usr/bin/env bash
set -euo pipefail
agent_gate_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$agent_gate_root"
# Gates are acceptance, never skip-capable runtime dispatch.
if [[ "${LEFTHOOK:-}" == "0" ]]; then
  echo "Refusing disabled acceptance gate" >&2
  exit 1
fi
agent_gate_tmp="$(mktemp -d "${TMPDIR:-/tmp}/agent-local-gate.XXXXXX")"
trap 'rm -rf "$agent_gate_tmp"' EXIT
export GOTOOLCHAIN=local
export GOCACHE="${GOCACHE:-$agent_gate_tmp/go-cache}"
bats --jobs 8 hp/tests
shellcheck -x hp/*.sh hp/lib/*.sh hp/tests/test_helper.bash
MAX_COMPLEXITY=10 scripts/check-bash-complexity.sh --execute
git diff --check
