# HP Printer Diagnostics

This directory contains a Bash-based diagnostic tool for HP printers that expose a normal CUPS queue plus HP's embedded web server endpoints.

It is an unofficial compatibility tool for printers you own or administer. It is not affiliated with, endorsed by, or sponsored by HP. "HP" is used here only to identify the supported device family.

The main script is [`diagnostics.sh`](./diagnostics.sh). It layers several checks:

- Local macOS and CUPS state
- IPP printer attributes
- HP LEDM XML endpoints under `/DevMgmt/...`
- HP service namespaces for firmware update, ePrint, and event history
- SNMP status and supply data

## Usage

Run these from the repository root:

```bash
chmod +x ./hp/diagnostics.sh
./hp/diagnostics.sh
./hp/diagnostics.sh --save-raw
./hp/diagnostics.sh --monitor-printing --interval 3 --samples 20 --save-raw
./hp/diagnostics.sh --soft-reset-pjl --save-raw
./hp/diagnostics.sh --experimental-clear-jobs --save-raw
./hp/diagnostics.sh --cancel-connecting --save-raw
./hp/diagnostics.sh --queue HP_Test_Series__ABC123_
./hp/diagnostics.sh --host 192.0.2.25 --output-dir ./hp/diagnostics-output
```

When `--save-raw` is enabled, the script writes the unmodified responses to a timestamped directory so you can inspect the raw IPP, XML, and SNMP output later.

When `--monitor-printing` is enabled, the script keeps sampling the live queue and printer state while a job is in flight. It captures:

- CUPS queue state and active jobs
- IPP printer state and `printer-state-reasons`
- IPP job state and progress counters
- HP `ProductStatusDyn.xml`
- HP `/Jobs/JobList`
- HP `ProductLogsDyn.xml`
- HP firmware-update, ePrint, and event-table endpoints

When `--soft-reset-pjl` is enabled, the script sends a soft HP PJL reset over TCP port `9100` before collecting diagnostics. This is a network soft reset, not a factory reset.

When `--experimental-clear-jobs` is enabled, the script tries to clear printer-side `Processing` jobs via HP's `/Jobs/JobList/{id}` API and falls back to a soft PJL reset if those jobs remain stuck. This path is explicitly experimental.

When `--cancel-connecting` is enabled, the script sends a `PUT` to `/ePrint/ePrintConfigDyn.xml` with only the writable ePrint fields. On tested printers that disables HP web services, sets `RegistrationState=unregistered`, and clears the HP Connected / Instant Ink panel warning without touching the local print queue.

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
shellcheck ./hp/diagnostics.sh ./hp/tests/test_helper.bash
bats ./hp/tests
```
