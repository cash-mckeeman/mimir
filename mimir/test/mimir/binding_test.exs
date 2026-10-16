defmodule Mimir.BindingTest do
  use ExUnit.Case, async: false

  alias Mimir.{Binding, RouteResponse}

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
end
