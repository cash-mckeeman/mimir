defmodule Mimir.Grant do
  @moduledoc """
  A minted routing grant from a route response: the granted key and its budget
  and expiry. Wire vocabulary — plain data parsed by `Mimir.RouteResponse.new/1`.
  """
  @enforce_keys [:key]
  defstruct [:key, :expires_at, :budget_microdollars]

  @type t :: %__MODULE__{
          key: String.t(),
          expires_at: String.t() | nil,
          budget_microdollars: non_neg_integer() | nil
        }
end
