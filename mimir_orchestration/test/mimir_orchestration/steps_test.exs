defmodule MimirOrchestration.StepsTest do
  use ExUnit.Case, async: true
  alias MimirOrchestration.Steps.{LlmStep, ToolStep}

  test "ToolStep executes a fun/1 callable" do
    assert {:ok, %{"echoed" => "hi"}} =
             ToolStep.run(fn %{"text" => t} -> {:ok, %{"echoed" => t}} end, %{"text" => "hi"}, [])
  end

  test "ToolStep executes an {m, f} callable and surfaces errors" do
    defmodule T do
      def boom(_), do: {:error, "nope"}
    end

    assert {:error, "nope"} = ToolStep.run({T, :boom}, %{}, [])
  end

  test "ToolStep wraps a raised callable as {:error, _}" do
    assert {:error, {:tool_crashed, %RuntimeError{}}} =
             ToolStep.run(fn _ -> raise "kaput" end, %{}, [])
  end

  test "ToolStep rejects non-callables" do
    assert {:error, {:not_a_callable, "nope"}} = ToolStep.run("nope", %{}, [])
  end

  test "LlmStep makes exactly one chat call with the routed model" do
    owner = self()

    chat_fun = fn model, prompt, opts ->
      send(owner, {:chat, model, prompt, opts})
      {:ok, "TITLE"}
    end

    assert {:ok, "TITLE"} =
             LlmStep.run("one-line title", model: %{"model" => "fleet-fast"}, chat_fun: chat_fun)

    assert_receive {:chat, %{"model" => "fleet-fast"}, "one-line title", _}
    refute_receive {:chat, _, _, _}, 10
  end

  test "LlmStep without chat_fun and without req_llm raises actionably" do
    unless Code.ensure_loaded?(ReqLLM) do
      assert_raise RuntimeError, ~r/req_llm/, fn -> LlmStep.run("x", model: %{}) end
    end
  end
end
