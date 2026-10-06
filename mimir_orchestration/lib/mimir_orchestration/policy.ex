defmodule MimirOrchestration.Policy do
  @moduledoc """
  Host policy for workflow compilation.

  `agent_registry` maps declared names to opaque references interpreted by the
  configured `AgentRunner`. `allowed_tools` maps names to MFAs,
  `{module, function, extra_args}`, invoked as
  `apply(module, function, [input | extra_args])`. Both reach the executor as step
  targets, so they must be plain data. Budget ceilings are expressed in microdollars.
  """
  @type t :: %__MODULE__{
          agent_registry: %{String.t() => term()},
          allowed_tools: %{String.t() => {module(), atom(), [term()]}},
          budget_ceiling_microdollars: non_neg_integer() | nil
        }
  defstruct agent_registry: %{}, allowed_tools: %{}, budget_ceiling_microdollars: nil
end
