defmodule MimirWorkflows.Step do
  @moduledoc """
  Behaviour for a single step in a workflow.

  Each step receives its own `params` map and an `upstream` map containing
  the result maps of **exactly the steps it declared as dependencies** —
  direct dependencies only, never transitive ancestors. Steps return
  `{:ok, result}` or `{:error, reason}`.

  Step ids are opaque terms: atoms in hand-written pipelines, strings when
  they come from parsed IR. The runner compares ids by value and never
  converts them.

  ## Graceful degradation (convention, not enforcement)

  Conditional steps stay in the DAG and no-op — returning a result like
  `{:ok, %{"skipped" => true}}` — rather than being excluded from the
  graph. The DAG stays static and analyzable; downstream steps read the
  skip marker from `upstream` and degrade in turn.

  ## Usage accounting (convention)

  Steps that spend put a `"usage"` map in their result
  (`%{"input_tokens" => _, "output_tokens" => _, "calls" => _}`);
  `MimirWorkflows.Result.usage/1` folds them across a run.
  """

  @type step_id :: term()
  @type params :: map()
  @type upstream :: %{optional(step_id()) => map()}
  @type result :: map()

  @callback run(params(), upstream()) :: {:ok, result()} | {:error, term()}
end
