# Repository Guidelines

## Project Structure & Modules
- `src/`: Core Relay library modules.
- `tests/`: Executable test programs plus `tests/ci.nims` test task.
- `examples/`: Small runnable usage examples.
- Root files:
  - `relay.nimble`: package metadata and test task.
  - `README.md`: API and usage docs.
  - `config.nims` / `nim.cfg`: compiler and path configuration.

## Build, Test, and Development
- Dependency workflow: use Atlas workspace/deps setup when working in a larger Atlas environment.
- Do not add Nimble-based dependency install steps to docs/automation for this repo.
- Run all tests:
  - `nim test tests/ci.nims`
- Run a single test:
  - `nim c -r tests/test_batch_helpers.nim`
  - `nim c -r tests/test_ordering_contract.nim`
  - `nim c -r tests/test_lifecycle_contracts.nim`
- Build an example:
  - `nim c -r examples/basic_get.nim`

## Coding Style & Naming
- Indentation: 2 spaces, no tabs.
- Nim naming:
  - Types/enums: `PascalCase`
  - Procs/vars/fields: `camelCase`
  - Modules/files: lowercase with underscores where helpful.
- Keep ARC/ownership-sensitive code explicit and easy to inspect (`move`, `sink`).

## Testing Guidelines
- This project does **not** use `unittest`.
- Tests are standalone Nim programs that use `doAssert` and exit non-zero on failure.
- Add new tests under `tests/` and follow current naming pattern: `test_<topic>.nim`.
- Prefer deterministic tests (loopback/local behavior, bounded timeouts).

## Commit & Pull Requests
- Commit messages: short, imperative (example: `use mvalues in inFlight loops`).
- PRs should include:
  - clear behavior change summary
  - memory-model / ownership notes for ARC-related edits
  - test coverage notes (which test files were added/updated)
- Keep CI green (`nim test tests/ci.nims`) before merge.
