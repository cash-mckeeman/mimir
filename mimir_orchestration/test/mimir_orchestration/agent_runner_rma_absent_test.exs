defmodule MimirOrchestration.AgentRunner.RMAAbsentTest do
  @moduledoc """
  Without req_managed_agents, the default agent runner names the missing dependency
  instead of crashing. Runs only in CI's without-RMA leg; the precondition makes it
  red, not vacuous, anywhere RMA is loaded.
  """
  use ExUnit.Case, async: true
  @moduletag :without_rma

  alias MimirOrchestration.AgentRunner

  test "the default runner returns missing_dependency" do
    refute Code.ensure_loaded?(ReqManagedAgents),
           "req_managed_agents is loaded: run this under MIMIR_WITHOUT_RMA=1"

    assert {:error, {:missing_dependency, :req_managed_agents}} =
             AgentRunner.RMA.run({:provider, {:spec, %{}}}, "hello", [])
  end
end
