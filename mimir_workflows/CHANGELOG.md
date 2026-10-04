# Changelog

## Unreleased

First public release.

### Added

- `Spec`, `Diagnostic`, `Compiler` and `Compiler.Pass`: a string-keyed workflow IR, validated by built-in schema,
  DAG and reference passes plus any passes the host supplies; every pass's diagnostics are returned together.
- `Template`: `{{ref}}` resolution against earlier results and run parameters.
- `Graph` and `Dag`: edge-list reachability, cycle detection and minimal-phase `waves/1`.
- `Step`, `Runner` and `Result`: a reference executor that runs each phase concurrently, kills a step at its
  timeout and reports it as `{:step_crashed, step_id, :timeout}`, emits run and step telemetry, and folds usage.
