defmodule MimirAnalytics.Row.Run do
  @moduledoc """
  One captured session mapped onto the run-record correlation columns.

  `result["session_id"]` is authoritative. `meta["run_id"]` is a fallback
  for legacy files only; caller-local correlation keys do not define run identity.
  Other session-fed row builders reuse `run_id/2`.
  """

  alias MimirAnalytics.Mapper

  @enforce_keys [:run_id, :source_file]
  defstruct [
    :run_id,
    :workflow_id,
    :step_id,
    :parent_step_id,
    :tenant_id,
    :agent_digest,
    :agent_name,
    :agent_version,
    :runtime,
    :provider,
    :model,
    :lane,
    :outcome,
    :terminal,
    :stop_reason,
    :error_class,
    :turns,
    :input_tokens,
    :output_tokens,
    :cost_microdollars,
    :started_at,
    :finished_at,
    :source_file
  ]

  @type t :: %__MODULE__{
          run_id: String.t(),
          workflow_id: String.t() | nil,
          step_id: String.t() | nil,
          parent_step_id: String.t() | nil,
          tenant_id: String.t() | nil,
          agent_digest: String.t() | nil,
          agent_name: String.t() | nil,
          agent_version: String.t() | nil,
          # claude_managed | agentcore | local
          runtime: String.t() | nil,
          provider: String.t() | nil,
          model: String.t() | nil,
          lane: String.t() | nil,
          # ok | error
          outcome: String.t() | nil,
          # end_turn | terminated | ...
          terminal: String.t() | nil,
          stop_reason: String.t() | nil,
          # a classification only, never the raw error term
          error_class: String.t() | nil,
          turns: integer() | nil,
          input_tokens: integer(),
          output_tokens: integer(),
          cost_microdollars: integer(),
          started_at: String.t() | nil,
          finished_at: String.t() | nil,
          source_file: String.t()
        }

  @doc """
  Build a run row from `meta`, `result` and `source_file`.
  `outcome` and `error_class` are source classifications; raw `error` terms
  are not read. Missing usage and cost values default to zero.
  """
  @spec new(map()) :: t()
  def new(%{"meta" => m, "result" => r, "source_file" => file}) do
    usage = r["usage"] || %{}

    %__MODULE__{
      run_id: run_id(m, r),
      workflow_id: m["workflow_id"],
      step_id: m["step_id"],
      parent_step_id: m["parent_step_id"],
      tenant_id: m["tenant_id"],
      agent_digest: m["agent_digest"],
      agent_name: m["agent_name"],
      agent_version: m["agent_version"],
      runtime: m["runtime"],
      provider: m["provider"],
      model: m["model"],
      lane: m["lane"],
      outcome: r["outcome"],
      terminal: r["terminal"],
      stop_reason: stringify(r["stop_reason"]),
      error_class: r["error_class"],
      turns: r["turns"],
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      cost_microdollars: m["cost_microdollars"] || 0,
      started_at: m["started_at"],
      finished_at: m["finished_at"],
      source_file: file
    }
  end

  @doc """
  Resolve a session entry's run id: `result["session_id"]` (authoritative)
  else `meta["run_id"]` (documented legacy-file fallback only — see
  moduledoc). The centralized resolution other Session-fed Row modules
  (`Row.ToolCall`, `Row.EventRaw`) reuse instead of duplicating.
  """
  @spec run_id(Mapper.source_map(), Mapper.source_map()) :: String.t() | nil
  def run_id(meta, result), do: result["session_id"] || meta["run_id"]

  defp stringify(nil), do: nil
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: inspect(v)
end
