defmodule Mimir.Event.OTelTest do
  use ExUnit.Case, async: true

  alias Mimir.Event
  alias Mimir.Event.OTel

  @fixtures_dir Path.expand("../../support/fixtures/gen_ai_compat", __DIR__)

  defp fixture!(name) do
    @fixtures_dir
    |> Path.join("#{name}.json")
    |> File.read!()
    |> Jason.decode!()
  end

  describe "llm domain — byte-compat with the retired Mimir.TurnEvents.GenAI" do
    test "usage renders the frozen gen_ai.usage.* shape" do
      {:ok, ev} =
        Event.llm(:usage, seq: 1, ts: 2, usage: %{input_tokens: 10, output_tokens: 2})

      assert OTel.render(ev).attributes == fixture!("usage_attrs")
    end

    test "tool_call renders the frozen gen_ai.tool.* shape" do
      {:ok, ev} = Event.llm(:tool_call, seq: 1, ts: 2, tool: %{id: "t1", name: "echo"})

      assert OTel.render(ev).attributes == fixture!("tool_use_attrs")
    end

    test "tool_call with a nil tool id renders exactly what the current GenAI.tool_use/1 produces" do
      {:ok, ev} = Event.llm(:tool_call, seq: 1, ts: 2, tool: %{id: nil, name: "echo"})

      assert OTel.render(ev).attributes == fixture!("tool_use_nil_id_attrs")
      assert OTel.render(ev).attributes["gen_ai.tool.call.id"] == nil
    end

    test "reasoning renders the frozen bare milestone shape (no gen_ai. prefix, matching history)" do
      {:ok, ev} = Event.llm(:reasoning, seq: 1, ts: 2, raw: %{"milestone" => "planning"})

      assert OTel.render(ev).attributes == fixture!("reasoning_attrs")
    end

    test "reasoning with no milestone in raw defaults to the empty-string marker" do
      {:ok, ev} = Event.llm(:reasoning, seq: 0, ts: 0, raw: %{})

      assert OTel.render(ev).attributes == %{"milestone" => ""}
    end

    test "llm types with no dedicated historical builder fall back to a stringified raw" do
      {:ok, ev} =
        Event.llm(:request_start, seq: 0, ts: 0, raw: %{"gen_ai.request.model" => "gpt-4o"})

      assert OTel.render(ev).attributes == %{"gen_ai.request.model" => "gpt-4o"}
    end

    test "render/1 type field is the domain string" do
      {:ok, ev} = Event.llm(:usage, seq: 0, ts: 0, usage: %{input_tokens: 1, output_tokens: 1})
      assert OTel.render(ev).type == "llm"
    end
  end

  describe "agent domain — OTel GenAI agent conventions" do
    test "session_reattach renders invoke_agent + the session id attribute" do
      {:ok, ev} = Event.agent(:session_reattach, seq: 2, ts: 3, session_id: "s1")

      attrs = OTel.render(ev).attributes
      assert attrs["gen_ai.operation.name"] == "invoke_agent"
      assert attrs["gen_ai.conversation.id"] == "s1"
      refute Map.has_key?(attrs, "mimir.agent.event")
    end

    test "session_open renders invoke_agent with no mimir.agent.event sub-type" do
      {:ok, ev} = Event.agent(:session_open, seq: 0, ts: 0, session_id: "s2")

      attrs = OTel.render(ev).attributes
      assert attrs["gen_ai.operation.name"] == "invoke_agent"
      refute Map.has_key?(attrs, "mimir.agent.event")
    end

    test "turn/terminal/error events add a mimir.agent.event sub-type attribute" do
      for type <- [:turn_start, :turn_end, :terminal, :error] do
        {:ok, ev} = Event.agent(type, seq: 0, ts: 0, session_id: "s3")
        attrs = OTel.render(ev).attributes

        assert attrs["gen_ai.operation.name"] == "invoke_agent"
        assert attrs["mimir.agent.event"] == Atom.to_string(type)
      end
    end

    test "no session_id present omits the conversation id attribute entirely" do
      {:ok, ev} = Event.agent(:session_open, seq: 0, ts: 0)
      refute Map.has_key?(OTel.render(ev).attributes, "gen_ai.conversation.id")
    end

    test "render/1 type field is the domain string" do
      {:ok, ev} = Event.agent(:session_open, seq: 0, ts: 0)
      assert OTel.render(ev).type == "agent"
    end
  end

  describe "workflow domain — plain mimir.workflow.*, no GenAI pretense" do
    test "step_stop renders mimir.workflow.* attributes and no gen_ai.* key" do
      {:ok, ev} = Event.workflow(:step_stop, seq: 3, ts: 4, workflow_id: "w1", step_id: "st1")

      attrs = OTel.render(ev).attributes
      assert attrs["mimir.workflow.id"] == "w1"
      assert attrs["mimir.workflow.step_id"] == "st1"
      refute Enum.any?(Map.keys(attrs), &String.starts_with?(&1, "gen_ai."))
    end

    test "step_start/step_exception also carry no gen_ai.* key" do
      for type <- [:step_start, :step_exception] do
        {:ok, ev} = Event.workflow(type, seq: 0, ts: 0, workflow_id: "w2", step_id: "st2")
        attrs = OTel.render(ev).attributes
        refute Enum.any?(Map.keys(attrs), &String.starts_with?(&1, "gen_ai."))
      end
    end

    test "render/1 type field is the domain string" do
      {:ok, ev} = Event.workflow(:step_start, seq: 0, ts: 0)
      assert OTel.render(ev).type == "workflow"
    end
  end
end
