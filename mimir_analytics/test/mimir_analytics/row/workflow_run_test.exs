defmodule MimirAnalytics.Row.WorkflowRunTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.Row.WorkflowRun

  test "new/1 builds a t() from a source map" do
    row =
      WorkflowRun.new(%{
        "workflow_id" => "wf_1",
        "tenant_id" => "tenant-a",
        "started_at" => "2026-07-07T14:00:00Z",
        "finished_at" => nil,
        "status" => "completed",
        "source_file" => "f.json"
      })

    assert %WorkflowRun{workflow_id: "wf_1", tenant_id: "tenant-a", status: "completed"} = row
  end

  test "enforce_keys raises when workflow_id or source_file is missing" do
    assert_raise ArgumentError, fn -> struct!(WorkflowRun, status: "x") end
  end
end
