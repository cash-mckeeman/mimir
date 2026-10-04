defmodule MimirAnalytics.Row.WorkflowRun do
  @moduledoc """
  One row of `workflow_runs`. Current mappers do not write this table;
  callers can construct rows with `new/1`.
  """

  @enforce_keys [:workflow_id, :source_file]
  defstruct [:workflow_id, :tenant_id, :started_at, :finished_at, :status, :source_file]

  @type t :: %__MODULE__{
          workflow_id: String.t(),
          tenant_id: String.t() | nil,
          started_at: String.t() | nil,
          finished_at: String.t() | nil,
          status: String.t() | nil,
          source_file: String.t()
        }

  @doc "Build a `t()` from a source map; string keys, `workflow_id`/`source_file` required."
  @spec new(map()) :: t()
  def new(m) do
    %__MODULE__{
      workflow_id: Map.fetch!(m, "workflow_id"),
      tenant_id: m["tenant_id"],
      started_at: m["started_at"],
      finished_at: m["finished_at"],
      status: m["status"],
      source_file: Map.fetch!(m, "source_file")
    }
  end
end
