defmodule MimirOrchestration.Test.SequentialExecutor do
  @moduledoc false
  # A second executor written against the seam alone: it takes the payload through the
  # external term format into a fresh process and runs one step at a time, wave by
  # wave, through Executor.run_step/4.
  @behaviour MimirOrchestration.Executor

  alias MimirOrchestration.Executor

  @impl true
  def execute(payload) do
    binary = :erlang.term_to_binary(payload)
    fn -> run(:erlang.binary_to_term(binary)) end |> Task.async() |> Task.await(:infinity)
  end

  defp run(payload) do
    {:ok, waves} =
      MimirWorkflows.Dag.waves(Enum.map(payload.steps, &Map.take(&1, [:id, :depends_on])))

    index = Map.new(payload.steps, &{&1.id, &1})

    waves
    |> Enum.reduce_while({:ok, %{}}, &run_wave(payload, index, &1, &2))
    |> case do
      {:ok, results} -> {:ok, %{results: results, workflow_id: payload.workflow_id}}
      error -> error
    end
  end

  defp run_wave(payload, index, wave, {:ok, acc}) do
    outcomes =
      for id <- wave do
        step = index[id]
        {id, Executor.run_step(payload, step, Map.take(acc, step.depends_on), length(wave))}
      end

    case Enum.find(outcomes, &match?({_, {:error, _}}, &1)) do
      nil -> {:cont, {:ok, Map.merge(acc, Map.new(outcomes, fn {id, {:ok, v}} -> {id, v} end))}}
      {id, {:error, reason}} -> {:halt, {:error, {:step_failed, id, reason}}}
    end
  end
end
