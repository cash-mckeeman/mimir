defmodule MimirOrchestration.Runner.Ctx do
  @moduledoc """
  Internal context for one runner invocation. The public entry point is
  `MimirOrchestration.Runner.run/2`; hosts pass its keyword options.
  """

  @enforce_keys [:run_fun, :workflow_id]
  defstruct [:router, :run_fun, :workflow_id, :max_concurrency, :step_timeout]

  @type run_fun :: (term(), term(), keyword() -> {:ok, term()} | {:error, term()})

  @type t :: %__MODULE__{
          router: {module(), keyword()} | nil,
          run_fun: run_fun(),
          workflow_id: String.t(),
          max_concurrency: pos_integer(),
          step_timeout: timeout()
        }
end
