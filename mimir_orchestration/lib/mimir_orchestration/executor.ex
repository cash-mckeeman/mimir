defmodule MimirOrchestration.Executor do
  @moduledoc """
  The execution seam. `MimirOrchestration.Runner.run/2` builds one
  `MimirOrchestration.Executor.Payload` and hands it to the executor named by its
  `:executor` option, `MimirOrchestration.Executor.InMemory` by default.

  An executor owns scheduling. It runs the payload's steps wave by wave, as
  `MimirWorkflows.Dag.waves/1` groups them, and calls `run_step/4` once per step
  with the results of the step's dependencies as `upstream` and the size of its wave
  as `fanout`. The payload's `max_concurrency`, `step_timeout` and `halt` are
  settings for the executor to apply; `MimirOrchestration.Executor.InMemory`
  applies them as `MimirOrchestration.Runner.run/2` documents. Routing, the grant,
  the turn guard, the dispatch through the `:run` MFA and the
  `[:mimir_orchestration, :step]` telemetry span all happen inside `run_step/4`, so
  every executor gets them unchanged. The payload is plain data, so an executor may
  persist it and run it in another process or node.

  `execute/1` is synchronous: it returns `t:MimirOrchestration.Runner.result/0`
  once the run has finished. On success that is
  `{:ok, %{results: results, workflow_id: workflow_id}}`, where `results` maps each
  step id to the `value` of its `{:ok, value}`. Otherwise it is the first failure,
  in the shapes callers of `Runner.run/2` match on:

    * `{:error, {:step_failed, step_id, reason}}` when `run_step/4` returns
      `{:error, reason}`;
    * `{:error, {:step_crashed, step_id, reason}}` when a step raises, exits or
      throws (`reason` is `{kind, reason}`) or outlives `step_timeout` (`reason` is
      `:timeout`);
    * `{:error, :cyclic}` or `{:error, {:unknown_dependency, step_id}}`, from
      `MimirWorkflows.Dag.waves/1`, when the steps' dependencies are not a DAG.
  """
  alias MimirOrchestration.Executor.Payload
  alias MimirOrchestration.{Runner, StepCall, StepInput}

  @callback execute(Payload.t()) :: Runner.result()

  @correlation_keys [:path, :workflow_id, :step_id, :fanout_hint, :parent_step_id]
  @correlation_names Enum.map(@correlation_keys, &Atom.to_string/1)

  @doc """
  Runs one step. `upstream` holds the results of the step's dependencies; `fanout`
  is the size of its wave, sent to the router as `fanout_hint`.

  A `%MimirOrchestration.StepInput{}` input is resolved against `upstream` and the
  payload's params first; an unresolved reference is the step's error, and nothing
  is routed or dispatched.
  """
  @spec run_step(Payload.t(), Payload.step(), %{optional(String.t()) => term()}, pos_integer()) ::
          {:ok, term()} | {:error, term()}
  def run_step(%Payload{} = payload, step, upstream, fanout) do
    meta = %{
      workflow_id: payload.workflow_id,
      step_id: step.id,
      path: topology_path(payload, step)
    }

    :telemetry.span([:mimir_orchestration, :step], meta, fn ->
      result =
        case resolve(step.input, upstream, payload.params) do
          {:ok, input} -> dispatch(%{step | input: input}, fanout, payload)
          {:error, _} = error -> error
        end

      {result, meta}
    end)
  end

  defp resolve(%StepInput{} = input, upstream, params),
    do: StepInput.resolve(input, upstream, params)

  defp resolve(data, _upstream, _params), do: {:ok, data}

  defp dispatch(%{route: false} = step, _fanout, payload),
    do: call(payload, step, metadata(payload, step, %{}))

  defp dispatch(_step, _fanout, %Payload{router: nil}),
    do: {:error, {:routing_failed, :no_router}}

  defp dispatch(step, fanout, payload) do
    {router, router_opts} = payload.router

    case router.route(route_request(step, fanout, payload), router_opts) do
      {:ok, %Mimir.RouteResponse{verdict: :no_candidate}} ->
        {:error, {:routing_failed, :no_candidate}}

      {:ok, %Mimir.RouteResponse{verdict: :placement, grant: nil}} ->
        {:error, {:routing_failed, :no_grant}}

      {:ok, %Mimir.RouteResponse{verdict: :placement} = resp} ->
        call(payload, step, routed_opts(payload, step, resp))

      {:ok, other} ->
        {:error, {:routing_failed, {:invalid_route_response, other}}}

      {:error, reason} ->
        {:error, {:routing_failed, reason}}
    end
  end

  # Flat, as Mimir.RouterClient.route/2 documents: the descriptor's fields at the
  # top level, plus the correlation ids. A descriptor's own correlation names are
  # dropped, in atom and string form, so the runner's values are the only ones sent.
  defp route_request(step, fanout, payload) do
    step.descriptor
    |> Map.drop(@correlation_keys ++ @correlation_names)
    |> Map.merge(%{
      workflow_id: payload.workflow_id,
      step_id: step.id,
      # Data-dependency edge ("whose output did I consume"), distinct from
      # `path`'s spawn-lineage edge ("who created me").
      parent_step_id: List.first(step.depends_on),
      fanout_hint: fanout,
      path: topology_path(payload, step)
    })
  end

  defp routed_opts(payload, step, resp) do
    payload
    |> metadata(step, %{mimir_request_id: resp.decision_id, decision_id: resp.decision_id})
    |> Keyword.put(:model, %{"key" => resp.grant.key, "model" => resp.placement.model})
    |> Keyword.put(:turn_guard, Mimir.Guard.for_grant(resp.grant, resp.placement.model))
  end

  defp call(%Payload{run: {module, function, extra_args}}, step, opts) do
    call = %StepCall{target: step.target, input: step.input, opts: opts}

    case apply(module, function, [call | extra_args]) do
      {:ok, _} = ok -> ok
      {:error, _} = error -> error
      other -> {:error, {:bad_return, other}}
    end
  end

  defp metadata(payload, step, extra) do
    base = %{
      workflow_id: payload.workflow_id,
      step_id: step.id,
      path: topology_path(payload, step)
    }

    [metadata: Map.merge(base, extra)]
  end

  # The scopes this runner creates, outermost first: the workflow, then the step.
  # The same path goes down every channel (route body, dispatch metadata, telemetry).
  defp topology_path(payload, step),
    do: ["workflow:" <> payload.workflow_id, "workflow_step:" <> step.id]
end
