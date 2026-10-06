# Changelog

## Unreleased

Dependency-direction tests guard the declared dependency sets and module references in `lib/`. Runtime adapter references are confined to their integration files.

First public release.

### Changed

- `Runner` runs its waves through `MimirWorkflows.Runner`. Results are the steps' values, no longer
  `{:ok, value}`.
- A step that times out or crashes returns `{:error, {:step_crashed, step_id, reason}}` instead of exiting the
  caller.
- A step's input sees its dependencies' results only, not every earlier result.
- `Exec.run/3` forwards `:step_timeout`.
- A step that returns anything other than `{:ok, _}` or `{:error, _}` fails with
  `{:error, {:step_failed, step_id, {:bad_return, term}}}`.
