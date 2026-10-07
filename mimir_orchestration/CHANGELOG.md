# Changelog

## Unreleased

Dependency-direction tests guard the declared dependency sets and module references in `lib/`. Runtime adapter references are confined to their integration files.

First public release.

### Added

- `Compiler`, `Policy` and `Compiled`: a string-keyed workflow of agent, tool and model steps, checked by
  `MimirWorkflows`' built-in passes plus `Passes.Kind`, `Passes.Policy` and `Passes.Budget` against the host's
  agent registry, tool allowlist and budget ceiling. `Eval.plan_score/2` reports diagnostics without running.
- `MimirOrchestration.Executor`, the execution seam: `Runner.run/2` builds one plain-data
  `MimirOrchestration.Executor.Payload` and hands it to the executor named by the new `:executor` option.
  `MimirOrchestration.Executor.InMemory` is the default. Routing, the grant, the turn guard and the step span stay in
  `Executor.run_step/4`, which every executor calls once per step.
- `Runner.run/2` takes `:params`, which step inputs resolve against, and `:halt`.
- `Exec.run/3` takes `:executor`.
- `AgentRunner` (default `AgentRunner.RMA` over the optional `req_managed_agents`), `Steps.ToolStep`,
  `Steps.LlmStep` (over the optional `req_llm`), `NodeResult`, and `AgentTool` with the optional `jido`.

### Changed

What differs from the source tree this package was built from before publishing, for hosts that used it as a
path dependency; no earlier version is on Hex.

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
- `Runner.run/2`'s `:run_fun` closure is now `:run`, an MFA invoked as
  `apply(m, f, [%MimirOrchestration.StepCall{} | extra_args])`. What the closure captured travels in `extra_args`.
  A plain-data `:run` of another shape returns `{:error, {:not_a_callable, run}}`.
- Step inputs that are templates are `%MimirOrchestration.StepInput{}` data, resolved at dispatch, instead of
  closures.
- `Runner.run/2` refuses a run whose steps or options (every option it reads but `:executor`) carry a function, pid, reference or port,
  at any depth, with `{:error, {:not_serialisable, path, kind}}`, and runs no step.
- Tool callables, `Policy.allowed_tools` values and `LlmStep`'s `:chat` (was `:chat_fun`) are MFAs,
  `{module, function, extra_args}`. A tool is invoked as `apply(m, f, [input | extra_args])`. A
  `{module, function}` callable fails the step with `{:not_a_callable, callable}`; a `fun/1` anywhere in the steps is
  refused before any step runs with `{:error, {:not_serialisable, path, :function}}` (a direct
  `Steps.ToolStep.run/3` call returns `{:error, {:not_a_callable, fun}}`). The chat MFA receives
  `%{model: model, prompt: prompt}` as its first argument, where `:chat_fun` received model, prompt and options as
  three arguments.
- An llm step with no `:chat` and no `req_llm` fails with
  `{:error, {:step_failed, step_id, {:missing_dependency, :req_llm}}}` instead of crashing with a `RuntimeError`;
  `LlmStep.run/2` itself returns `{:error, {:missing_dependency, :req_llm}}`.
- Through `Exec.run/3`, the agent runner options cross the executor seam: req_managed_agents' session `:handler`
  must be a module, and `AgentRunner.RMA`'s `:provision_fun` and `:session_fun` closures are refused with
  `{:error, {:not_serialisable, path, :function}}`. Direct calls to `AgentRunner.RMA.run/3` keep them.
