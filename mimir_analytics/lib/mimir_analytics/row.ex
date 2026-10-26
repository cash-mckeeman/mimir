defmodule MimirAnalytics.Row do
  @moduledoc """
  Direct-insert run-record rows. `tables/0` maps SQL tables to structs with
  matching columns; each module owns source-field coercion in `new/1`.

  `Store` owns `ingest_ledger` and `ingest_rejections`. `AccountingStore`
  owns `accounting_events`, `accounting_states` and `gateway_checkpoints`
  through explicit storage projections. These tables are outside this registry.
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
