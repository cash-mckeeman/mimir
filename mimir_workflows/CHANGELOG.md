# Changelog

## 0.7.0 (2026-10-07)

First release on Hex.

Dependency-direction tests guard the declared dependency sets and module references in `lib/`.

### Added

- `Spec`, `Diagnostic`, `Compiler` and `Compiler.Pass`: a string-keyed workflow IR, validated by built-in schema,
  DAG and reference passes plus any passes the host supplies; every pass's diagnostics are returned together.
- `Template`: `{{ref}}` resolution against earlier results and run parameters.
- `Graph` and `Dag`: edge-list reachability, cycle detection and minimal-phase `waves/1`.
- `Step`, `Runner` and `Result`: a reference executor that runs each phase concurrently, kills a step at its
  timeout and reports it as `{:step_crashed, step_id, :timeout}`, emits run and step telemetry, and folds usage.
- `Runner.run/2` takes `halt: :after_phase` to let a failing phase finish before the run stops.
- Step results may be any term; `Result.usage/1` skips results that are not maps.
