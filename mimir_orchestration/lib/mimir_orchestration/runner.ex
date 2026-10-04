defmodule MimirOrchestration.Runner do
  @moduledoc """
  Runs steps wave by wave with routing and correlation metadata.

  Routed steps receive model configuration and, for typed placements with grants,
  a turn guard. `route: false` skips routing. A returned step error halts after
  its wave finishes; task crashes and timeouts exit the caller. Input functions
  receive completed results. `:step_timeout` defaults to 120 seconds and accepts
  `:infinity` for long sessions.
  """
  alias MimirOrchestration.Runner.Ctx
  alias MimirWorkflows.Dag

  @default_max_concurrency 4
  @step_timeout 120_000

  @spec run([map()], keyword()) ::
          {:ok, %{results: map(), workflow_id: String.t()}} | {:error, term()}
  def run(steps, opts) do
    workflow_id = Keyword.get_lazy(opts, :workflow_id, fn -> "wf-" <> random_id() end)

    ctx = %Ctx{
      router: Keyword.get(opts, :router),
      run_fun: Keyword.fetch!(opts, :run_fun),
      workflow_id: workflow_id,
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
      step_timeout: Keyword.get(opts, :step_timeout, @step_timeout)
    }

    with {:ok, waves} <- Dag.waves(Enum.map(steps, &%{id: &1.id, depends_on: &1.depends_on})) do
      index = Map.new(steps, &{&1.id, &1})
      run_waves(waves, index, %{}, ctx)
    end
  end

  defp run_waves([], _index, results, ctx),
    do: {:ok, %{results: results, workflow_id: ctx.workflow_id}}

  defp run_waves([wave | rest], index, results, ctx) do
    fanout = length(wave)

    outcomes =
      wave
      |> Task.async_stream(
        fn id -> {id, run_step(resolve_input(Map.fetch!(index, id), results), fanout, ctx)} end,
        max_concurrency: min(fanout, ctx.max_concurrency),
        timeout: ctx.step_timeout,
        ordered: false
      )
      |> Enum.map(fn {:ok, pair} -> pair end)

    case Enum.find(outcomes, fn {_id, r} -> match?({:error, _}, r) end) do
      {id, {:error, reason}} -> {:error, {:step_failed, id, reason}}
      nil -> run_waves(rest, index, Enum.into(outcomes, results), ctx)
    end
  end

  defp resolve_input(%{input: fun} = step, results) when is_function(fun, 1),
    do: %{step | input: fun.(results)}

  defp resolve_input(step, _results), do: step

  defp run_step(step, fanout, ctx) do
    meta = %{workflow_id: ctx.workflow_id, step_id: step.id, path: topology_path(ctx, step)}

    :telemetry.span([:mimir_orchestration, :step], meta, fn ->
      result = dispatch(step, fanout, ctx)
      {result, meta}
    end)
  end

  # Input resolution (Exec's dataflow closure) failed before dispatch — e.g.
  # an unresolved {{ref}} in a hand-built or foreign-compiled plan. Surface
  # it as this step's error without ever calling run_fun or the router.
  defp dispatch(%{input: {:error, _} = error}, _fanout, _ctx), do: error

  defp dispatch(%{route: false} = step, _fanout, ctx) do
    ctx.run_fun.(step.target, step.input, metadata_opts(step, ctx, %{}))
  end

  defp dispatch(step, fanout, ctx) do
    {router_mod, router_opts} = ctx.router

    request = %{
      descriptor: step.descriptor,
      workflow_id: ctx.workflow_id,
      step_id: step.id,
      # Data-dependency edge ("whose output did I consume"), distinct from
      # `path`'s spawn-lineage edge ("who created me").
      parent_step_id: List.first(step.depends_on),
      fanout_hint: fanout,
      path: topology_path(ctx, step)
    }

    case router_mod.route(request, router_opts) do
      {:ok, decision} -> routed_dispatch(step, decision, ctx)
      {:error, reason} -> {:error, {:routing_failed, reason}}
    end
  end

  # A no-candidate verdict is a routing failure; never dispatch a nil grant.
  defp routed_dispatch(_step, %{"verdict" => "no_candidate"}, _ctx),
    do: {:error, {:routing_failed, :no_candidate}}

  defp routed_dispatch(_step, %{verdict: "no_candidate"}, _ctx),
    do: {:error, {:routing_failed, :no_candidate}}

  defp routed_dispatch(step, decision, ctx) do
    case typed_route(decision) do
      {:ok, resp} ->
        ctx.run_fun.(
          step.target,
          step.input,
          metadata_opts(step, ctx, %{
            mimir_request_id: resp.decision_id,
            decision_id: resp.decision_id
          })
          |> Keyword.put(
            :model,
            decision
            |> raw_model()
            |> Map.merge(%{"key" => resp.grant.key, "model" => resp.placement.model})
          )
          |> Keyword.put(:turn_guard, Mimir.Guard.for_grant(resp.grant, resp.placement.model))
        )

      :raw ->
        ctx.run_fun.(
          step.target,
          step.input,
          metadata_opts(step, ctx, %{mimir_request_id: decision["decision_id"]})
          |> Keyword.put(:model, raw_model(decision))
        )
    end
  end

  # Raw-path placements (in-process/test routers) may carry a base_url the
  # host needs to build its model config; production gateway placements
  # never send one. Present only when the placement carries it.
  defp raw_model(decision) do
    model = %{
      "key" => get_in(decision, ["grant", "key"]),
      "model" => get_in(decision, ["placement", "model"])
    }

    case get_in(decision, ["placement", "base_url"]) do
      nil -> model
      base_url -> Map.put(model, "base_url", base_url)
    end
  end

  # Typed decisions get typed handling and a turn guard;
  # anything unparseable (scripted test routers, legacy gateways) stays raw.
  defp typed_route(decision) do
    case Mimir.RouteResponse.new(decision) do
      {:ok, %Mimir.RouteResponse{verdict: :placement, grant: grant} = resp}
      when not is_nil(grant) ->
        {:ok, resp}

      _ ->
        :raw
    end
  rescue
    _ -> :raw
  end

  defp metadata_opts(step, ctx, extra) do
    base = %{workflow_id: ctx.workflow_id, step_id: step.id, path: topology_path(ctx, step)}
    [metadata: Map.merge(base, extra)]
  end

  # The runner appends the scopes it creates
  # (`workflow:` + `workflow_step:`), outermost first, and hands the
  # accumulated path down every channel it uses (route body, RMA metadata,
  # step telemetry).
  defp topology_path(ctx, step),
    do: ["workflow:" <> ctx.workflow_id, "workflow_step:" <> step.id]

  defp random_id, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
