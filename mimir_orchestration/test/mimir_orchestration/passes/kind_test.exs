defmodule MimirOrchestration.Passes.KindTest do
  use ExUnit.Case, async: true
  alias MimirOrchestration.Passes.Kind

  # Conform-to-engine: passes receive the parsed %MimirWorkflows.Spec{},
  # not the raw map (Pass behaviour contract).
  defp spec(steps) do
    {spec, _schema_diags} =
      MimirWorkflows.Spec.parse(%{
        "name" => "wf",
        "version" => 1,
        "params" => [],
        "steps" => steps
      })

    spec
  end

  test "valid kinds produce no diagnostics" do
    diags =
      Kind.check(
        spec([
          %{"id" => "a", "kind" => "agent", "agent" => "data_analyst", "depends_on" => []},
          %{"id" => "b", "kind" => "llm", "prompt" => "title: {{a}}", "depends_on" => ["a"]},
          %{"id" => "c", "kind" => "tool", "tool" => "emit", "depends_on" => ["b"]}
        ]),
        nil
      )

    assert diags == []
  end

  test "unknown kind and missing kind-specific field" do
    diags =
      Kind.check(
        spec([
          %{"id" => "a", "kind" => "magic", "depends_on" => []},
          %{"id" => "b", "kind" => "agent", "depends_on" => []}
        ]),
        nil
      )

    assert Enum.any?(diags, &(&1.step_id == "a" and &1.message =~ "kind"))
    assert Enum.any?(diags, &(&1.step_id == "b" and &1.message =~ ~s("agent")))
    assert Enum.all?(diags, &(&1.pass == :kind and &1.severity == :error))
  end

  test "invalid runtime value" do
    diags =
      Kind.check(
        spec([
          %{
            "id" => "a",
            "kind" => "agent",
            "agent" => "x",
            "runtime" => "cloud9",
            "depends_on" => []
          }
        ]),
        nil
      )

    assert Enum.any?(diags, &(&1.message =~ "runtime"))
  end

  test "steps without an id are skipped (schema pass already reported them)" do
    assert Kind.check(spec([%{"kind" => "agent", "depends_on" => []}]), nil) == []
  end
end
