defmodule MimirOrchestration.Executor.InMemory do
  @moduledoc """
  The reference executor: runs the payload in this node, wave by wave, through
  `MimirWorkflows.Runner`, each step through `MimirOrchestration.Executor.run_step/4`.
  """
  @behaviour MimirOrchestration.Executor

  alias MimirOrchestration.Executor
  alias MimirOrchestration.Executor.Payload
  alias MimirWorkflows.Dag

  @impl true
  def execute(%Payload{} = payload) do
    with {:ok, waves} <-
           Dag.waves(Enum.map(payload.steps, &%{id: &1.id, depends_on: &1.depends_on})) do
      fanout = for wave <- waves, id <- wave, into: %{}, do: {id, length(wave)}

      payload.steps
      |> Enum.map(
        &%{
          id: &1.id,
          module: __MODULE__.Step,
          depends_on: &1.depends_on,
          params: %{payload: payload, step: &1, fanout: Map.fetch!(fanout, &1.id)}
        }
      )
      |> MimirWorkflows.Runner.run(
        max_concurrency: payload.max_concurrency,
        timeout: payload.step_timeout,
        halt: payload.halt,
        telemetry_meta: %{workflow_id: payload.workflow_id}
      )
      |> case do
        {:ok, results} -> {:ok, %{results: results, workflow_id: payload.workflow_id}}
        {:error, _} = error -> error
      end
    end
  end

  defmodule Step do
    @moduledoc false
    @behaviour MimirWorkflows.Step

    @impl true
    def run(%{payload: payload, step: step, fanout: fanout}, upstream),
      do: Executor.run_step(payload, step, upstream, fanout)
  end
end
