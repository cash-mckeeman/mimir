defmodule MimirOrchestration.RunnerGrantGuardTest do
  # Prices a synthetic model through the global `:mimir, :pricing` config, so it
  # runs outside the async modules that would otherwise see the setting.
  use ExUnit.Case, async: false
  alias MimirOrchestration.{Runner, StepCall}
  alias MimirOrchestration.Test.Registered

  @model "test:priced"

  setup do
    Application.put_env(:mimir, :pricing, %{@model => %{input: 1_000_000, output: 1_000_000}})
    on_exit(fn -> Application.delete_env(:mimir, :pricing) end)
  end

  defmodule PricedRouter do
    @behaviour Mimir.RouterClient
    @impl true
    def route(req, _opts) do
      Mimir.RouteResponse.new(%{
        "verdict" => "placement",
        "decision_id" => "dec-#{req.step_id}",
        "placement" => %{"model" => "test:priced", "lane" => "bedrock", "runtime" => "local"},
        "grant" => %{"key" => "sk-grant", "budget_microdollars" => 1_000}
      })
    end
  end

  def report(%StepCall{opts: opts}, to) do
    send(to, {:opts, opts})
    {:ok, :done}
  end

  test "the turn guard halts once the placed model's spend passes the grant's budget" do
    name = Registered.self_name()

    steps = [
      %{id: "a", target: :t, input: 1, descriptor: %{"task_class" => "t"}, depends_on: []}
    ]

    assert {:ok, _} =
             Runner.run(steps,
               router: {PricedRouter, []},
               run: {__MODULE__, :report, [name]},
               workflow_id: "wf"
             )

    assert_receive {:opts, opts}

    # 10M tokens each way at 1 µ$ per token: only the placed model prices to 20M.
    assert {:halt,
            {:budget_exceeded, %{budget_microdollars: 1_000, cost_microdollars: 20_000_000}}} =
             opts[:turn_guard].(%{
               usage: %{input_tokens: 10_000_000, output_tokens: 10_000_000},
               turns: 1
             })
  end
end
