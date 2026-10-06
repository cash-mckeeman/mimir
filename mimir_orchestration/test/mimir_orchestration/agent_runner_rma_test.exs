defmodule MimirOrchestration.AgentRunner.RMATest do
  use ExUnit.Case, async: true
  @moduletag :rma
  alias MimirOrchestration.{AgentRunner, Compiler, Exec, NodeResult, Policy}

  if Code.ensure_loaded?(ReqManagedAgents.Provider) do
    defmodule ScriptedLocal do
      @moduledoc false
      # The Local provider with a scripted chat: as a module it is plain data, so it
      # can sit in an agent reference that crosses the executor seam, where a
      # chat_fun closure is refused. The first call asks for the "lookup" tool; the
      # second answers with the tool's result.
      @behaviour ReqManagedAgents.Provider
      alias ReqManagedAgents.Providers.Local

      @impl true
      def open(opts, subscriber),
        do: Local.open(Keyword.put(opts, :chat_fun, &__MODULE__.chat/1), subscriber)

      def chat(%{messages: messages}) do
        message =
          case Enum.find(messages, &(&1["role"] == "tool")) do
            nil ->
              %{
                "role" => "assistant",
                "content" => nil,
                "tool_calls" => [
                  %{
                    "id" => "call-1",
                    "type" => "function",
                    "function" => %{"name" => "lookup", "arguments" => "{}"}
                  }
                ]
              }

            %{"content" => found} ->
              %{"role" => "assistant", "content" => "answer: " <> found}
          end

        reason = if message["tool_calls"], do: "tool_calls", else: "stop"
        {:ok, %{"choices" => [%{"message" => message, "finish_reason" => reason}]}}
      end

      @impl true
      defdelegate mode(), to: Local
      @impl true
      defdelegate provision(spec, opts), to: Local
      @impl true
      defdelegate teardown(handle, opts), to: Local
      @impl true
      defdelegate session_id(conn), to: Local
      @impl true
      defdelegate ref(conn), to: Local
      @impl true
      defdelegate consumer(conn), to: Local
      @impl true
      defdelegate resumed?(conn), to: Local
      @impl true
      defdelegate transcript(conn), to: Local
      @impl true
      defdelegate kickoff_input(opts), to: Local
      @impl true
      defdelegate user_input(text), to: Local
      @impl true
      defdelegate resume_input(tool_uses, results), to: Local
      @impl true
      defdelegate poll_turn(conn, input), to: Local
      @impl true
      defdelegate normalize(events), to: Local
      @impl true
      defdelegate text_delta(event), to: Local
    end
  end

  defmodule LookupHandler do
    @moduledoc false
    def handle_tool_call("lookup", _input, _ctx), do: {:ok, "42"}
  end

  defmodule Router do
    @moduledoc false
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

  # The session seam is injectable so tests never touch RMA's real providers:
  # session_fun.(provider, handle, opts) stands in for Session.run/2 with the
  # handle already splatted (the RMA handle contract).
  test "provisions-if-spec, threads guard/model/metadata, projects the result" do
    owner = self()

    provision_fun = fn :prov, {:spec, s} ->
      send(owner, {:provisioned, s})
      {:ok, {:handle, s}}
    end

    session_fun = fn :prov, {:handle, "da"}, opts ->
      send(owner, {:session_opts, opts})

      {:ok,
       %{
         terminal: :end_turn,
         stop_reason: :end_turn,
         text: "42",
         usage: %{input_tokens: 3, output_tokens: 5}
       }}
    end

    guard = fn _ -> :cont end

    assert {:ok, %NodeResult{text: "42", stop_reason: "end_turn", terminal: "end_turn"} = result} =
             AgentRunner.RMA.run({:prov, {:spec, "da"}}, "meaning?",
               model: %{"model" => "m"},
               turn_guard: guard,
               metadata: %{workflow_id: "wf", step_id: "s"},
               provision_fun: provision_fun,
               session_fun: session_fun
             )

    # raw keeps the whole unprojected session result — no information lost
    # by typing only the common fields.
    assert result.raw == %{
             terminal: :end_turn,
             stop_reason: :end_turn,
             text: "42",
             usage: %{input_tokens: 3, output_tokens: 5}
           }

    assert_receive {:provisioned, "da"}
    assert_receive {:session_opts, opts}
    assert opts[:turn_guard] == guard
    assert opts[:telemetry_metadata] == %{workflow_id: "wf", step_id: "s"}
    assert opts[:model_config] == %{"model" => "m"}
    assert opts[:prompt] == "meaning?"
  end

  test "handle refs skip provisioning" do
    session_fun = fn :prov, {:handle, "h"}, _ ->
      {:ok, %{terminal: :end_turn, stop_reason: :end_turn, text: "ok", usage: %{}}}
    end

    assert {:ok, %NodeResult{text: "ok"}} =
             AgentRunner.RMA.run({:prov, {:handle, "h"}}, "q", session_fun: session_fun)
  end

  test "raw-native stop_reason maps pass through JSON-encodable, never to_string'd" do
    session_fun = fn _, _, _ ->
      {:ok,
       %{
         terminal: :end_turn,
         stop_reason: %{"type" => "end_turn"},
         text: "ok",
         usage: %{input_tokens: 1, output_tokens: 2}
       }}
    end

    assert {:ok, %NodeResult{stop_reason: %{"type" => "end_turn"}, usage: usage}} =
             AgentRunner.RMA.run({:prov, {:handle, "h"}}, "q", session_fun: session_fun)

    assert usage == %{"input_tokens" => 1, "output_tokens" => 2}
  end

  test "session errors pass through" do
    session_fun = fn _, _, _ -> {:error, :kaput} end

    assert {:error, :kaput} =
             AgentRunner.RMA.run({:prov, {:handle, "h"}}, "q", session_fun: session_fun)
  end

  # No injected funs: the real provision/2 and Session.run/2 run the in-process Local
  # provider, whose handle is the map of session options (splat_handle/2 merges it).
  # The scripted chat_fun is the only stand-in, so no network is touched.
  test "the default adapter drives ReqManagedAgents through the Local provider" do
    provider = ReqManagedAgents.Providers.Local

    owner = self()

    chat_fun = fn %{messages: messages} ->
      send(owner, {:chat, messages})

      {:ok,
       %{
         "choices" => [
           %{
             "message" => %{"role" => "assistant", "content" => "pong"},
             "finish_reason" => "stop"
           }
         ],
         "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 1}
       }}
    end

    handler = fn _id, _name, _input -> {:ok, "unused"} end
    spec = %{spec: %{system_prompt: "be brief"}, chat_fun: chat_fun, max_turns: 2}

    for ref <- [{:spec, spec}, {:handle, spec}] do
      assert {:ok, %NodeResult{text: "pong", usage: usage, raw: raw}} =
               AgentRunner.RMA.run({provider, ref}, "ping", handler: handler)

      assert usage == %{"input_tokens" => 3, "output_tokens" => 1}
      assert raw.text == "pong"

      assert_receive {:chat, [%{"role" => "system", "content" => "be brief"} | rest]}
      assert %{"role" => "user", "content" => "ping"} in rest
    end

    # Local's provision/2 is identity, so the run above cannot tell a real
    # ReqManagedAgents.provision/2 call from a bypass. This reads RMA's default
    # provision cache (a named public ETS table, an RMA internal) for the spec the
    # {:spec, _} ref provisioned; if RMA renames that table, update it here.
    assert [_ | _] = :ets.match_object(:req_managed_agents_provisions, {:_, spec})
  end

  test "through Exec, the default adapter runs a session with a module handler" do
    spec = %{
      spec: %{
        system_prompt: "be brief",
        tools: [%{"name" => "lookup", "description" => "look it up", "input_schema" => %{}}]
      },
      max_turns: 3
    }

    plan = %{
      "name" => "ask",
      "version" => 1,
      "params" => ["q"],
      "steps" => [
        %{
          "id" => "ask",
          "kind" => "agent",
          "agent" => "asker",
          "input" => "{{params.q}}",
          "descriptor" => %{"task_class" => "t", "budget_ceiling_microdollars" => 1},
          "depends_on" => []
        }
      ]
    }

    policy = %Policy{
      agent_registry: %{"asker" => {__MODULE__.ScriptedLocal, {:handle, spec}}},
      budget_ceiling_microdollars: 10
    }

    {:ok, compiled} = Compiler.compile(plan, policy)

    assert {:ok, %{results: %{"ask" => %NodeResult{text: "answer: 42"}}}} =
             Exec.run(compiled, %{"q" => "what is it?"},
               router: {Router, []},
               agent_runner_opts: [handler: LookupHandler]
             )
  end
end
