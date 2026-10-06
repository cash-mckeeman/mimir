defmodule MimirOrchestration.Runner.WorkflowStep do
  @moduledoc false
  # One governed step, run by MimirWorkflows.Runner: resolve the input against the
  # step's dependencies' results, route it unless it has route: false, dispatch it
  # through run_fun, all inside the [:mimir_orchestration, :step] span.
  @behaviour MimirWorkflows.Step

  @impl true
  def run(%{step: step, ctx: ctx, fanout: fanout}, upstream) do
    meta = %{workflow_id: ctx.workflow_id, step_id: step.id, path: topology_path(ctx, step)}

    :telemetry.span([:mimir_orchestration, :step], meta, fn ->
      result = step |> resolve_input(upstream) |> dispatch(fanout, ctx) |> as_step_result()
      {result, meta}
    end)
  end

  defp as_step_result({:ok, _} = ok), do: ok
  defp as_step_result({:error, _} = error), do: error
  defp as_step_result(other), do: {:error, {:bad_return, other}}

  defp resolve_input(%{input: fun} = step, upstream) when is_function(fun, 1),
    do: %{step | input: fun.(upstream)}

  defp resolve_input(step, _upstream), do: step

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
end
