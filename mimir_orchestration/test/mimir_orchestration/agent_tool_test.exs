defmodule MimirOrchestration.AgentToolTest do
  use ExUnit.Case, async: true
  alias MimirOrchestration.NodeResult

  defmodule EchoRunner do
    @behaviour MimirOrchestration.AgentRunner
    @impl true
    def run(ref, input, opts) do
      send(opts[:owner] || self(), {:ran, ref, input, opts[:metadata], opts[:runtime]})
      {:ok, %NodeResult{text: "42", stop_reason: "end_turn", raw: %{}}}
    end
  end

  test "run_agent/3 delegates to the configured runner" do
    assert {:ok, %NodeResult{text: "42"}} =
             MimirOrchestration.run_agent({:rma, "sub"}, "meaning?",
               agent_runner: EchoRunner,
               metadata: %{workflow_id: "wf-1", step_id: "supervise"}
             )

    assert_receive {:ran, {:rma, "sub"}, "meaning?", %{workflow_id: "wf-1"}, nil}
  end

  if Code.ensure_loaded?(Jido.Action) do
    defmodule AskSub do
      use MimirOrchestration.AgentTool,
        agent_ref: {:rma, "sub"},
        name: "ask_sub",
        description: "delegate a question to the sub agent",
        runtime: :local
    end

    test "emits a Jido.Action with tool metadata" do
      assert AskSub.name() == "ask_sub"
      assert AskSub.description() =~ "delegate"
      assert Keyword.has_key?(AskSub.schema(), :input)
    end

    test "run/2 inherits correlation and runtime from context" do
      ctx = %{
        agent_runner: EchoRunner,
        metadata: %{workflow_id: "wf-1", step_id: "supervise"},
        owner: self()
      }

      assert {:ok, %NodeResult{text: "42", stop_reason: "end_turn"}} =
               AskSub.run(%{input: "meaning?"}, ctx)

      assert_receive {:ran, {:rma, "sub"}, "meaning?", %{workflow_id: "wf-1"}, :local}
    end

    test "context :runtime overrides the tool default" do
      AskSub.run(%{input: "q"}, %{agent_runner: EchoRunner, runtime: :managed, owner: self()})
      assert_receive {:ran, _, _, _, :managed}
    end
  end
end
