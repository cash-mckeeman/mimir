defmodule MimirWorkflows.TemplateTest do
  use ExUnit.Case, async: true
  alias MimirWorkflows.Template

  @ctx %{results: %{"analyze" => %{"kpi" => 42}}, params: %{"month" => "2026-06"}}

  test "refs walks maps, lists, and strings" do
    input = %{
      "a" => "{{analyze}}",
      "b" => ["KPIs for {{params.month}}", %{"c" => "{{params.month}}"}]
    }

    assert Enum.sort(Template.refs(input)) ==
             Enum.sort(["analyze", "params.month", "params.month"])
  end

  test "whole-string step ref substitutes the full value" do
    assert {:ok, %{"kpi" => 42}} = Template.resolve("{{analyze}}", @ctx)
  end

  test "embedded refs interpolate; params resolve under the params namespace" do
    assert {:ok, "KPIs for 2026-06"} = Template.resolve("KPIs for {{params.month}}", @ctx)
  end

  test "resolution recurses through maps and lists" do
    assert {:ok, %{"q" => "KPIs for 2026-06", "data" => %{"kpi" => 42}}} =
             Template.resolve(
               %{"q" => "KPIs for {{params.month}}", "data" => "{{analyze}}"},
               @ctx
             )
  end

  test "an unresolved ref is an error naming the ref" do
    assert {:error, {:unresolved_ref, "ghost"}} = Template.resolve("{{ghost}}", @ctx)
  end
end
