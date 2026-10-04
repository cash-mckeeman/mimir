defmodule MimirAnalytics.Row.ToolCall do
  @moduledoc """
  One row of `tool_calls` — a single custom/server tool use from a Capture
  session result, or one occurrence of a `RunRecord` name/count roll-up.
  `new/1` owns extracting `id`/`name`/`input` off the tool-use map (formerly
  positional digs at the mapper call site) and defaulting `input` to `%{}`
  when the tool use carried none.

  A `RunRecord` carries no per-invocation tool-use data — only `%{name,
  count}` roll-ups (the content boundary that struct enforces: arguments
  never leave the producer). `Mappers.Session` expands each roll-up into
  `count` occurrences, kind `"rollup"`, `tool_use_id` and `input` both
  absent — this is the one place a `tool_calls` row carries no invocation
  identity.
  """

  @enforce_keys [:run_id, :seq, :source_file]
  defstruct [:run_id, :turn, :seq, :tool_use_id, :name, :kind, :input, :source_file]

  @type kind :: String.t()

  @type t :: %__MODULE__{
          run_id: String.t(),
          turn: integer() | nil,
          # order within the run
          seq: integer(),
          tool_use_id: String.t() | nil,
          name: String.t() | nil,
          # custom | server | rollup
          kind: kind(),
          input: map(),
          source_file: String.t()
        }

  @doc """
  Build a `t()` from `run_id`, `seq`, the raw `tool_use` map
  (`%{"id" => ..., "name" => ..., "input" => ...}`), its `kind`
  (`"custom"`/`"server"`/`"rollup"`), and `source_file`.
  """
  @spec new(%{
          required(:run_id) => String.t(),
          required(:turn) => integer() | nil,
          required(:seq) => integer(),
          required(:tool_use) => map(),
          required(:kind) => kind(),
          required(:source_file) => String.t()
        }) :: t()
  def new(%{run_id: run_id, turn: turn, seq: seq, tool_use: tu, kind: kind, source_file: file}) do
    %__MODULE__{
      run_id: run_id,
      turn: turn,
      seq: seq,
      tool_use_id: tu["id"],
      name: tu["name"],
      kind: kind,
      input: tu["input"] || %{},
      source_file: file
    }
  end
end
