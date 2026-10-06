defmodule MimirOrchestration.Test.Registered do
  @moduledoc false
  # Pids may not cross the executor seam, so a test process that a step must reach
  # is passed by registered name.

  @spec self_name() :: atom()
  def self_name do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} when is_atom(name) ->
        name

      _unregistered ->
        name = :"mimir_orchestration_test_#{System.unique_integer([:positive])}"
        Process.register(self(), name)
        name
    end
  end
end
