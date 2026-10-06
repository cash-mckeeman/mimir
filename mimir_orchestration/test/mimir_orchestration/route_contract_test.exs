defmodule MimirOrchestration.RouteContractTest do
  @moduledoc """
  The route request the runner sends parses as a `Mimir.Descriptor`; a placement
  `Mimir.Oracle` chose, rendered as the gateway's wire body, parses as a
  `Mimir.RouteResponse`; and the dispatch receives the grant's model and a turn guard.
  """
  use ExUnit.Case, async: true

  alias MimirOrchestration.{Runner, StepCall}

  defmodule WireRouter do
    @behaviour Mimir.RouterClient
    @impl true
    def route(request, opts) do
      {:ok, descriptor} = Mimir.Descriptor.parse(request)
      send(Keyword.fetch!(opts, :owner), {:parsed, descriptor, request})

      # Faster than the tools entry, so only the capability requirement picks the
      # other one.
      plain = %Mimir.Catalog.Entry{
        id: "local-plain",
        model: "ollama:model-plain",
        model_spec: "ollama:model-plain",
        lane: "ollama",
        runtime: :local,
        capabilities: [],
        p50_latency_ms: 100,
        priority: 100
      }

      tools = %Mimir.Catalog.Entry{
        id: "local-tools",
        model: "ollama:model-tools",
        model_spec: "ollama:model-tools",
        lane: "ollama",
        runtime: :local,
        capabilities: [:tools],
        p50_latency_ms: 1_000,
        priority: 100
      }

      snapshot =
        Mimir.Snapshot.assemble(
          pricing: %{
            "ollama:model-plain" => %{input: 0, output: 0},
            "ollama:model-tools" => %{input: 0, output: 0}
          },
          health: %{},
          parent_remaining: :unlimited
        )

      {:decision, %Mimir.Oracle.Decision{entry: chosen}} =
        Mimir.Oracle.decide(descriptor, [plain, tools], %Mimir.Oracle.Policy{}, snapshot)

      Mimir.RouteResponse.new(%{
        "verdict" => "placement",
        "decision_id" => "rd_contract",
        "placement" => %{
          "model" => chosen.model,
          "lane" => to_string(chosen.lane),
          "runtime" => to_string(chosen.runtime)
        },
        "grant" => %{
          "key" => "vk-contract",
          "budget_microdollars" => 50_000,
          "expires_at" => "2026-10-03T00:00:00Z"
        }
      })
    end
  end

  def report(%StepCall{opts: opts}, to) do
    send(to, {:dispatched, opts})
    {:ok, :done}
  end

  test "request, response and dispatch agree" do
    name = :"route_contract_#{System.unique_integer([:positive])}"
    Process.register(self(), name)

    steps = [
      %{
        id: "a",
        target: :t,
        input: 1,
        depends_on: [],
        descriptor: %{
          "task_class" => "extract",
          "budget_ceiling_microdollars" => 50_000,
          "latency_tolerance_ms" => 30_000,
          "capabilities" => ["tools"],
          "runtime_preference" => "local",
          "expected_tokens" => %{"in" => 100, "out" => 50},
          "agent" => %{"digest" => "sha256:contract"},
          "max_outcome_iterations" => 2
        }
      }
    ]

    assert {:ok, _} =
             Runner.run(steps,
               router: {WireRouter, [owner: name]},
               run: {__MODULE__, :report, [name]},
               workflow_id: "wf-c"
             )

    assert_received {:parsed, descriptor, request}

    assert descriptor == %Mimir.Descriptor{
             task_class: "extract",
             capabilities: [:tools],
             budget_ceiling_microdollars: 50_000,
             latency_tolerance_ms: 30_000,
             runtime_preference: :local,
             expected_tokens: %{in: 100, out: 50},
             agent: %{digest: "sha256:contract", name: nil, version: nil},
             max_outcome_iterations: 2
           }

    assert %{
             workflow_id: "wf-c",
             step_id: "a",
             fanout_hint: 1,
             path: ["workflow:wf-c", "workflow_step:a"]
           } = request

    refute Map.has_key?(request, :descriptor)
    refute Map.has_key?(request, "descriptor")

    assert_received {:dispatched, opts}
    assert opts[:model] == %{"key" => "vk-contract", "model" => "ollama:model-tools"}
    assert is_function(opts[:turn_guard], 1)
    assert opts[:metadata][:decision_id] == "rd_contract"
  end
end
