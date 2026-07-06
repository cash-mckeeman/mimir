defmodule Mimir do
  @moduledoc """
  Mimir is an embeddable routing oracle, pricing source, and decision
  vocabulary for LLM workloads. Consult it in-process: hand it a workload
  descriptor and an operational snapshot, and it hands back a placement (or a
  reasoned no-candidate answer) plus an auditable decision record. A gateway
  service built on top of Mimir is one possible embedder — not a requirement.

  ## Module inventory

  | Module | What it does |
  | --- | --- |
  | `Mimir.Descriptor` | Validated workload descriptor — the contract a workflow step presents to the oracle. |
  | `Mimir.Oracle` | Pure filter-then-rank placement decision over catalog entries. |
  | `Mimir.Catalog` | Config-sourced routable entries, with an injectable model resolver seam. |
  | `Mimir.Snapshot` | Explicit-inputs operational snapshot the oracle ranks against (pricing, health, budget). |
  | `Mimir.Health` | Failure-streak table for router lanes, driven by telemetry. |
  | `Mimir.DecisionRecord` | Pure builder for a binary-keyed routing-decision audit record. |
  | `Mimir.RouteLog` | Typed route outcome plus a request-log meta builder. |
  | `Mimir.Pricing` | Token usage to integer microdollar cost, config-first over a vendored LiteLLM pricing DB. |
  | `Mimir.TurnEvents` | Per-request ordered `gen_ai.*` event buffer. |
  | `Mimir.RouterClient` | Behaviour for routing clients, with an HTTP (Req-based) implementation. |
  | `Mimir.Redact` | Secret masking and payload-capture gating helpers. |
  | `Mimir.Guard` | Turn-guard builders for a session's between-turn hook — grant-budget halts and mimir-less caps. |
  | `Mimir.Ingest` | Decision-correlated ingestion of raw session events into `Mimir.TurnEvents`. |
  | `Mimir.Sessions` | Canonical recipe: route response to session options (`model_config`, `turn_guard`, `telemetry_metadata`). |

  See the [README](readme.html) for design rules, supervision, configuration,
  and a gateway-less worked example.
  """
end
