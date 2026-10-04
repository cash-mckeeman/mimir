defmodule MimirAnalytics.CaptureSeamCrosscheckTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias MimirAnalytics.{Mappers.Session, Store}

  @fixture Path.expand(
             "../support/run_record_fixtures/session_seam_crosscheck.jsonl",
             __DIR__
           )

  setup do
    {:ok, store} = Store.open(:memory)
    %{store: store}
  end

  test "sanitised captured session output preserves identity and terminal fields", %{store: store} do
    assert {:ok, %{rows: %{"runs" => 2, "events_raw" => 0}}} = Session.ingest(store, @fixture)

    # The captured session output carries no "events" key at all — asserted so a
    # producer that starts emitting them shows up here as a failing test rather
    # than as silence.
    {:ok, [[0]]} = Store.query(store, "SELECT count(*) FROM events_raw")

    {:ok, rows} =
      Store.query(store, """
      SELECT run_id, workflow_id, terminal, stop_reason, turns, input_tokens, output_tokens
      FROM runs ORDER BY run_id
      """)

    assert [
             [run_id_1, "wf-fixture-demo", "end_turn", stop_reason_1, 3, 512, 128],
             [run_id_2, nil, "terminated", "max_tokens", nil, 0, 0]
           ] = rows

    # session_id is authoritative over caller-local correlation keys.
    assert run_id_1 == "sess-9f3c2a11"
    assert run_id_2 == "sess-9f3c2a12"

    # RMA's raw stop_reason for the success row was a provider-shaped map
    # (%{"type" => "end_turn"}) — Row.Run stringifies it, verbatim content
    # preserved via inspect/1.
    assert stop_reason_1 == inspect(%{"type" => "end_turn"})
  end
end
