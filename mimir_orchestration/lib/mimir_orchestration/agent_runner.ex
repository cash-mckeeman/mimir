defmodule MimirOrchestration.AgentRunner do
  @moduledoc """
  Runs one agent reference to completion.

  Implementations interpret the opaque reference and return a `NodeResult` or
  an error. Hosts select an implementation through `:agent_runner`; the default
  is `MimirOrchestration.AgentRunner.RMA`.
  """
  alias MimirOrchestration.NodeResult

  @callback run(agent_ref :: term(), input :: term(), opts :: keyword()) ::
              {:ok, NodeResult.t()} | {:error, term()}
end
