defmodule MimirOrchestration.Runner do
  @moduledoc """
  Runs lowered steps through an executor (`MimirOrchestration.Executor`). Each
  routed step gets a grant and a turn guard from the router; `route: false` steps
  skip routing. With the default executor, when a step fails the rest of its wave
  finishes, then the run stops.

  Options:

    * `:run` (required) — an MFA `{module, function, extra_args}`, invoked once per
      step as `apply(module, function, [%MimirOrchestration.StepCall{} | extra_args])`.
      It returns `{:ok, value}` or `{:error, reason}`; anything else fails the step
      with `{:bad_return, other}`. A plain-data `:run` of another shape returns
      `{:error, {:not_a_callable, run}}` and no step runs.
    * `:router` — `{module, opts}`, where `module` implements `Mimir.RouterClient`.
    * `:workflow_id` — default a random `"wf-…"`.
    * `:params` — the run's params, which `%MimirOrchestration.StepInput{}` inputs
      resolve against; default `%{}`.
    * `:max_concurrency` — default 4.
    * `:step_timeout` — default 120 000 ms; `:infinity` allowed. A step that outlives
      it returns `{:error, {:step_crashed, step_id, :timeout}}`.
    * `:halt` — `:after_phase` (default) or `:immediate`.
    * `:executor` — a `MimirOrchestration.Executor`; default
      `MimirOrchestration.Executor.InMemory`.

  Steps and options are plain data: a function, pid, reference or port anywhere in
  the steps or in any of the options above but `:executor` returns
  `{:error, {:not_serialisable, path, kind}}` and no step runs (see
  `MimirOrchestration.Executor.Payload`).

  A missing `:run` raises `KeyError`, and an `:executor` without `execute/1` raises
  `UndefinedFunctionError`. An executor's own raise propagates to the caller. The
  default executor raises `ArgumentError` for a `:halt` other than `:after_phase`
  or `:immediate`.

  A step's `input` is plain data, passed to `:run` as it is, or a
  `%MimirOrchestration.StepInput{}` resolved at dispatch against the step's
  dependencies' results.

  The route request is flat: the step descriptor's fields at the top level, plus
  `:workflow_id`, `:step_id`, `:parent_step_id`, `:fanout_hint` and `:path`. A
  descriptor that carries any of those names loses them: the runner's values win.
  `:parent_step_id` is the step's first dependency, `nil` for none. A
  routed step fails with `{:routing_failed, reason}`, where `reason` is
  `:no_router`, `:no_candidate`, `:no_grant` (a placement without a grant),
  `{:invalid_route_response, other}` (an `{:ok, other}` that is not a
  `Mimir.RouteResponse`), or the router's own error.
  A router that raises, exits, throws or returns something other than
  `{:ok, _}` or `{:error, _}` fails the step with `{:step_crashed, step_id, reason}`,
  not `{:routing_failed, _}`.
  """
  alias MimirOrchestration.Executor.Payload

  @type step :: %{
          required(:id) => String.t(),
          required(:depends_on) => [String.t()],
          required(:target) => term(),
          required(:input) => term(),
          required(:descriptor) => map(),
          optional(:route) => boolean()
        }
  @type result ::
          {:ok, %{results: %{String.t() => term()}, workflow_id: String.t()}} | {:error, term()}

  @spec run([step()], keyword()) :: result()
  def run(steps, opts) do
    executor = Keyword.get(opts, :executor, MimirOrchestration.Executor.InMemory)
    with {:ok, payload} <- Payload.new(steps, opts), do: executor.execute(payload)
  end
end
