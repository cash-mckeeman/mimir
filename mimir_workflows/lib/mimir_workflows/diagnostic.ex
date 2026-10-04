defmodule MimirWorkflows.Diagnostic do
  @moduledoc """
  One structured finding from a compiler pass.

  Diagnostics accumulate across every pass (built-in and host-supplied) —
  compilation never stops at the first problem, so a caller (or an agent
  repairing its own declared workflow) sees the complete picture in one
  round trip.
  """

  @type severity :: :error | :warning

  @type t :: %__MODULE__{
          pass: atom(),
          severity: severity(),
          step_id: term() | nil,
          message: String.t()
        }

  @enforce_keys [:pass, :severity, :message]
  defstruct [:pass, :severity, :step_id, :message]
end
