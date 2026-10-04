defmodule MimirAnalytics.Row do
  @moduledoc """
  Typed row structs for the run-record tables. `tables/0` maps table names
  to their row modules. Each module owns source-field coercion in `new/1`.

  Ingest-ledger and rejection rows are written directly by `Store`, so
  they are not part of this registry.
  """

  alias MimirAnalytics.Row.{
    EvalOutcome,
    EventRaw,
    MemoryProvenance,
    ModelCall,
    RoutingDecision,
    Run,
    Step,
    ToolCall,
    Turn,
    WorkflowRun
  }

  @tables %{
    "workflow_runs" => WorkflowRun,
    "steps" => Step,
    "runs" => Run,
    "turns" => Turn,
    "tool_calls" => ToolCall,
    "model_calls" => ModelCall,
    "routing_decisions" => RoutingDecision,
    "eval_outcomes" => EvalOutcome,
    "events_raw" => EventRaw,
    "memory_provenance" => MemoryProvenance
  }

  @spec tables() :: %{String.t() => module()}
  def tables, do: @tables
end
