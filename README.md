# printers

Manufacturer-scoped printer tooling and notes.

## Layout

- [`hp/`](./hp/) contains the current HP diagnostics and repair wrappers, shared implementation, documentation, and tests.
- `brother/` and `canon/` are reserved for future manufacturer-specific tooling.

## Current Support

- HP: see [`hp/README.md`](./hp/README.md)

## Compatibility Notice

This repository is an unofficial collection of compatibility tooling. It is not affiliated with, endorsed by, or sponsored by HP, Brother, Canon, or any other printer vendor. Manufacturer names are used only to describe device compatibility.

## Repository Rules

- Keep device-specific scripts, docs, and tests under the matching manufacturer directory.
- Keep raw captures out of git. Any `diagnostics-output/` directory is ignored repository-wide.
