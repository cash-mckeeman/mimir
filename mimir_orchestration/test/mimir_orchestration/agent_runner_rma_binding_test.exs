defmodule MimirOrchestration.AgentRunner.RMABindingTest do
  use ExUnit.Case, async: true
  @moduletag :rma
  alias MimirOrchestration.AgentRunner.RMA
  alias MimirOrchestration.AgentRunner.RMA.Reference

  defmodule RuntimeProvider do
    def supports_runtime_model?, do: true
    def data_plane, do: :chat_completions
    def native_model("unsupported"), do: :error
    def native_model(model), do: {:ok, model}
  end

  defmodule FixedProvider do
    def supports_runtime_model?, do: false
    def data_plane, do: :managed_agents_api
  end

  defmodule ControlProvider do
    def supports_runtime_model?, do: true
    def data_plane, do: :none
  end

  setup do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    owner = self()

    provision = fn _, {:spec, spec} ->
      Agent.update(counter, &(&1 + 1))
      {:ok, {:handle, spec}}
    end

    session = fn provider, handle, opts ->
      send(owner, {:session, provider, handle, opts})
      {:ok, %{text: "ok", terminal: :end_turn, usage: %{}}}
    end

    %{counter: counter, opts: [provision_fun: provision, session_fun: session]}
  end

  test "compatible binding provisions once and applies canonical controls", %{
    counter: counter,
    opts: opts
  } do
    binding = route_binding()

    assert {:ok, _} =
             RMA.run(
               reference(RuntimeProvider),
               "q",
               opts ++ [binding: binding, metadata: %{custom: "kept", workflow_id: "spoof"}]
             )

    assert Agent.get(counter, & &1) == 1
    assert_received {:session, RuntimeProvider, {:handle, %{}}, session_opts}

    assert session_opts[:model_config] == %{
             model: "anthropic:claude-sonnet-4-6",
             api_key: "vk-test-binding",
             base_url: "http://127.0.0.1:8080/v1",
             metadata: %{
               mimir_request_id: "decision-test",
               decision_id: "decision-test",
               workflow_id: "wf",
               step_id: "ask"
             }
           }

    assert session_opts[:telemetry_metadata].workflow_id == "wf"
    assert session_opts[:telemetry_metadata].custom == "kept"
    assert is_function(session_opts[:turn_guard], 1)
  end

  test "incompatible targets and models refuse before provisioning", %{
    counter: counter,
    opts: opts
  } do
    cases = [
      {reference(RuntimeProvider), route_binding(runtime: "managed"),
       {:runtime, "managed", "local"}},
      {reference(FixedProvider), route_binding(urls: %{}),
       {:model, "anthropic:claude-sonnet-4-6", :unknown}},
      {reference(FixedProvider, configured_model: "different"), route_binding(urls: %{}),
       {:model, "anthropic:claude-sonnet-4-6", "different"}},
      {reference(RuntimeProvider),
       route_binding(urls: %{managed_agents_api: "http://127.0.0.1:8080"}),
       {:plane, {:no_url_for, :chat_completions}}},
      {reference(ControlProvider), route_binding(), {:plane, :data_plane_unsupported}}
    ]

    for {ref, route, reason} <- cases do
      assert {:error, {:target_mismatch, ^reason}} = RMA.run(ref, "q", opts ++ [binding: route])
    end

    assert {:error, {:unsupported_model, "unsupported"}} =
             RMA.run(
               reference(RuntimeProvider),
               "q",
               opts ++ [binding: route_binding(model: "unsupported")]
             )

    assert Agent.get(counter, & &1) == 0
    refute_received {:session, _, _, _}
  end

  test "fixed targets use the declared catalog model without provisioning a replacement", %{
    counter: counter,
    opts: opts
  } do
    ref =
      reference(FixedProvider,
        configured_model: "anthropic:claude-sonnet-4-6",
        resource: {:handle, "existing-agent"}
      )

    assert {:ok, _} =
             RMA.run(
               ref,
               "q",
               opts ++
                 [binding: route_binding(urls: %{managed_agents_api: "http://127.0.0.1:8080"})]
             )

    assert Agent.get(counter, & &1) == 0
    assert_received {:session, FixedProvider, {:handle, "existing-agent"}, session_opts}
    assert session_opts[:model_config].api_key == "vk-test-binding"
    refute Map.has_key?(session_opts[:model_config], :model)
  end

  test "a control-plane binding supplies correlation without grant credentials", %{opts: opts} do
    assert {:ok, _} =
             RMA.run(reference(ControlProvider), "q", opts ++ [binding: route_binding(urls: %{})])

    assert_received {:session, ControlProvider, _, session_opts}
    assert session_opts[:model_config].model == "anthropic:claude-sonnet-4-6"
    refute Map.has_key?(session_opts[:model_config], :api_key)
    refute Map.has_key?(session_opts[:model_config], :base_url)
  end

  test "handles cannot replace binding or call controls or result ownership", %{opts: opts} do
    for {key, value} <- [
          model_config: %{model: "spoof"},
          turn_guard: :spoof,
          telemetry_metadata: %{},
          prompt: "spoof",
          handler: :spoof,
          timeout: 2,
          max_turns: 99,
          notify: self()
        ] do
      ref = reference(RuntimeProvider, resource: {:handle, %{key => value}})

      assert {:error, {:handle_overrides_run_option, ^key}} =
               RMA.run(
                 ref,
                 "q",
                 opts ++
                   [binding: route_binding(), handler: __MODULE__, timeout: 100, max_turns: 3]
               )
    end

    refute_received {:session, _, _, _}
  end

  test "open handle fields and a handle-only turn limit survive", %{opts: opts} do
    handle = %{spec: %{system_prompt: "brief"}, max_turns: 3, provider_field: "open"}

    assert {:ok, _} =
             RMA.run(
               reference(RuntimeProvider, resource: {:handle, handle}),
               "q",
               opts ++ [binding: route_binding()]
             )

    assert_received {:session, RuntimeProvider, {:handle, ^handle}, session_opts}
    refute Keyword.has_key?(session_opts, :max_turns)
  end

  test "Local refuses an injected chat transport on the data plane" do
    ref =
      reference(ReqManagedAgents.Providers.Local,
        resource: {:handle, %{chat_fun: fn _ -> flunk("must not call injected chat") end}}
      )

    assert {:error, :data_plane_unsupported} =
             RMA.run(ref, "q", binding: route_binding(), handler: __MODULE__)
  end

  defp reference(provider, extra \\ []) do
    {:ok, ref} =
      Reference.new(
        Keyword.merge([provider: provider, runtime: "local", resource: {:spec, %{}}], extra)
      )

    ref
  end

  defp route_binding(opts \\ []) do
    {:ok, response} =
      Mimir.RouteResponse.new(%{
        "verdict" => "placement",
        "decision_id" => "decision-test",
        "placement" => %{
          "model" => Keyword.get(opts, :model, "anthropic:claude-sonnet-4-6"),
          "runtime" => Keyword.get(opts, :runtime, "local")
        },
        "grant" => %{"key" => "vk-test-binding"}
      })

    {:ok, binding} =
      Mimir.Binding.new(response,
        workflow_id: "wf",
        step_id: "ask",
        data_plane: Keyword.get(opts, :urls, %{chat_completions: "http://127.0.0.1:8080/v1"})
      )

    binding
  end
end
