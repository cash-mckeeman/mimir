defmodule MimirWorkflows.SpecTest do
  use ExUnit.Case, async: true
  alias MimirWorkflows.{Diagnostic, Spec}

  @valid %{
    "name" => "brief",
    "version" => 1,
    "params" => ["month"],
    "steps" => [
      %{"id" => "analyze", "kind" => "agent", "depends_on" => []},
      %{"id" => "narrate", "kind" => "agent", "depends_on" => ["analyze"]}
    ]
  }

  test "valid spec parses with no diagnostics and string ids" do
    assert {%Spec{name: "brief", version: 1, steps: [s1, s2]}, []} = Spec.parse(@valid)
    assert s1.id == "analyze" and s2.depends_on == ["analyze"]
    assert s1.raw["kind"] == "agent"
  end

  test "duplicate ids, missing keys, and non-list deps are schema errors" do
    bad = %{
      "name" => "x",
      "steps" => [
        %{"id" => "a", "kind" => "t", "depends_on" => []},
        %{"id" => "a", "kind" => "t", "depends_on" => []},
        %{"kind" => "t", "depends_on" => "a"}
      ]
    }

    {_spec, diags} = Spec.parse(bad)
    passes = Enum.map(diags, & &1.pass) |> Enum.uniq()
    assert passes == [:schema]
    assert Enum.all?(diags, &match?(%Diagnostic{severity: :error}, &1))
    assert Enum.any?(diags, &(&1.message =~ "duplicate id"))
    assert Enum.any?(diags, &(&1.message =~ "missing \"id\""))
    assert Enum.any?(diags, &(&1.message =~ "\"depends_on\" must be a list"))
    assert Enum.any?(diags, &(&1.message =~ "missing \"version\""))
  end

  test "kind vocabulary is NOT validated here (host concern)" do
    spec = put_in(@valid, ["steps", Access.at(0), "kind"], "anything_at_all")
    assert {_spec, []} = Spec.parse(spec)
  end
end
