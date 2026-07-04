defmodule Mimir.DescriptorTest do
  use ExUnit.Case, async: true
  alias Mimir.Descriptor

  @valid %{
    "task_class" => "extraction",
    "capabilities" => ["tools"],
    "budget_ceiling_microdollars" => 50_000,
    "latency_tolerance_ms" => 30_000,
    "runtime_preference" => "any"
  }

  test "parses a valid descriptor with atomized enums and defaults" do
    assert {:ok, d} = Descriptor.parse(@valid)
    assert d.task_class == "extraction"
    assert d.capabilities == [:tools]
    assert d.runtime_preference == :any
    assert d.expected_tokens == nil
    assert d.quality_bar == nil
  end

  test "accepts atom-keyed input (in-process callers)" do
    assert {:ok, _} =
             Descriptor.parse(%{
               task_class: "x",
               budget_ceiling_microdollars: 1,
               latency_tolerance_ms: 1
             })
  end

  test "quality_bar non-nil is rejected, not ignored" do
    assert {:error, :quality_bar_unsupported} =
             Descriptor.parse(Map.put(@valid, "quality_bar", 0.9))
  end

  test "quality_bar: false (falsy) with atom key is rejected" do
    assert {:error, :quality_bar_unsupported} =
             Descriptor.parse(%{
               task_class: "x",
               budget_ceiling_microdollars: 1,
               latency_tolerance_ms: 1,
               quality_bar: false
             })
  end

  test "quality_bar: false (falsy) with string key is rejected" do
    assert {:error, :quality_bar_unsupported} =
             Descriptor.parse(Map.put(@valid, "quality_bar", false))
  end

  test "rejects unknown runtime_preference, negative budget, missing task_class" do
    assert {:error, {:invalid_descriptor, :runtime_preference, _}} =
             Descriptor.parse(Map.put(@valid, "runtime_preference", "quantum"))

    assert {:error, {:invalid_descriptor, :budget_ceiling_microdollars, _}} =
             Descriptor.parse(Map.put(@valid, "budget_ceiling_microdollars", -1))

    assert {:error, {:invalid_descriptor, :task_class, _}} =
             Descriptor.parse(Map.delete(@valid, "task_class"))
  end

  test "expected_tokens validates shape when present" do
    assert {:ok, d} =
             Descriptor.parse(Map.put(@valid, "expected_tokens", %{"in" => 10, "out" => 2}))

    assert d.expected_tokens == %{in: 10, out: 2}

    assert {:error, {:invalid_descriptor, :expected_tokens, _}} =
             Descriptor.parse(Map.put(@valid, "expected_tokens", %{"in" => -5}))
  end

  test "unknown capabilities are rejected (closed vocabulary)" do
    assert {:error, {:invalid_descriptor, :capabilities, _}} =
             Descriptor.parse(Map.put(@valid, "capabilities", ["telekinesis"]))
  end

  describe "agent identity + outcome hint" do
    @valid %{
      task_class: "extraction",
      budget_ceiling_microdollars: 10_000,
      latency_tolerance_ms: 5_000
    }

    test "defaults to nil agent and nil max_outcome_iterations" do
      assert {:ok, d} = Mimir.Descriptor.parse(@valid)
      assert d.agent == nil
      assert d.max_outcome_iterations == nil
    end

    test "parses agent identity with atom or string keys" do
      assert {:ok, d} =
               Mimir.Descriptor.parse(
                 Map.put(@valid, :agent, %{
                   digest: "sha256:abc",
                   name: "business_analyst",
                   version: "3"
                 })
               )

      assert d.agent == %{digest: "sha256:abc", name: "business_analyst", version: "3"}

      assert {:ok, d} =
               Mimir.Descriptor.parse(Map.put(@valid, "agent", %{"digest" => "sha256:abc"}))

      assert d.agent == %{digest: "sha256:abc", name: nil, version: nil}
    end

    test "rejects agent without a digest" do
      assert {:error, {:invalid_descriptor, :agent, _}} =
               Mimir.Descriptor.parse(Map.put(@valid, :agent, %{name: "x"}))

      assert {:error, {:invalid_descriptor, :agent, _}} =
               Mimir.Descriptor.parse(Map.put(@valid, :agent, "not-a-map"))
    end

    test "parses max_outcome_iterations, rejects non-positive" do
      assert {:ok, %{max_outcome_iterations: 5}} =
               Mimir.Descriptor.parse(Map.put(@valid, :max_outcome_iterations, 5))

      assert {:error, {:invalid_descriptor, :max_outcome_iterations, _}} =
               Mimir.Descriptor.parse(Map.put(@valid, :max_outcome_iterations, 0))
    end
  end
end
