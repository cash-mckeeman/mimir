defmodule MimirOrchestration.AgentRunner.RMAAbsentTest do
  @moduledoc """
  Without req_managed_agents, the default agent runner names the missing dependency
  instead of crashing. Runs only in CI's without-RMA leg; the precondition makes it
  red, not vacuous, anywhere RMA is loaded.
  """
  use ExUnit.Case, async: true
  @moduletag :without_rma

  alias MimirOrchestration.AgentRunner
  alias MimirOrchestration.AgentRunner.RMA.Reference

  test "the default runner returns missing_dependency for specs and handles" do
    refute Code.ensure_loaded?(ReqManagedAgents),
           "req_managed_agents is loaded: run this under MIMIR_WITHOUT_RMA=1"

    for resource <- [{:spec, %{}}, {:handle, "h"}] do
      {:ok, ref} = Reference.new(provider: :provider, runtime: "local", resource: resource)

      assert {:error, {:missing_dependency, :req_managed_agents}} =
               AgentRunner.RMA.run(ref, "hello", [])
    end
  end
end
