# HP Printer Diagnostics

This directory contains Bash-based diagnostic and repair tools for HP printers that expose a normal CUPS queue plus HP's embedded web server endpoints.

It is an unofficial compatibility tool for printers you own or administer. It is not affiliated with, endorsed by, or sponsored by HP. "HP" is used here only to identify the supported device family.

The main scripts are [`diagnostics.sh`](./diagnostics.sh) and [`repair.sh`](./repair.sh). They share the same layered checks but keep read-only inspection and repair actions separate:

- Local macOS and CUPS state
- IPP printer attributes
- HP LEDM XML endpoints under `/DevMgmt/...`
- HP service namespaces for firmware update, ePrint, and event history
- SNMP status and supply data

Both wrappers delegate to the shared implementation in [`lib/printer-common.sh`](./lib/printer-common.sh), which keeps the transport and parsing plumbing in one place.

## Usage

Run these from the repository root:

```bash
chmod +x ./hp/diagnostics.sh
chmod +x ./hp/repair.sh
./hp/diagnostics.sh
./hp/diagnostics.sh --save-raw
./hp/diagnostics.sh --monitor-printing --interval 3 --samples 20 --save-raw
./hp/diagnostics.sh --queue HP_Test_Series__ABC123_
./hp/diagnostics.sh --host 192.0.2.25 --output-dir ./hp/diagnostics-output
./hp/diagnostics.sh --host 192.0.2.25 --plain
./hp/repair.sh --execute --host 192.0.2.25 --save-raw
./hp/repair.sh --fix --host 192.0.2.25 --plain
```

`diagnostics.sh` is read-only. `repair.sh` prints help by default and only performs mutation when you opt into `--execute` or `--fix`.

Use `--plain` on either wrapper when you need a stable `key=value` summary for scripts or fixtures instead of the full prose report. The repair script keeps the full repair steps behind the recipe so the public surface stays simple.

When `--save-raw` is enabled, the script writes the unmodified responses to a timestamped directory so you can inspect the raw IPP, XML, and SNMP output later.

When `--monitor-printing` is enabled on `diagnostics.sh`, the script keeps sampling the live queue and printer state while a job is in flight. It captures:

- CUPS queue state and active jobs
- IPP printer state and `printer-state-reasons`
- IPP job state and progress counters
- HP `ProductStatusDyn.xml`
- HP `/Jobs/JobList`
- HP `ProductLogsDyn.xml`
- HP firmware-update, ePrint, and event-table endpoints

When `repair.sh` runs the full repair recipe, it may send a soft HP PJL reset over TCP port `9100` before collecting diagnostics. This is a network soft reset, not a factory reset.

When `repair.sh` runs the full repair recipe, it may try to clear printer-side `Processing` jobs via HP's `/Jobs/JobList/{id}` API and fall back to a soft PJL reset if those jobs remain stuck. This path is intentionally best-effort.

When `repair.sh` runs the full repair recipe, it may send a `PUT` to `/ePrint/ePrintConfigDyn.xml` with only the writable ePrint fields. On tested printers that disables HP web services, sets `RegistrationState=unregistered`, and clears the HP Connected / Instant Ink panel warning without touching the local print queue.

## What It Surfaces

- Current queue state and recent jobs
- Recent CUPS errors
- `printer-state`, `printer-state-reasons`, queue depth, uptime, alerts, and marker levels from IPP
- Repeated during-printing samples so transient states are not missed
- HP status, event codes, hidden error log entries, usage counters, jam and mispick history, and consumable details from the embedded web server
- Firmware revision, service ID, firmware-update state, ePrint connection state, consumable-subscription state, and device event history
- SNMP printer status and supply levels

## Docs

- [`docs/diagnostic-approach.md`](./docs/diagnostic-approach.md)
- [`docs/hp-ledm-endpoints.md`](./docs/hp-ledm-endpoints.md)

## Verification

```bash
shellcheck ./hp/diagnostics.sh ./hp/repair.sh ./hp/lib/printer-common.sh ./hp/tests/test_helper.bash
bats ./hp/tests
```
