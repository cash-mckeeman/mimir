defmodule MimirAnalytics.Row.StepTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.Row.Step

  test "new/1 builds a t() from a source map" do
    row =
      Step.new(%{
        "workflow_id" => "wf_1",
        "step_id" => "analyze",
        "parent_step_id" => nil,
        "agent_name" => "agent_a",
        "status" => "ok",
        "started_at" => nil,
        "finished_at" => nil,
        "source_file" => "f.json"
      })

    assert %Step{workflow_id: "wf_1", step_id: "analyze", status: "ok"} = row
  end

  test "enforce_keys raises when workflow_id, step_id, or source_file is missing" do
    assert_raise ArgumentError, fn -> struct!(Step, status: "x") end
  end
end
