defmodule Integration.ExecutionBindingContractTest do
  use ExUnit.Case, async: true
  alias Integration.ExecutionBindingHTTP
  alias MimirOrchestration.{Compiler, Exec, NodeResult, Policy}
  alias MimirOrchestration.AgentRunner.RMA.Reference

  defmodule Router do
    @behaviour Mimir.RouterClient
    @impl true
    def route(_request, opts) do
      Mimir.RouteResponse.new(%{
        "verdict" => "placement",
        "decision_id" => "decision-test",
        "placement" => %{
          "model" => "anthropic:claude-sonnet-4-6",
          "runtime" => Keyword.get(opts, :runtime, "local")
        },
        "grant" => %{"key" => "vk-test-binding"}
      })
    end
  end

  defmodule Tools do
    def handle_tool_call(_, _, _), do: {:error, :unexpected_tool}
  end

  setup do
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    %{bypass: bypass, counter: counter, base: "http://127.0.0.1:#{bypass.port}"}
  end

  test "default Local execution preserves the routed HTTP contract", %{
    bypass: bypass,
    counter: counter,
    base: base
  } do
    ExecutionBindingHTTP.expect(bypass, self(), counter, "/v1/chat/completions")

    assert {:ok, %{results: %{"ask" => %NodeResult{text: "ok", raw: raw}}}} =
             Exec.run(compiled("agent"), %{},
               router: {Router, []},
               workflow_id: "wf-http",
               data_plane: %{chat_completions: base <> "/v1"},
               agent_runner_opts: [handler: Tools]
             )

    assert raw.text == "ok"
    assert raw.usage.input_tokens == 12
    assert raw.usage.output_tokens == 4
    assert raw.usage.complete? == false

    assert_receive {:wire, "/v1/chat/completions", ["Bearer vk-test-binding"],
                    "anthropic:claude-sonnet-4-6"}

    assert Agent.get(counter, & &1) == 1
  end

  test "the real Session receives binding model and telemetry correlation", %{
    bypass: bypass,
    counter: counter,
    base: base
  } do
    owner = self()
    name = :"binding_http_#{System.unique_integer([:positive])}"
    Process.register(owner, name)
    handler = {__MODULE__, name}

    :ok =
      :telemetry.attach(
        handler,
        [:req_managed_agents, :session, :terminal],
        &__MODULE__.capture_terminal/4,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    ExecutionBindingHTTP.expect(bypass, owner, counter, "/v1/chat/completions")

    assert {:ok, _} =
             Exec.run(
               compiled("agent", Integration.ExecutionBindingLocal, %{test_owner: name}),
               %{},
               router: {Router, []},
               workflow_id: "wf-correlation",
               data_plane: %{chat_completions: base <> "/v1"},
               agent_runner_opts: [handler: Tools]
             )

    assert_received {:provider_open,
                     %{
                       model: "anthropic:claude-sonnet-4-6",
                       api_key: "vk-test-binding",
                       base_url: routed_base,
                       metadata: metadata
                     }}

    assert routed_base == base <> "/v1"

    assert metadata == %{
             workflow_id: "wf-correlation",
             step_id: "ask",
             decision_id: "decision-test",
             mimir_request_id: "decision-test"
           }

    assert_received {:session_terminal, telemetry}

    assert Map.take(telemetry, [:workflow_id, :step_id, :decision_id, :mimir_request_id]) ==
             metadata

    assert Agent.get(counter, & &1) == 1
    refute_received {:provider_open, _}
  end

  def capture_terminal(_event, _measurements, %{workflow_id: "wf-correlation"} = metadata, owner),
    do: send(owner, {:session_terminal, metadata})

  def capture_terminal(_event, _measurements, _metadata, _owner), do: :ok

  for prefix <- ["/v1", "/prefix/v1"] do
    test "a routed model step preserves configured base #{prefix}", %{
      bypass: bypass,
      counter: counter,
      base: base
    } do
      path = unquote(prefix) <> "/chat/completions"
      ExecutionBindingHTTP.expect(bypass, self(), counter, path)

      assert {:ok, %{results: %{"ask" => "ok"}}} =
               Exec.run(compiled("llm"), %{},
                 router: {Router, []},
                 data_plane: %{chat_completions: base <> unquote(prefix)}
               )

      assert_receive {:wire, ^path, ["Bearer vk-test-binding"], "anthropic:claude-sonnet-4-6"}
      assert Agent.get(counter, & &1) == 1
    end
  end

  test "an incompatible model target refuses without HTTP", %{
    bypass: bypass,
    counter: counter,
    base: base
  } do
    ExecutionBindingHTTP.stub(bypass, self(), counter, "/chat/completions")

    assert {:error,
            {:step_failed, "ask", {:target_mismatch, {:plane, {:no_url_for, :chat_completions}}}}} =
             Exec.run(compiled("llm"), %{},
               router: {Router, []},
               data_plane: %{managed_agents_api: base}
             )

    assert {:error, {:step_failed, "ask", {:target_mismatch, {:runtime, "managed", "local"}}}} =
             Exec.run(compiled("llm"), %{},
               router: {Router, [runtime: "managed"]},
               data_plane: %{chat_completions: base}
             )

    assert Agent.get(counter, & &1) == 0
    refute_received {:wire, _, _, _}

    assert {:ok, %{results: %{"ask" => "ok"}}} =
             Exec.run(compiled("llm"), %{},
               router: {Router, []},
               data_plane: %{chat_completions: base}
             )

    assert Agent.get(counter, & &1) == 1

    assert_received {:wire, "/chat/completions", ["Bearer vk-test-binding"],
                     "anthropic:claude-sonnet-4-6"}
  end

  defp compiled(kind, provider \\ ReqManagedAgents.Providers.Local, spec \\ %{}) do
    {:ok, reference} =
      Reference.new(
        provider: provider,
        runtime: "local",
        resource: {:handle, %{spec: Map.merge(%{system_prompt: "brief"}, spec), max_turns: 2}}
      )

    step = %{
      "id" => "ask",
      "kind" => kind,
      "depends_on" => [],
      "descriptor" => %{"budget_ceiling_microdollars" => 1}
    }

    step =
      if kind == "agent",
        do: Map.merge(step, %{"agent" => "assistant", "input" => "hello"}),
        else: Map.put(step, "prompt", "hello")

    {:ok, compiled} =
      Compiler.compile(
        %{"name" => "wire", "version" => 1, "params" => [], "steps" => [step]},
        %Policy{agent_registry: %{"assistant" => reference}, budget_ceiling_microdollars: 1}
      )

    compiled
  end
end
