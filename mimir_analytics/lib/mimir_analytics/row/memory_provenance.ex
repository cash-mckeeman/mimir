defmodule MimirAnalytics.Row.MemoryProvenance do
  @moduledoc """
  One row of `memory_provenance`. Current mappers do not write this table;
  callers can construct rows with `new/1`.
  """

  @enforce_keys [:entry_id, :source_file]
  defstruct [:entry_id, :event, :agent, :run_id, :evidence_ref, :at, :source_file]

  @type event ::
          String.t()
          | nil

  @type t :: %__MODULE__{
          entry_id: String.t(),
          # proposed | recalled | accepted | corrected | promoted | demoted | archived
          event: event(),
          agent: String.t() | nil,
          run_id: String.t() | nil,
          evidence_ref: String.t() | nil,
          at: String.t() | nil,
          source_file: String.t()
        }

  @doc "Build a `t()` from a source map; string keys, `entry_id`/`source_file` required."
  @spec new(map()) :: t()
  def new(m) do
    %__MODULE__{
      entry_id: Map.fetch!(m, "entry_id"),
      event: m["event"],
      agent: m["agent"],
      run_id: m["run_id"],
      evidence_ref: m["evidence_ref"],
      at: m["at"],
      source_file: Map.fetch!(m, "source_file")
    }
  end
end
