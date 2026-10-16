defmodule Mimir.BindingTest do
  use ExUnit.Case, async: false

  alias Mimir.{Binding, RouteResponse}
  alias Mimir.Binding.Target

  @wire %{
    "verdict" => "placement",
    "placement" => %{
      "lane" => "anthropic",
      "model" => "anthropic:claude-sonnet-4-6",
      "runtime" => "managed"
    },
    "grant" => %{"key" => "vk-grant", "budget_microdollars" => 50_000},
    "workflow_id" => "wf1",
    "step_id" => "s1",
    "decision_id" => "rd_1"
  }

  @urls %{
    chat_completions: "https://gw.example/v1",
    managed_agents_api: "https://gw.example"
  }

  defp resp(changes \\ %{}) do
    {:ok, resp} = @wire |> Map.merge(changes) |> RouteResponse.new()
    resp
  end

  describe "new/2" do
    test "preserves the route decision and data-plane URLs without choosing a target" do
      assert {:ok, %Binding{} = binding} = Binding.new(resp(), data_plane: @urls)
      assert binding.decision_id == "rd_1"
      assert binding.request_id == "rd_1"
      assert binding.workflow_id == "wf1"
      assert binding.step_id == "s1"
      assert binding.placement.lane == "anthropic"
      assert binding.placement.model == "anthropic:claude-sonnet-4-6"
      assert binding.placement.runtime == "managed"
      assert binding.grant.key == "vk-grant"
      assert binding.grant.budget_microdollars == 50_000
      assert binding.data_plane_urls == @urls
      assert binding.target == nil
    end

    test "inspect omits the grant credential" do
      {:ok, binding} = Binding.new(resp())
      refute inspect(binding) =~ "vk-grant"
    end

    test "the request id can override the decision id without changing it" do
      assert {:ok, %Binding{request_id: "req_7", decision_id: "rd_1"}} =
               Binding.new(resp(), request_id: "req_7")
    end

    test "nil options preserve response ids and leave data-plane URLs unset" do
      assert {:ok,
              %Binding{
                request_id: "rd_1",
                workflow_id: "wf1",
                step_id: "s1"
              } = binding} =
               Binding.new(resp(),
                 request_id: nil,
                 workflow_id: nil,
                 step_id: nil,
                 data_plane: nil
               )

      assert binding.data_plane_urls == %{}
      assert {:ok, empty_plane} = Binding.new(resp(), data_plane: %{})
      assert empty_plane.data_plane_urls == %{}
    end

    test "caller ids fill gaps in the response" do
      assert {:ok, %Binding{workflow_id: "wf9", step_id: "s9"}} =
               Binding.new(resp(%{"workflow_id" => nil, "step_id" => nil}),
                 workflow_id: "wf9",
                 step_id: "s9"
               )

      assert {:ok, %Binding{workflow_id: nil, step_id: nil}} =
               Binding.new(resp(%{"workflow_id" => nil, "step_id" => nil}))
    end

    test "caller ids equal to the response ids are accepted" do
      assert {:ok, %Binding{workflow_id: "wf1", step_id: "s1"}} =
               Binding.new(resp(), workflow_id: "wf1", step_id: "s1")
    end

    test "caller ids that contradict the response are conflicts" do
      assert Binding.new(resp(), workflow_id: "other") ==
               {:error, {:invalid_binding, {:correlation_conflict, :workflow_id}}}

      assert Binding.new(resp(), step_id: "other") ==
               {:error, {:invalid_binding, {:correlation_conflict, :step_id}}}
    end

    test "refuses decisions without an executable verdict, grant or decision id" do
      {:ok, no_candidate} = RouteResponse.new(%{"verdict" => "no_candidate"})
      assert Binding.new(no_candidate) == {:error, {:invalid_binding, {:verdict, :no_candidate}}}
      assert Binding.new(resp(%{"grant" => nil})) == {:error, {:invalid_binding, :grant_missing}}

      for decision_id <- [nil, "", 7, false] do
        assert Binding.new(resp(%{"decision_id" => decision_id})) ==
                 {:error, {:invalid_binding, :decision_id_missing}}
      end
    end

    test "refuses unknown options and mistyped ids" do
      assert Binding.new(resp(), base_url: "x") ==
               {:error, {:invalid_binding, {:option, :base_url}}}

      assert Binding.new(resp(), target: nil) == {:error, {:invalid_binding, {:option, :target}}}

      for key <- [:request_id, :workflow_id, :step_id], value <- ["", 7, false, %{}] do
        assert Binding.new(resp(), [{key, value}]) ==
                 {:error, {:invalid_binding, {:option, key}}}
      end
    end

    test "refuses an unknown wire and mistyped data-plane URLs" do
      for urls <- [
            %{messages: "https://gw.example/v1"},
            %{"chat_completions" => "https://gw.example/v1"},
            %{none: "https://gw.example/v1"},
            %{chat_completions: ""},
            %{managed_agents_api: nil},
            %{chat_completions: 7},
            [chat_completions: "https://gw.example/v1"],
            %URI{},
            false
          ] do
        assert Binding.new(resp(), data_plane: urls) ==
                 {:error, {:invalid_binding, {:option, :data_plane}}}
      end
    end

    test "refuses option containers that are not keyword lists" do
      for opts <- [%{request_id: "req_7"}, nil, "opts", [:request_id], [{"request_id", "req_7"}]] do
        assert Binding.new(resp(), opts) ==
                 {:error, {:invalid_binding, {:option, :not_a_keyword}}}
      end
    end

    test "reads no application environment" do
      previous = Application.fetch_env(:mimir, :gateway_base_url)
      Application.put_env(:mimir, :gateway_base_url, "https://cfg.example/v1")

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:mimir, :gateway_base_url, value)
          :error -> Application.delete_env(:mimir, :gateway_base_url)
        end
      end)

      assert {:ok, binding} = Binding.new(resp())
      assert binding.data_plane_urls == %{}
    end
  end

  test "correlation/1 projects the authoritative ids with telemetry keys" do
    {:ok, binding} = Binding.new(resp(), request_id: "req_7")

    assert Binding.correlation(binding) == %{
             mimir_request_id: "req_7",
             decision_id: "rd_1",
             workflow_id: "wf1",
             step_id: "s1"
           }

    {:ok, unscoped} = Binding.new(resp(%{"workflow_id" => nil, "step_id" => nil}))

    assert Binding.correlation(unscoped) == %{
             mimir_request_id: "rd_1",
             decision_id: "rd_1",
             workflow_id: nil,
             step_id: nil
           }
  end

  defp target(attrs) do
    {:ok, target} =
      %{runtime: "managed", runtime_model: true, data_plane: :chat_completions}
      |> Map.merge(attrs)
      |> Target.new()

    target
  end

  # The unbound calls below are deliberate. Going through apply/3 with a variable
  # function name keeps the compile-time type checker from flagging them; the runtime
  # FunctionClauseError is what the tests assert.
  defp call_unbound(fun, binding), do: apply(Binding, fun, [binding])

  defp bound(opts \\ [], target_attrs \\ %{}) do
    {:ok, binding} = Binding.new(resp(), opts)
    {:ok, binding} = Binding.bind(binding, target(target_attrs))
    binding
  end

  describe "bind/2" do
    test "accepts a target serving the routed runtime" do
      {:ok, b} = Binding.new(resp())
      assert {:ok, %Binding{target: %Target{runtime: "managed"}}} = Binding.bind(b, target(%{}))
    end

    test "a placement without a runtime constrains nothing" do
      {:ok, b} = Binding.new(resp(%{"placement" => %{"model" => "anthropic:claude-sonnet-4-6"}}))
      assert {:ok, _} = Binding.bind(b, target(%{runtime: "local"}))
    end

    test "refuses another runtime; labels compare as exact strings" do
      {:ok, b} = Binding.new(resp())

      assert Binding.bind(b, target(%{runtime: "agentcore_harness"})) ==
               {:error, {:target_mismatch, {:runtime, "managed", "agentcore_harness"}}}

      # A scripted router's atom runtime is not the label "managed" (no casting).
      {:ok, atom_runtime} =
        Binding.new(
          resp(%{
            "placement" => %{"model" => "anthropic:claude-sonnet-4-6", "runtime" => :managed}
          })
        )

      assert Binding.bind(atom_runtime, target(%{})) ==
               {:error, {:target_mismatch, {:runtime, :managed, "managed"}}}
    end

    test "a target without per-run models must already run the routed one" do
      {:ok, b} = Binding.new(resp())

      assert {:ok, _} =
               Binding.bind(
                 b,
                 target(%{runtime_model: false, configured_model: "anthropic:claude-sonnet-4-6"})
               )

      assert Binding.bind(
               b,
               target(%{runtime_model: false, configured_model: "anthropic:claude-haiku-4-5"})
             ) ==
               {:error,
                {:target_mismatch,
                 {:model, "anthropic:claude-sonnet-4-6", "anthropic:claude-haiku-4-5"}}}

      assert Binding.bind(b, target(%{runtime_model: false})) ==
               {:error, {:target_mismatch, {:model, "anthropic:claude-sonnet-4-6", :unknown}}}
    end

    test "a per-run-model target runs the routed model whatever it is configured with" do
      {:ok, b} = Binding.new(resp())
      assert {:ok, _} = Binding.bind(b, target(%{runtime_model: true, configured_model: "other"}))
    end

    test "a data-plane binding needs a target with a wire, and a URL for that wire" do
      {:ok, data} = Binding.new(resp(), data_plane: %{chat_completions: "https://gw.example/v1"})

      assert Binding.bind(data, target(%{data_plane: :none})) ==
               {:error, {:target_mismatch, {:plane, :data_plane_unsupported}}}

      # A chat-completions URL cannot serve a managed-agents API target.
      assert Binding.bind(data, target(%{data_plane: :managed_agents_api})) ==
               {:error, {:target_mismatch, {:plane, {:no_url_for, :managed_agents_api}}}}

      assert {:ok, _} = Binding.bind(data, target(%{data_plane: :chat_completions}))
    end

    test "a control-plane binding binds to any wire, including none" do
      {:ok, control} = Binding.new(resp())

      for wire <- [:none, :chat_completions, :managed_agents_api] do
        assert {:ok, _} = Binding.bind(control, target(%{data_plane: wire}))
      end
    end
  end

  describe "model_config/1" do
    test "on the data plane: model, grant key, the target wire's URL and correlation" do
      b =
        bound(
          [
            data_plane: %{
              chat_completions: "https://gw.example/v1",
              managed_agents_api: "https://gw.example"
            },
            request_id: "req_7"
          ],
          %{data_plane: :chat_completions, configured_model: "other"}
        )

      assert Binding.model_config(b) == %{
               model: "anthropic:claude-sonnet-4-6",
               api_key: "vk-grant",
               base_url: "https://gw.example/v1",
               metadata: %{
                 mimir_request_id: "req_7",
                 decision_id: "rd_1",
                 workflow_id: "wf1",
                 step_id: "s1"
               }
             }
    end

    test "a managed-agents-API target gets that wire's URL" do
      b =
        bound(
          [
            data_plane: %{
              chat_completions: "https://gw.example/v1",
              managed_agents_api: "https://gw.example"
            }
          ],
          %{
            data_plane: :managed_agents_api,
            runtime_model: false,
            configured_model: "anthropic:claude-sonnet-4-6"
          }
        )

      assert Binding.model_config(b) == %{
               base_url: "https://gw.example",
               api_key: "vk-grant",
               metadata: Binding.correlation(b)
             }
    end

    test "on the control plane the grant key goes nowhere" do
      config = Binding.model_config(bound())

      assert config == %{
               model: "anthropic:claude-sonnet-4-6",
               metadata: Binding.correlation(bound())
             }

      refute Map.has_key?(config, :api_key)
      refute Map.has_key?(config, :base_url)
      refute inspect(config) =~ "vk-grant"
    end

    test "the model goes only to a target that applies it per run" do
      config =
        Binding.model_config(
          bound([], %{runtime_model: false, configured_model: "anthropic:claude-sonnet-4-6"})
        )

      assert config == %{metadata: Binding.correlation(bound())}
      refute Map.has_key?(config, :model)
      assert config.metadata.decision_id == "rd_1"
    end

    test "an unbound binding has no projection" do
      {:ok, b} = Binding.new(resp())
      assert_raise FunctionClauseError, fn -> call_unbound(:model_config, b) end
    end
  end

  describe "plane/1" do
    test "names the resolved plane of a bound binding" do
      assert Binding.plane(bound()) == :control_plane

      for wire <- Target.wires() do
        assert Binding.plane(bound([data_plane: @urls], %{data_plane: wire})) ==
                 {:data_plane, wire}
      end
    end

    test "an unbound binding has no plane yet" do
      {:ok, b} = Binding.new(resp(), data_plane: %{chat_completions: "https://gw.example/v1"})
      assert_raise FunctionClauseError, fn -> call_unbound(:plane, b) end
    end
  end

  describe "guard/2" do
    setup do
      previous = Application.fetch_env(:mimir, :pricing)

      Application.put_env(:mimir, :pricing, %{
        "anthropic:claude-sonnet-4-6" => %{input: 3_000_000, output: 15_000_000}
      })

      on_exit(fn ->
        case previous do
          {:ok, pricing} -> Application.put_env(:mimir, :pricing, pricing)
          :error -> Application.delete_env(:mimir, :pricing)
        end
      end)
    end

    test "prices the routed model against the grant budget" do
      guard = Binding.guard(bound([], %{configured_model: "other"}))

      # 1,000 input tokens at 3,000,000 µ$/M = 3,000 µ$, under the 50,000 µ$ grant.
      assert guard.(%{usage: %{input_tokens: 1_000, output_tokens: 0}, turns: 1}) == :cont

      # 20,000 input tokens = 60,000 µ$, over it.
      assert {:halt, {:budget_exceeded, %{budget_microdollars: 50_000}}} =
               guard.(%{usage: %{input_tokens: 20_000, output_tokens: 0}, turns: 1})
    end

    test "passes caps through" do
      assert {:halt, {:max_turns, _}} =
               Binding.guard(bound(), max_turns: 2).(%{usage: %{}, turns: 2})
    end

    test "an unbound binding has no guard yet" do
      {:ok, b} = Binding.new(resp())
      assert_raise FunctionClauseError, fn -> call_unbound(:guard, b) end
    end
  end
end
