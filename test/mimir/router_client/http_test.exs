defmodule Mimir.RouterClient.HTTPTest do
  use ExUnit.Case, async: true

  alias Mimir.RouterClient.HTTP

  @placement_body %{
    "verdict" => "placement",
    "placement" => %{
      "lane" => "anthropic",
      "model" => "anthropic:claude-sonnet-4-6",
      "runtime" => "managed",
      "reasons" => ["cheapest_capable"],
      "candidates" => [%{"id" => "e1", "verdict" => "chosen"}]
    },
    "grant" => %{"key" => "vk-grant", "expires_at" => nil, "budget_microdollars" => 50_000},
    "workflow_id" => "wf1",
    "step_id" => "s1",
    "decision_id" => "rd_x",
    "snapshot_at" => "2026-07-04T00:00:00Z"
  }

  test "route/2 atomizes a placement response" do
    plug = fn conn -> Req.Test.json(conn, @placement_body) end

    assert {:ok, resp} =
             HTTP.route(%{task_class: "extraction"},
               base_url: "http://router.test",
               bearer_token: "vk-parent",
               plug: plug
             )

    assert resp.verdict == "placement"
    assert resp.placement.model == "anthropic:claude-sonnet-4-6"
    assert resp.grant.key == "vk-grant"
    assert [%{id: "e1", verdict: "chosen"}] = resp.placement.candidates
  end

  test "route/2 surfaces non-2xx as http_error" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(422, Jason.encode!(%{"error" => "invalid_descriptor"}))
    end

    assert {:error, {:http_error, 422, _body}} =
             HTTP.route(%{},
               base_url: "http://router.test",
               bearer_token: "vk-parent",
               plug: plug
             )
  end
end
