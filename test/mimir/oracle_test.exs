defmodule Mimir.OracleTest do
  use ExUnit.Case, async: true
  alias Mimir.{Catalog.Entry, Descriptor, Oracle, Snapshot}

  defp entry(id, model, opts \\ []) do
    [provider, _model_id] = String.split(model, ":", parts: 2)

    %Entry{
      id: id,
      model: model,
      model_spec: model,
      lane: Keyword.get(opts, :lane, provider),
      runtime: Keyword.get(opts, :runtime, :managed),
      capabilities: Keyword.get(opts, :capabilities, [:tools]),
      p50_latency_ms: Keyword.get(opts, :p50, 5_000),
      priority: Keyword.get(opts, :priority, 100)
    }
  end

  defp descriptor(over \\ %{}) do
    {:ok, d} =
      Descriptor.parse(
        Map.merge(
          %{
            task_class: "t",
            budget_ceiling_microdollars: 100_000,
            latency_tolerance_ms: 60_000,
            capabilities: ["tools"],
            expected_tokens: %{in: 1_000_000, out: 0}
          },
          over
        )
      )

    d
  end

  defp snapshot(over \\ []) do
    Snapshot.assemble(
      Keyword.merge(
        [
          pricing: %{
            "anthropic:sonnet" => %{input: 3_000_000, output: 15_000_000},
            "ollama:nemotron" => %{input: 0, output: 0}
          },
          health: %{},
          parent_remaining: :unlimited
        ],
        over
      )
    )
  end

  @policy %Oracle.Policy{allowed_models: []}

  test "cheapest viable wins; every entry gets a verdict" do
    entries = [entry("son", "anthropic:sonnet"), entry("nem", "ollama:nemotron", runtime: :local)]

    # budget raised to 10M so sonnet (3M projected) is viable-but-ranked, not excluded
    assert {:placement, placement} =
             Oracle.decide(
               descriptor(%{budget_ceiling_microdollars: 10_000_000}),
               entries,
               @policy,
               snapshot()
             )

    assert placement.entry.id == "nem"
    assert "cheapest_viable" in placement.reasons
    verdicts = Map.new(placement.candidates, &{&1.id, &1.verdict})
    assert verdicts["nem"] == :chosen
    assert verdicts["son"] == :ranked
  end

  test "capability filter excludes with reason" do
    entries = [entry("son", "anthropic:sonnet", capabilities: [])]
    d = descriptor(%{capabilities: ["tools"]})

    assert {:no_candidate, _reasons,
            [%{id: "son", verdict: {:excluded, {:capability, [:tools]}}}]} =
             Oracle.decide(d, entries, @policy, snapshot())
  end

  test "policy allowlist excludes non-listed models" do
    entries = [entry("son", "anthropic:sonnet"), entry("nem", "ollama:nemotron")]
    policy = %Oracle.Policy{allowed_models: ["anthropic:sonnet"]}

    # budget raised to 10M so sonnet (3M projected) passes cost and can be placed
    assert {:placement, placement} =
             Oracle.decide(
               descriptor(%{budget_ceiling_microdollars: 10_000_000}),
               entries,
               policy,
               snapshot()
             )

    assert placement.entry.id == "son"

    assert Enum.any?(
             placement.candidates,
             &(&1.id == "nem" and match?({:excluded, {:policy, _}}, &1.verdict))
           )
  end

  test "runtime_preference filters" do
    entries = [entry("son", "anthropic:sonnet"), entry("nem", "ollama:nemotron", runtime: :local)]
    d = descriptor(%{runtime_preference: "local"})

    assert {:placement, %{entry: %{id: "nem"}}} = Oracle.decide(d, entries, @policy, snapshot())
  end

  test "viability: projected cost over ceiling excludes; nil expected_tokens skips cost exclusion" do
    entries = [entry("son", "anthropic:sonnet")]
    # 1M input tokens at 3_000_000µ$/M = 3_000_000µ$ > 100_000 ceiling → excluded
    assert {:no_candidate, _, [%{verdict: {:excluded, {:cost, _}}}]} =
             Oracle.decide(descriptor(), entries, @policy, snapshot())

    # nil expected_tokens: no cost exclusion, sonnet places
    d = descriptor(%{expected_tokens: nil})
    assert {:placement, %{entry: %{id: "son"}}} = Oracle.decide(d, entries, @policy, snapshot())
  end

  test "viability: degraded lane and over-tolerance latency exclude" do
    entries = [entry("son", "anthropic:sonnet", lane: "anthropic", p50: 5_000)]

    assert {:no_candidate, _, [%{verdict: {:excluded, {:health, :degraded}}}]} =
             Oracle.decide(
               descriptor(%{expected_tokens: nil}),
               entries,
               @policy,
               snapshot(health: %{"anthropic" => :degraded})
             )

    d = descriptor(%{latency_tolerance_ms: 1_000, expected_tokens: nil})

    assert {:no_candidate, _, [%{verdict: {:excluded, {:latency, _}}}]} =
             Oracle.decide(d, entries, @policy, snapshot())
  end

  test "parent_remaining caps projected cost even when ceiling allows" do
    entries = [entry("son", "anthropic:sonnet")]
    d = descriptor(%{budget_ceiling_microdollars: 10_000_000})

    assert {:no_candidate, _, [%{verdict: {:excluded, {:cost, _}}}]} =
             Oracle.decide(d, entries, @policy, snapshot(parent_remaining: 1_000))
  end

  test "rank tie-break: equal cost → lower p50; then lower priority number" do
    entries = [
      entry("a", "ollama:nemotron", p50: 9_000, priority: 20),
      entry("b", "ollama:nemotron2", p50: 2_000, priority: 30)
    ]

    snap =
      snapshot(
        pricing: %{
          "ollama:nemotron" => %{input: 0, output: 0},
          "ollama:nemotron2" => %{input: 0, output: 0}
        }
      )

    assert {:placement, %{entry: %{id: "b"}}} =
             Oracle.decide(descriptor(%{expected_tokens: nil}), entries, @policy, snap)
  end

  test "rank tie-break: equal cost and equal p50 → lower priority number wins" do
    entries = [
      entry("a", "ollama:nemotron", p50: 5_000, priority: 20),
      entry("b", "ollama:nemotron2", p50: 5_000, priority: 10)
    ]

    snap =
      snapshot(
        pricing: %{
          "ollama:nemotron" => %{input: 0, output: 0},
          "ollama:nemotron2" => %{input: 0, output: 0}
        }
      )

    assert {:placement, %{entry: %{id: "b"}}} =
             Oracle.decide(descriptor(%{expected_tokens: nil}), entries, @policy, snap)
  end

  test "decide is deterministic and pure (same inputs, same output, twice)" do
    entries = [entry("son", "anthropic:sonnet"), entry("nem", "ollama:nemotron")]
    args = [descriptor(%{expected_tokens: nil}), entries, @policy, snapshot()]
    assert apply(Oracle, :decide, args) == apply(Oracle, :decide, args)
  end
end
