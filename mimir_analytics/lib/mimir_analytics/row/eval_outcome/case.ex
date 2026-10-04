defmodule MimirAnalytics.Row.EvalOutcome.Case do
  @moduledoc """
  One typed, named case record: an eval report's `results[]` entry joined
  with its matching `judge_results[]` entry (by `case_id`) — replaces the
  untyped positional `c`/judge-map digs that used to feed `eval_row/4`
  directly at the `MimirAnalytics.Mappers.EvalReport` call site.
  """

  @enforce_keys [:case_id]
  defstruct [
    :case_id,
    :passed,
    :reason,
    :elapsed_ms,
    :session_id,
    :judge_passed,
    :judge_reasoning,
    :judge_elapsed_ms
  ]

  @type t :: %__MODULE__{
          case_id: String.t(),
          passed: boolean() | nil,
          reason: String.t() | nil,
          elapsed_ms: integer() | nil,
          session_id: String.t() | nil,
          judge_passed: boolean() | nil,
          judge_reasoning: String.t() | nil,
          judge_elapsed_ms: integer() | nil
        }

  @doc """
  Join a decoded `results[]` case with its (possibly absent — mechanical
  mode runs carry no judge) matching `judge_results[]` entry.
  """
  @spec new(map(), map()) :: t()
  def new(c, judge) do
    %__MODULE__{
      case_id: Map.fetch!(c, "case_id"),
      passed: c["passed"],
      reason: c["reason"],
      elapsed_ms: c["elapsed_ms"],
      session_id: c["session_id"],
      judge_passed: judge["passed"],
      judge_reasoning: judge["reasoning"],
      judge_elapsed_ms: judge["elapsed_ms"]
    }
  end
end
