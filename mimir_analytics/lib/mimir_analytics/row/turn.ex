defmodule MimirAnalytics.Row.Turn do
  @moduledoc """
  One per-turn row. The session mapper currently writes a run-level turn
  count, not rows in this table. Callers with per-turn data can construct
  rows with `new/1`.
  """

  @enforce_keys [:run_id, :turn, :source_file]
  defstruct [:run_id, :turn, :terminal, :input_tokens, :output_tokens, :source_file]

  @type t :: %__MODULE__{
          run_id: String.t(),
          turn: integer(),
          terminal: String.t() | nil,
          input_tokens: integer() | nil,
          output_tokens: integer() | nil,
          source_file: String.t()
        }

  @doc "Build a `t()` from a source map; string keys, PK fields + `source_file` required."
  @spec new(map()) :: t()
  def new(m) do
    %__MODULE__{
      run_id: Map.fetch!(m, "run_id"),
      turn: Map.fetch!(m, "turn"),
      terminal: m["terminal"],
      input_tokens: m["input_tokens"],
      output_tokens: m["output_tokens"],
      source_file: Map.fetch!(m, "source_file")
    }
  end
end
