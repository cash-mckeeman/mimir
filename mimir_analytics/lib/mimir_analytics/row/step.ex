defmodule MimirAnalytics.Row.Step do
  @moduledoc """
  One row of `steps`. Current mappers do not write this table;
  callers can construct rows with `new/1`.
  """

  @enforce_keys [:workflow_id, :step_id, :source_file]
  defstruct [
    :workflow_id,
    :step_id,
    :parent_step_id,
    :agent_name,
    :status,
    :started_at,
    :finished_at,
    :source_file
  ]

  @type t :: %__MODULE__{
          workflow_id: String.t(),
          step_id: String.t(),
          parent_step_id: String.t() | nil,
          agent_name: String.t() | nil,
          status: String.t() | nil,
          started_at: String.t() | nil,
          finished_at: String.t() | nil,
          source_file: String.t()
        }

  @doc "Build a `t()` from a source map; string keys, PK fields + `source_file` required."
  @spec new(map()) :: t()
  def new(m) do
    %__MODULE__{
      workflow_id: Map.fetch!(m, "workflow_id"),
      step_id: Map.fetch!(m, "step_id"),
      parent_step_id: m["parent_step_id"],
      agent_name: m["agent_name"],
      status: m["status"],
      started_at: m["started_at"],
      finished_at: m["finished_at"],
      source_file: Map.fetch!(m, "source_file")
    }
  end
end
