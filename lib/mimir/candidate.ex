defmodule Mimir.Candidate do
  @moduledoc """
  One catalog entry's verdict in a routing decision: `:chosen`, `:ranked`
  (viable but not chosen), or `{:excluded, reason}`.
  """
  @enforce_keys [:id, :verdict]
  defstruct [:id, :verdict]

  @type verdict :: :chosen | :ranked | {:excluded, term()}
  @type t :: %__MODULE__{id: String.t(), verdict: verdict()}
end
