defmodule MimirAnalytics.Row.EvalOutcome do
  @moduledoc """
  One evaluation case joined with its matching judge result by `case_id`.
  Report-level agent, suite and runtime fields accompany the case.
  Missing optional source fields remain `nil`.
  """

  alias MimirAnalytics.Row.EvalOutcome.Case

  @enforce_keys [:case_id, :source_file]
  defstruct [
    :ts,
    :agent,
    :suite,
    :runtime,
    :run_id,
    :mode,
    :threshold,
    :pass_rate,
    :case_id,
    :passed,
    :reason,
    :elapsed_ms,
    :judge_passed,
    :judge_reasoning,
    :judge_elapsed_ms,
    :source_file
  ]

  @type t :: %__MODULE__{
          ts: String.t() | nil,
          # widened vs the original eval-ingest format
          agent: String.t() | nil,
          suite: String.t() | nil,
          runtime: String.t() | nil,
          # widened, nullable
          run_id: String.t() | nil,
          mode: String.t(),
          threshold: float(),
          pass_rate: float(),
          case_id: String.t(),
          passed: boolean() | nil,
          reason: String.t() | nil,
          elapsed_ms: integer() | nil,
          judge_passed: boolean() | nil,
          judge_reasoning: String.t() | nil,
          judge_elapsed_ms: integer() | nil,
          source_file: String.t()
        }

  @doc """
  Build a `t()` from a `Case.t()` (the joined case+judge shape) plus the
  report-level `agent`/`suite`/`runtime`/`mode`/`threshold`/`pass_rate`/`ts`
  context and `source_file`. `run_id` renames the case's `session_id` (see
  `Case.new/2`) — the eval-report analog of the Capture-session rename
  centralized in `Row.Run.run_id/2`.
  """
  @spec new(%{
          required(:case) => Case.t(),
          required(:agent) => String.t() | nil,
          required(:suite) => String.t() | nil,
          required(:runtime) => String.t() | nil,
          required(:mode) => String.t(),
          required(:threshold) => float(),
          required(:pass_rate) => float(),
          required(:ts) => String.t() | nil,
          required(:source_file) => String.t()
        }) :: t()
  def new(%{case: c, source_file: file} = ctx) do
    %__MODULE__{
      ts: ctx.ts,
      agent: ctx.agent,
      suite: ctx.suite,
      runtime: ctx.runtime,
      run_id: c.session_id,
      mode: ctx.mode,
      threshold: ctx.threshold,
      pass_rate: ctx.pass_rate,
      case_id: c.case_id,
      passed: c.passed,
      reason: c.reason,
      elapsed_ms: c.elapsed_ms,
      judge_passed: c.judge_passed,
      judge_reasoning: c.judge_reasoning,
      judge_elapsed_ms: c.judge_elapsed_ms,
      source_file: file
    }
  end
end
