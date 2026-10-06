defmodule MimirOrchestration.Runner do
  @moduledoc """
  Runs lowered steps wave by wave through `MimirWorkflows.Runner`. Each routed step
  gets a grant and a turn guard from the router; `route: false` steps skip routing.
  When a step fails, the rest of its wave finishes, then the run stops.

  Options: `:run_fun` (required), `:router` (`{module, opts}`, where `module`
  implements `Mimir.RouterClient`), `:workflow_id`, `:max_concurrency` (default 4),
  `:step_timeout` (default 120 000 ms; `:infinity` allowed). A step that outlives
  `:step_timeout` returns `{:error, {:step_crashed, step_id, :timeout}}`.

  The route request is flat: the step descriptor's fields at the top level, plus
  `:workflow_id`, `:step_id`, `:parent_step_id`, `:fanout_hint` and `:path`. A
  routed step fails with `{:routing_failed, reason}`, where `reason` is
  `:no_router`, `:no_candidate`, `:no_grant` (a placement without a grant),
  `{:invalid_route_response, other}` (an `{:ok, other}` that is not a
  `Mimir.RouteResponse`), or the router's own error.
  """
  alias MimirOrchestration.Runner.{Ctx, WorkflowStep}
  alias MimirWorkflows.Dag

  @default_max_concurrency 4
  @default_step_timeout 120_000

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
    ctx = %Ctx{
      router: Keyword.get(opts, :router),
      run_fun: Keyword.fetch!(opts, :run_fun),
      workflow_id: Keyword.get_lazy(opts, :workflow_id, fn -> "wf-" <> random_id() end),
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
      step_timeout: Keyword.get(opts, :step_timeout, @default_step_timeout)
    }

    with {:ok, waves} <- Dag.waves(Enum.map(steps, &%{id: &1.id, depends_on: &1.depends_on})) do
      fanout = for wave <- waves, id <- wave, into: %{}, do: {id, length(wave)}

      steps
      |> Enum.map(
        &%{
          id: &1.id,
          module: WorkflowStep,
          depends_on: &1.depends_on,
          params: %{step: &1, ctx: ctx, fanout: Map.fetch!(fanout, &1.id)}
        }
      )
      |> MimirWorkflows.Runner.run(
        max_concurrency: ctx.max_concurrency,
        timeout: ctx.step_timeout,
        halt: :after_phase,
        telemetry_meta: %{workflow_id: ctx.workflow_id}
      )
      |> case do
        {:ok, results} -> {:ok, %{results: results, workflow_id: ctx.workflow_id}}
        {:error, _} = error -> error
      end
    end
  end

  defp random_id, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
