defmodule MimirOrchestration.Runner.WorkflowStep do
  @moduledoc false
  # One governed step, run by MimirWorkflows.Runner: resolve the input against the
  # step's dependencies' results, route it unless it has route: false, dispatch it
  # through run_fun, all inside the [:mimir_orchestration, :step] span.
  @behaviour MimirWorkflows.Step

  @correlation_keys [:path, :workflow_id, :step_id, :fanout_hint, :parent_step_id]
  @correlation_names Enum.map(@correlation_keys, &Atom.to_string/1)

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

  defp dispatch(_step, _fanout, %{router: nil}), do: {:error, {:routing_failed, :no_router}}

  defp dispatch(step, fanout, ctx) do
    {router, router_opts} = ctx.router

    case router.route(route_request(step, fanout, ctx), router_opts) do
      {:ok, %Mimir.RouteResponse{verdict: :no_candidate}} ->
        {:error, {:routing_failed, :no_candidate}}

      {:ok, %Mimir.RouteResponse{verdict: :placement, grant: nil}} ->
        {:error, {:routing_failed, :no_grant}}

      {:ok, %Mimir.RouteResponse{verdict: :placement} = resp} ->
        ctx.run_fun.(step.target, step.input, routed_opts(step, ctx, resp))

      {:ok, other} ->
        {:error, {:routing_failed, {:invalid_route_response, other}}}

      {:error, reason} ->
        {:error, {:routing_failed, reason}}
    end
  end

  # Flat, as Mimir.RouterClient.route/2 documents: the descriptor's fields at the
  # top level, plus the correlation ids. A descriptor's own correlation names are
  # dropped, in atom and string form, so the runner's values are the only ones sent.
  defp route_request(step, fanout, ctx) do
    step.descriptor
    |> Map.drop(@correlation_keys ++ @correlation_names)
    |> Map.merge(%{
      workflow_id: ctx.workflow_id,
      step_id: step.id,
      # Data-dependency edge ("whose output did I consume"), distinct from
      # `path`'s spawn-lineage edge ("who created me").
      parent_step_id: List.first(step.depends_on),
      fanout_hint: fanout,
      path: topology_path(ctx, step)
    })
  end

  defp routed_opts(step, ctx, resp) do
    step
    |> metadata_opts(ctx, %{mimir_request_id: resp.decision_id, decision_id: resp.decision_id})
    |> Keyword.put(:model, %{"key" => resp.grant.key, "model" => resp.placement.model})
    |> Keyword.put(:turn_guard, Mimir.Guard.for_grant(resp.grant, resp.placement.model))
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
