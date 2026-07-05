defmodule Mimir.SessionsTest do
  use ExUnit.Case, async: false

  @resp %{
    verdict: "placement",
    placement: %{
      lane: "anthropic",
      model: "anthropic:claude-sonnet-4-6",
      runtime: "managed",
      reasons: [],
      candidates: []
    },
    grant: %{key: "vk-grant", expires_at: nil, budget_microdollars: 50_000},
    workflow_id: "wf1",
    step_id: "s1",
    decision_id: "rd_1",
    snapshot_at: "2026-07-04T00:00:00Z"
  }

  setup do
    Application.put_env(:mimir, :pricing, %{
      "anthropic:claude-sonnet-4-6" => %{input: 3_000_000, output: 15_000_000}
    })

    on_exit(fn ->
      Application.delete_env(:mimir, :pricing)
      Application.delete_env(:mimir, :gateway_base_url)
    end)
  end

  test "builds model_config, turn_guard, telemetry_metadata from a placement" do
    opts = Mimir.Sessions.opts(@resp, base_url: "https://mimir.example/v1", request_id: "req_x")

    assert opts[:model_config] == %{
             model: "anthropic:claude-sonnet-4-6",
             api_key: "vk-grant",
             base_url: "https://mimir.example/v1",
             metadata: %{
               mimir_request_id: "req_x",
               decision_id: "rd_1",
               workflow_id: "wf1",
               step_id: "s1"
             }
           }

    assert opts[:telemetry_metadata] == opts[:model_config].metadata

    # the guard is live: grant budget 50_000 µ$; 10k in + 10k out = 180_000 µ$ → halt
    assert {:halt, {:budget_exceeded, _}} =
             opts[:turn_guard].(%{
               usage: %{input_tokens: 10_000, output_tokens: 10_000},
               turns: 1
             })

    assert :cont = opts[:turn_guard].(%{usage: %{input_tokens: 10, output_tokens: 10}, turns: 1})
  end

  test "base_url falls back to config and is omitted when absent" do
    Application.put_env(:mimir, :gateway_base_url, "https://cfg.example/v1")
    assert Mimir.Sessions.opts(@resp)[:model_config].base_url == "https://cfg.example/v1"

    Application.delete_env(:mimir, :gateway_base_url)
    refute Map.has_key?(Mimir.Sessions.opts(@resp)[:model_config], :base_url)
  end

  test "generates a request id when none is given" do
    opts = Mimir.Sessions.opts(@resp)
    assert "req_route_" <> _ = opts[:telemetry_metadata].mimir_request_id
  end

  test "extra guard caps compose" do
    opts = Mimir.Sessions.opts(@resp, guard: [max_turns: 2])

    assert {:halt, {:max_turns, _}} =
             opts[:turn_guard].(%{usage: %{input_tokens: 1, output_tokens: 1}, turns: 2})
  end

  test "raises at composition time on no_candidate or malformed responses" do
    assert_raise ArgumentError, ~r/no placement/, fn ->
      Mimir.Sessions.opts(%{@resp | verdict: "no_candidate", placement: nil})
    end

    assert_raise ArgumentError, ~r/no grant/, fn ->
      Mimir.Sessions.opts(%{@resp | grant: nil})
    end

    assert_raise ArgumentError, ~r/grant has no key/, fn ->
      Mimir.Sessions.opts(%{@resp | grant: %{budget_microdollars: 1}})
    end
  end

  test "accepts string-keyed responses (raw JSON that skipped the client)" do
    resp = %{
      "verdict" => "placement",
      "placement" => %{
        "model" => "anthropic:claude-sonnet-4-6",
        "lane" => "anthropic",
        "runtime" => "managed"
      },
      "grant" => %{"key" => "vk-g", "budget_microdollars" => 10},
      "workflow_id" => "wf",
      "step_id" => "s",
      "decision_id" => "rd"
    }

    opts = Mimir.Sessions.opts(resp, base_url: "https://x/v1")
    assert opts[:model_config].api_key == "vk-g"
    assert opts[:model_config].model == "anthropic:claude-sonnet-4-6"
  end
end
