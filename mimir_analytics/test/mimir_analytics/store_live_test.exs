defmodule MimirAnalytics.StoreLiveTest do
  use ExUnit.Case, async: false

  @moduletag :live

  # Requires MOTHERDUCK_TOKEN and network access; excluded by default.
  test "opens the MotherDuck target, applies schema, round-trips the ledger" do
    assert System.get_env("MOTHERDUCK_TOKEN") not in [nil, ""],
           "set MOTHERDUCK_TOKEN to run the live test"

    {:ok, store} = MimirAnalytics.Store.open({:motherduck, "mimir_analytics_live_test"})
    probe = "live-probe-#{System.system_time(:second)}.jsonl"
    digest = MimirAnalytics.Store.digest(probe)
    refute MimirAnalytics.Store.ingested?(store, digest)
    :ok = MimirAnalytics.Store.record_ingest(store, digest, probe, "live_test", 0)
    assert MimirAnalytics.Store.ingested?(store, digest)
  end
end
