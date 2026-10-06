# printers: agent operating model

Adopted 6 October 2026 from local source and command inspection.
Gather layered printer evidence and apply explicit repair recipes only when instructed.

## Read by intent

Start with the local agent guide and build manifest. For domain or behavior
changes, follow the owners below, then the relevant contract/test. These
documents retain product detail and historical evidence:

- [README.md](../README.md)
- [hp/README.md](../hp/README.md)
- [hp/docs/diagnostic-approach.md](../hp/docs/diagnostic-approach.md)
- [hp/docs/hp-ledm-endpoints.md](../hp/docs/hp-ledm-endpoints.md)

## System ownership

| Owner | Responsibility |
| --- | --- |
| [hp/lib/printer-common.sh](../hp/lib/printer-common.sh) | Shared transports/parsers, interpretation and repair recipe |
| [hp/lib/printer-discovery.sh](../hp/lib/printer-discovery.sh) | Queue and host discovery |
| [hp/diagnostics.sh](../hp/diagnostics.sh) | Read-only diagnostics |
| [hp/repair.sh](../hp/repair.sh) | Opt-in device mutation |
| [hp/lucky.sh](../hp/lucky.sh) | Diagnostics then repair/test print convenience workflow |

Intent selects the owning policy; that policy produces decisions or artifacts;
adapters perform effects; verification establishes the result. Change the
owner once and keep alternate surfaces on that same contract.

## Invariants

- Manufacturer boundaries.
- Raw device captures excluded from git.
- Diagnostics distinct from mutation.
- Network reachability/queue acceptance is not physical printed-page proof.

## Existing action interfaces

These are inspected command surfaces, not a report that they ran. Read current
help and recipes for arguments, dependencies and lifecycle hooks before use.
Examples containing placeholder paths or bracketed options are grammar.

| Command | Effects and evidence |
| --- | --- |
| `./hp/diagnostics.sh --plain` | Reads local CUPS and device endpoints; stable key=value output |
| `./hp/diagnostics.sh --monitor-printing --interval 3 --samples 20 --save-raw` | Bounded monitoring; writes raw evidence files |
| `./hp/repair.sh` | Help by default; does not repair |
| `./hp/repair.sh --execute --host 192.0.2.25 --save-raw` | May reset device, clear stuck jobs, disable ePrint; saves raw evidence |
| `./hp/lucky.sh` | Can repair and send physical print; consumes paper/ink |
| `make test` | Bats fixtures, no live printer needed |

## Observe, verify and retain

Establish source revision, dirty state and relevant input identity before
choosing an action. Keep intended settings, cached artifacts and observed
runtime state distinct. An existing artifact is not a freshness or readiness
claim. Use the smallest deterministic fixture at the changed seam first;
expand to process, browser, device or deployment checks only when that
claim needs them. Record unavailable evidence explicitly.

Retain the command/configuration, source and input identity, result, limitation
and next discriminating check. Reuse evidence only while its relevant inputs
remain applicable. Promote a reproducible failure to a regression fixture,
a design decision to its owning document, and a repeated operator correction
to one concise guide rule. Keep private observations in private artifacts.

## Implemented plan for this pass

- [x] Map current source ownership and existing interfaces.
- [x] Make command effects and evidence limits discoverable.
- [x] Route agent work here and retain detailed product plans at their owners.

Acceptance: owner paths and document links resolve; current instructions
match inspected source; catalog hashes bind this context to the reviewed
bytes. This is documentation/control navigation acceptance. Product runtime
checks retain their own scope and are not certified by this pass.

### hp/docs/diagnostic-approach.md

Agent evidence ladder: use diagnostics --plain for current machine-readable facts, then retain timestamped raw responses when an endpoint or interpretation is uncertain. Local queue acceptance, device processing state and a physically observed printed page are different claims. repair --execute can reset the device, clear jobs and change ePrint settings. lucky and prove-print send physical print jobs and consume supplies; they are effectful acceptance actions, not routine read-only checks.
