defmodule Mimir.Placement do
  @moduledoc """
  The flat chosen-model placement from a route response: which lane, model, and
  runtime the workload was placed on. Wire vocabulary — distinct from
  `Mimir.Oracle.Decision`, the rich server-side decision.
  """
  @enforce_keys [:model]
  defstruct [:lane, :model, :runtime]

  @type t :: %__MODULE__{
          lane: String.t() | nil,
          model: String.t(),
          runtime: String.t() | nil
        }
end
