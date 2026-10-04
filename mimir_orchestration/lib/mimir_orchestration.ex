defmodule MimirOrchestration do
  @moduledoc """
  Governed agent composition: route → grant → run → guard → correlate.
  `run_agent/3` delegates to the configured `AgentRunner` and returns its result.
  """
  alias MimirOrchestration.{AgentRunner, NodeResult}

  @spec run_agent(term(), term(), keyword()) :: {:ok, NodeResult.t()} | {:error, term()}
  def run_agent(agent_ref, input, opts \\ []) do
    runner = Keyword.get(opts, :agent_runner, AgentRunner.RMA)
    runner.run(agent_ref, input, opts)
  end
end
