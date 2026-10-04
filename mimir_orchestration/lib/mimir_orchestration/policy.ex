defmodule MimirOrchestration.Policy do
  @moduledoc """
  Host policy for workflow compilation.

  `agent_registry` maps declared names to opaque references interpreted by the
  configured `AgentRunner`. `allowed_tools` maps names to one-argument functions
  or `{module, function}` pairs. Budget ceilings are expressed in microdollars.
  """
  @type t :: %__MODULE__{
          agent_registry: %{String.t() => term()},
          allowed_tools: %{String.t() => term()},
          budget_ceiling_microdollars: non_neg_integer() | nil
        }
  defstruct agent_registry: %{}, allowed_tools: %{}, budget_ceiling_microdollars: nil
end
