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
- `MimirOrchestration.RouterClient` is removed: `:router` takes a `Mimir.RouterClient` implementation, which
  returns `Mimir.RouteResponse`.
- The route request is flat: descriptor fields at the top level, as `Mimir.RouterClient` documents. A
  descriptor's own `workflow_id`, `step_id`, `parent_step_id`, `fanout_hint` or `path` is dropped, so the
  runner's values are the only ones sent.
- A router response that is not a `Mimir.RouteResponse` fails the step with
  `{:routing_failed, {:invalid_route_response, response}}`, and a placement without a grant with
  `{:routing_failed, :no_grant}`. The raw-decision path, and the placement `base_url` it passed into the model map,
  are gone.
- A routed step with no `:router` fails with `{:routing_failed, :no_router}` instead of crashing.
- req_managed_agents is optional (`>= 0.10.0 and < 0.11.0`): without it, the default agent runner returns
  `{:error, {:missing_dependency, :req_managed_agents}}`.
