defmodule MimirAnalytics do
  @moduledoc """
  Analytical run-record store for the mimir agent stack: the canonical,
  queryable record of an agent run — workflow → step → run (session) → turn
  → tool_call, plus model calls, routing decisions, eval outcomes, and raw
  events. Mappers ingest from gateway pull-buffers, session drops, and eval
  reports into a shared correlation-id contract (`workflow_id`, `step_id`,
  `run_id`, `mimir_request_id`, and friends), backed by a local DuckDB file
  in dev/test and a MotherDuck-hosted DuckLake in deployment. This library
  depends on nothing else in-house — see the dependency-direction invariant
  in the README.
  """
end
