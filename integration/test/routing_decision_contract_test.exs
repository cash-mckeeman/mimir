defmodule Integration.RoutingDecisionContractTest do
  @moduledoc """
  Runs a producer-generated decision envelope through the HTTP pull and mapper
  to guard the routing type agreement between independent packages.
  """
  use ExUnit.Case, async: true

  alias Integration.Fixtures
  alias Mimir.{CloudEvent, DecisionRecord}
  alias MimirAnalytics.{Ingest.GatewayPull, Mappers.GatewayExport, Store}

  @moduletag :tmp_dir

  test "a decision envelope from mimir becomes a routing_decisions row", %{tmp_dir: dir} do
    record = Fixtures.decision_record()

    {:ok, envelope} =
      CloudEvent.new(
        id: "ev-1",
        source: "//gateway.example/integration",
        type: CloudEvent.Types.routing_decision(),
        time: "2026-10-02T00:00:00Z",
        data: DecisionRecord.to_event(record)
      )

    row = Fixtures.request_log_row([CloudEvent.to_wire(envelope)])

    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.query_params["updated_since"] do
        "c0" -> Req.Test.json(conn, %{"rows" => [row], "next_updated_since" => "c1"})
        _ -> Req.Test.json(conn, %{"rows" => [], "next_updated_since" => nil})
      end
    end)

    {:ok, %{files: [file]}} =
      GatewayPull.pull(
        base_url: "http://gateway.test",
        token: "test-token",
        dir: dir,
        updated_since: "c0",
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    {:ok, store} = Store.open(:memory)
    on_exit(fn -> Store.close(store) end)
    {:ok, _summary} = GatewayExport.ingest(store, file)

    assert {:ok, [[decision_id]]} =
             Store.query(store, "SELECT decision_id FROM routing_decisions")

    assert decision_id == record.decision_id
  end
end
