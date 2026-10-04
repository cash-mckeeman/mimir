defmodule MimirAnalytics.Ingest.GatewayPullTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.Ingest.GatewayPull

  @fixture Path.expand("../../support/run_record_fixtures/gateway_export.jsonl", __DIR__)

  # Sanitised captured envelopes and a synthetic legacy decision from the
  # fixture exercise both read paths; provenance is in the fixtures README.
  defp captured_turn_events do
    @fixture
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find(&(&1["kind"] == "request_log"))
    |> Map.fetch!("turn_events")
  end

  defp row do
    %{
      "request_id" => "req_9f1",
      "virtual_key_id" => "vk_1",
      "tenant_id" => "tenant-a",
      "lane" => "bedrock_reason",
      "provider" => "bedrock",
      "model_id" => "nemotron-super-3-120b",
      "status" => "success",
      "input_tokens" => 4100,
      "output_tokens" => 600,
      "cost_microdollars" => 1834,
      "workflow_id" => "wf_demo1",
      "step_id" => "analyze",
      "inserted_at" => "2026-07-08T00:00:01",
      "turn_events" => captured_turn_events()
    }
  end

  defp stub_pages(row) do
    Req.Test.stub(GatewayPull, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.params["updated_since"] do
        "2026-07-08T00:00:01" ->
          Req.Test.json(conn, %{"rows" => [], "next_updated_since" => nil})

        _ ->
          Req.Test.json(conn, %{"rows" => [row], "next_updated_since" => "2026-07-08T00:00:01"})
      end
    end)
  end

  defp pull_lines(dir) do
    {:ok, %{files: [file], last_cursor: "2026-07-08T00:00:01"}} =
      GatewayPull.pull(
        base_url: "http://gateway.test",
        token: "t",
        updated_since: "2026-07-01T00:00:00",
        dir: dir,
        req_options: [plug: {Req.Test, GatewayPull}]
      )

    file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  @tag :tmp_dir
  test "a routing.decision CloudEvent becomes a routing_decision line with the decision's own ts",
       %{tmp_dir: dir} do
    stub_pages(row())
    lines = pull_lines(dir)

    # The captured turn_events carries an enveloped decision AND a legacy bare
    # one — both are lifted, alongside the request_log line itself.
    assert Enum.map(lines, & &1["kind"]) |> Enum.sort() ==
             ["request_log", "routing_decision", "routing_decision"]

    decision =
      Enum.find(lines, &(&1["kind"] == "routing_decision" and &1["decision_id"] != "rd_abc"))

    assert String.starts_with?(decision["decision_id"], "rd_")
    assert is_map(decision["verdict"])
    assert is_map(decision["descriptor"])
    # the envelope's wall-clock, not the row's inserted_at
    assert decision["ts"] != "2026-07-08T00:00:01"
    assert {:ok, _, _} = DateTime.from_iso8601(decision["ts"])

    # the legacy entry in the same array falls back to the row's inserted_at
    legacy =
      Enum.find(lines, &(&1["kind"] == "routing_decision" and &1["decision_id"] == "rd_abc"))

    assert legacy["ts"] == "2026-07-08T00:00:01"
  end

  @tag :tmp_dir
  test "an enveloped decision missing `time` falls back to the row's inserted_at", %{
    tmp_dir: dir
  } do
    # Defensive-path variant, not a captured fixture: hand-derived from the
    # captured routing.decision entry by DROPPING its "time" attribute — the
    # producer always emits one, so this pins the fallback, not a producer
    # shape.
    [enveloped_decision] =
      for %{"specversion" => _, "type" => "ai.bizinsights.mimir.routing.decision"} = ce <-
            captured_turn_events()["events"],
          do: Map.delete(ce, "time")

    stub_pages(Map.put(row(), "turn_events", %{"events" => [enveloped_decision]}))
    lines = pull_lines(dir)

    decision = Enum.find(lines, &(&1["kind"] == "routing_decision"))
    assert decision["decision_id"] == enveloped_decision["data"]["decision_id"]
    assert decision["ts"] == "2026-07-08T00:00:01"
  end

  @tag :tmp_dir
  test "a pre-envelope routing_decision entry still yields a line", %{tmp_dir: dir} do
    legacy = %{
      "turn_events" => %{
        "events" => [
          %{
            "seq" => 1,
            "ts" => 1,
            "type" => "routing_decision",
            "decision" => %{
              "decision_id" => "rd_legacy",
              "verdict" => %{"outcome" => "placement"}
            }
          }
        ]
      }
    }

    stub_pages(Map.merge(row(), legacy))
    lines = pull_lines(dir)

    decision = Enum.find(lines, &(&1["kind"] == "routing_decision"))
    assert decision["decision_id"] == "rd_legacy"
    assert decision["ts"] == "2026-07-08T00:00:01"
  end

  @tag :tmp_dir
  test "a row with no decision entry yields only the request_log line", %{tmp_dir: dir} do
    stub_pages(Map.put(row(), "turn_events", %{"events" => []}))
    lines = pull_lines(dir)

    assert Enum.map(lines, & &1["kind"]) == ["request_log"]
  end

  describe "buffer filenames" do
    # The buffer file IS the ingest contract, so two pages resolving to one
    # filename loses a page with a successful write and nothing to notice it.
    # Under the composite `<rfc3339>|<uuid>` cursor the old digits-only name
    # made that reachable: same second, different rows, same filename.
    @tag :tmp_dir
    test "pages within one pull never share a filename, even on a shared second", %{
      tmp_dir: dir
    } do
      at = "2026-07-08T00:00:01Z"

      cursors = [
        "#{at}|aaaaaaaa-0000-4000-8000-000000000001",
        "#{at}|bbbbbbbb-0000-4000-8000-000000000001",
        "#{at}|cccccccc-0000-4000-8000-000000000001"
      ]

      # Three pages that all sit inside the same second, then an empty page.
      Req.Test.stub(GatewayPull, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        seen = conn.params["updated_since"]

        case Enum.find_index(cursors, &(&1 == seen)) do
          nil ->
            Req.Test.json(conn, %{"rows" => [row()], "next_updated_since" => hd(cursors)})

          i when i < length(cursors) - 1 ->
            Req.Test.json(conn, %{
              "rows" => [row()],
              "next_updated_since" => Enum.at(cursors, i + 1)
            })

          _ ->
            Req.Test.json(conn, %{"rows" => [], "next_updated_since" => seen})
        end
      end)

      {:ok, %{files: files}} =
        GatewayPull.pull(
          base_url: "http://gateway.test",
          token: "t",
          updated_since: "2026-07-01T00:00:00Z",
          dir: dir,
          req_options: [plug: {Req.Test, GatewayPull}]
        )

      # Three pages carry rows (the fourth response is the empty stop page).
      assert length(files) == 3
      assert length(Enum.uniq(files)) == 3, "two pages collided on one buffer filename"

      # Every page's bytes survived to disk — the property a collision breaks.
      for f <- files, do: assert(File.read!(f) != "")
      assert length(Enum.uniq(Enum.map(files, &Path.basename/1))) == 3
    end

    @tag :tmp_dir
    test "a re-pull of the same range is idempotent, not an accidental new file", %{
      tmp_dir: dir
    } do
      stub_pages(row())

      run = fn ->
        {:ok, %{files: files}} =
          GatewayPull.pull(
            base_url: "http://gateway.test",
            token: "t",
            updated_since: "2026-07-01T00:00:00",
            dir: dir,
            req_options: [plug: {Req.Test, GatewayPull}]
          )

        files
      end

      assert run.() == run.()
      assert length(Path.wildcard(Path.join(dir, "*.jsonl"))) == 1
    end
  end
end
