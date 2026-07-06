defmodule Mimir.RouteResponseTest do
  use ExUnit.Case, async: true

  alias Mimir.{Candidate, Grant, Placement, RouteResponse}

  @atom_placement %{
    verdict: "placement",
    placement: %{
      lane: "anthropic",
      model: "anthropic:claude-sonnet-4-6",
      runtime: "managed",
      reasons: ["capability_match", "cheapest_viable"],
      candidates: [%{id: "claude", verdict: "chosen"}]
    },
    grant: %{key: "vk-grant", expires_at: nil, budget_microdollars: 50_000},
    workflow_id: "wf1",
    step_id: "s1",
    decision_id: "rd_1",
    snapshot_at: "2026-07-04T00:00:00Z"
  }

  test "parses an atom-keyed placement response into structs" do
    assert {:ok, %RouteResponse{} = r} = RouteResponse.new(@atom_placement)
    assert r.verdict == :placement

    assert r.placement == %Placement{
             lane: "anthropic",
             model: "anthropic:claude-sonnet-4-6",
             runtime: "managed"
           }

    assert r.grant == %Grant{key: "vk-grant", expires_at: nil, budget_microdollars: 50_000}
    assert r.decision_id == "rd_1"
    assert r.workflow_id == "wf1"
    assert r.step_id == "s1"
    # reasons/candidates lifted from inside placement to the top level
    assert r.reasons == ["capability_match", "cheapest_viable"]
    assert r.candidates == [%Candidate{id: "claude", verdict: :chosen}]
  end

  test "parses a string-keyed response (raw JSON that skipped the client)" do
    resp = %{
      "verdict" => "placement",
      "placement" => %{
        "model" => "anthropic:claude-sonnet-4-6",
        "lane" => "anthropic",
        "runtime" => "managed"
      },
      "grant" => %{"key" => "vk-g", "budget_microdollars" => 10},
      "decision_id" => "rd"
    }

    assert {:ok, r} = RouteResponse.new(resp)
    assert r.grant == %Grant{key: "vk-g", expires_at: nil, budget_microdollars: 10}
    assert r.placement.model == "anthropic:claude-sonnet-4-6"
  end

  test "parses a no_candidate response: nil placement/grant, top-level candidates/reasons" do
    resp = %{
      "verdict" => "no_candidate",
      "reasons" => ["health"],
      "candidates" => [
        %{"id" => "claude", "verdict" => "excluded", "reason" => "{:health, :degraded}"}
      ]
    }

    assert {:ok, r} = RouteResponse.new(resp)
    assert r.verdict == :no_candidate
    assert r.placement == nil
    assert r.grant == nil
    assert r.reasons == ["health"]

    assert r.candidates == [
             %Candidate{id: "claude", verdict: {:excluded, "{:health, :degraded}"}}
           ]
  end

  test "errors on a placement verdict with no model" do
    resp = %{verdict: "placement", placement: %{lane: "x"}, grant: %{key: "k"}}
    assert {:error, {:invalid_route_response, :placement_missing_model}} = RouteResponse.new(resp)
  end

  test "errors on an unknown verdict and on a non-map" do
    assert {:error, {:invalid_route_response, {:verdict, "weird"}}} =
             RouteResponse.new(%{verdict: "weird"})

    assert {:error, {:invalid_route_response, :not_a_map}} = RouteResponse.new("nope")
  end

  test "grant absent yields nil grant on a placement verdict" do
    assert {:ok, r} = RouteResponse.new(%{verdict: "placement", placement: %{model: "m"}})
    assert r.grant == nil
  end
end
