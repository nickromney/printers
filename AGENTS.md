# printers agent guide

- Keep device-specific scripts, docs and tests under the matching manufacturer directory (`hp/`). Keep raw captures out of git; `diagnostics-output/` is ignored.
- Diagnostics are read-only. Repair is an explicit mutation.

## Verify

- `make check-local` (also the pre-push gate after `lefthook install`): bats `hp/tests`, shellcheck, bash complexity ceiling of 10, `git diff --check`. No live printer is needed.
- `make test`: bats fixtures only.
- Prerequisites: `bats`, `shellcheck`, `lefthook`.

## Hazards

- `./hp/repair.sh --execute` may reset the device, clear stuck jobs and disable ePrint. `repair.sh` prints help unless given `--execute` or `--fix`.
- `./hp/lucky.sh` and `hp/prove-print.sh` send physical print jobs that consume paper and ink.
- `--save-raw` writes unmodified device responses to timestamped directories.
- Reachability and queue acceptance are not proof that a page printed.
