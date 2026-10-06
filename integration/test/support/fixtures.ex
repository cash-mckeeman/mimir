defmodule Integration.Fixtures do
  @moduledoc false

  alias Mimir.{Candidate, Catalog.Entry, DecisionRecord, Descriptor, Snapshot}
  alias Mimir.Oracle.Decision

  @doc "A raw Observability API row carrying producer-generated envelopes."
  def request_log_row(events) do
    %{
      "request_id" => "req-1",
      "virtual_key_id" => "vk-1",
      "parent_key_id" => nil,
      "tenant_id" => "tenant-a",
      "lane" => "lane-a",
      "provider" => "anthropic",
      "model_id" => "model-a",
      "status" => "success",
      "finish_reason" => "stop",
      "input_tokens" => 1,
      "output_tokens" => 1,
      "cost_microdollars" => 1,
      "latency_ms" => 1,
      "fallback" => false,
      "error_class" => nil,
      "workflow_id" => "wf-1",
      "step_id" => "s-1",
      "parent_step_id" => nil,
      "inserted_at" => "2026-10-02T00:00:00Z",
      "turn_events" => %{"events" => events}
    }
  end

  def decision_record do
    {:ok, descriptor} =
      Descriptor.parse(%{
        task_class: "extract",
        budget_ceiling_microdollars: 50_000,
        latency_tolerance_ms: 30_000
      })

    decision = %Decision{
      entry: %Entry{
        id: "haiku",
        model: "anthropic:claude-haiku-4-5",
        model_spec: %{},
        lane: :anthropic,
        runtime: :managed
      },
      reasons: ["cheapest_viable"],
      candidates: [%Candidate{id: "haiku", verdict: :chosen}]
    }

    snapshot = %Snapshot{
      pricing: %{"anthropic:claude-haiku-4-5" => %{input: 250_000, output: 1_250_000}},
      health: %{},
      parent_remaining: :unlimited,
      snapshot_at: ~U[2026-10-02 00:00:00Z]
    }

    DecisionRecord.build(
      descriptor,
      {:decision, decision},
      nil,
      %{workflow_id: "wf-1", step_id: "s-1"},
      snapshot
    )
  end
end
