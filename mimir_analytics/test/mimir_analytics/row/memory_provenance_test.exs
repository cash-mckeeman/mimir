defmodule MimirAnalytics.Row.MemoryProvenanceTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.Row.MemoryProvenance

  test "new/1 builds a t() from a source map" do
    row =
      MemoryProvenance.new(%{
        "entry_id" => "mp_1",
        "event" => "proposed",
        "agent" => "agent_a",
        "run_id" => "r1",
        "evidence_ref" => "evt_1",
        "at" => "2026-07-07T14:00:00Z",
        "source_file" => "f.json"
      })

    assert %MemoryProvenance{entry_id: "mp_1", event: "proposed", run_id: "r1"} = row
  end

  test "enforce_keys raises when entry_id or source_file is missing" do
    assert_raise ArgumentError, fn -> struct!(MemoryProvenance, event: "x") end
  end
end
