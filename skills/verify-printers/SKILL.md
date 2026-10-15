# Verify the HP printer diagnostics

Run `make verify-dry-run` to preview the cycle, `make verify-test` for shellcheck and BATS contract checks, and `make verify` for a read-only invocation of the supported HP diagnostics CLI.

The cycle runs `hp/diagnostics.sh --plain`, which queries the configured local CUPS printer and its reachable status endpoints, then checks the command name and recognized printer/cloud health values. It does not invoke repair, lucky, prove-print, or send a print job. Results are limited to live diagnostic reachability and reported state; queue acceptance does not prove paper output.

State lives under `${TMPDIR:-/tmp}/verify-printers/<run>/state`; evidence lives under `${TMPDIR:-/tmp}/verify-printers-evidence/<run>` and survives cleanup. Cleanup removes only the current run's state.
