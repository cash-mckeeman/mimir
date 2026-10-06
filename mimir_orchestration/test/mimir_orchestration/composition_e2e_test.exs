defmodule MimirOrchestration.CompositionE2ETest do
  use ExUnit.Case, async: true
  alias MimirOrchestration.{Compiler, Eval, Exec, NodeResult, Policy}

  defmodule Router do
    @behaviour Mimir.RouterClient
    @impl true
    def route(req, _opts) do
      Mimir.RouteResponse.new(%{
        "verdict" => "placement",
        "placement" => %{"model" => "fleet-fast"},
        "grant" => %{"key" => "k"},
        "decision_id" => "d-#{req.step_id}"
      })
    end
  end

  defmodule StubRunner do
    @behaviour MimirOrchestration.AgentRunner
    @impl true
    def run({:rma, name}, input, opts) do
      send(opts[:owner], {:dispatched, name, input, opts[:metadata]})
      {:ok, %NodeResult{text: "out-#{name}", stop_reason: "end_turn", raw: %{}}}
    end
  end

  @spec_map %{
    "name" => "brief",
    "version" => 1,
    "params" => ["q"],
    "steps" => [
      %{
        "id" => "analyze",
        "kind" => "agent",
        "agent" => "a",
        "input" => "{{params.q}}",
        "descriptor" => %{"task_class" => "analysis", "budget_ceiling_microdollars" => 1},
        "depends_on" => []
      },
      %{
        "id" => "narrate",
        "kind" => "agent",
        "agent" => "b",
        "input" => "{{analyze}}",
        "descriptor" => %{"task_class" => "narrative", "budget_ceiling_microdollars" => 1},
        "depends_on" => ["analyze"]
      },
      %{
        "id" => "title",
        "kind" => "llm",
        "prompt" => "title: {{narrate}}",
        "descriptor" => %{"budget_ceiling_microdollars" => 1},
        "depends_on" => ["narrate"]
      }
    ]
  }

  def title(%{prompt: p}), do: {:ok, "TITLE(#{String.slice(p, 0, 6)})"}
  def live_title(%{prompt: _}), do: {:ok, "live-title"}

  # Pids may not cross the executor seam: the test process is reached by name.
  defp owner do
    name = :"composition_e2e_#{System.unique_integer([:positive])}"
    Process.register(self(), name)
    name
  end

  defp policy do
    %Policy{
      agent_registry: %{"a" => {:rma, "a"}, "b" => {:rma, "b"}},
      budget_ceiling_microdollars: 10
    }
  end

  test "three-node composition: dataflow + one workflow_id across the tree" do
    {:ok, compiled} = Compiler.compile(@spec_map, policy())

    assert {:ok, %{results: results, workflow_id: "wf-e2e"}} =
             Exec.run(compiled, %{"q" => "kpis?"},
               router: {Router, []},
               workflow_id: "wf-e2e",
               agent_runner: StubRunner,
               agent_runner_opts: [owner: owner()],
               llm_opts: [chat: {__MODULE__, :title, []}]
             )

    assert results["analyze"].text == "out-a"
    assert results["narrate"].text == "out-b"
    # the llm prompt interpolated narrate's TEXT ("title: out-b"), not the struct
    assert results["title"] == "TITLE(title:)"

    assert_receive {:dispatched, "a", "kpis?", %{workflow_id: "wf-e2e", step_id: "analyze"}}

    assert_receive {:dispatched, "b", %NodeResult{text: "out-a"} = _narr_input,
                    %{workflow_id: "wf-e2e", step_id: "narrate"}}
  end

  test "the same spec scores clean on plan evals" do
    assert %{compiles: true, errors: 0, dead_steps: []} = Eval.plan_score(@spec_map, policy())
  end

  @tag :live
  test "live gateway canary (requires MIMIR_GATEWAY_URL + admin token)" do
    url = System.get_env("MIMIR_GATEWAY_URL")

    if url in [nil, ""] do
      flunk("set MIMIR_GATEWAY_URL (and credentials) to run the live canary")
    end

    # Minimal live check: the composition's flat route request reaches the real
    # gateway, which places the step or refuses it with a typed verdict
    # (:no_candidate, :no_grant). A transport error or an unparsable reply fails it.
    defmodule LiveRouter do
      @behaviour Mimir.RouterClient
      @impl true
      def route(req, opts) do
        base = Keyword.fetch!(opts, :url)
        token = System.fetch_env!("MIMIR_ADMIN_TOKEN")
        body = Jason.encode!(req)

        request =
          {~c"#{base}/v1/route", [{~c"authorization", ~c"Bearer #{token}"}], ~c"application/json",
           body}

        # House rule: :httpc always with verify_peer TLS specced (https only).
        http_opts =
          if String.starts_with?(base, "https") do
            [
              ssl: [
                verify: :verify_peer,
                cacerts: :public_key.cacerts_get(),
                depth: 3,
                customize_hostname_check: [
                  match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
                ]
              ]
            ]
          else
            []
          end

        case :httpc.request(:post, request, http_opts, []) do
          {:ok, {{_, 200, _}, _, resp}} ->
            resp |> to_string() |> Jason.decode!() |> Mimir.RouteResponse.new()

          other ->
            {:error, other}
        end
      end
    end

    {:ok, compiled} = Compiler.compile(@spec_map, policy())

    result =
      Exec.run(compiled, %{"q" => "live kpis?"},
        router: {LiveRouter, [url: url]},
        agent_runner: MimirOrchestration.CompositionE2ETest.StubRunner,
        agent_runner_opts: [owner: owner()],
        llm_opts: [chat: {__MODULE__, :live_title, []}]
      )

    assert match?({:ok, _}, result) or
             match?(
               {:error, {:step_failed, _, {:routing_failed, reason}}}
               when reason in [:no_candidate, :no_grant],
               result
             )
  end
end
