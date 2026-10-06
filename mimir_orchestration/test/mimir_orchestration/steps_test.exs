defmodule MimirOrchestration.StepsTest do
  use ExUnit.Case, async: true
  alias MimirOrchestration.Steps.{LlmStep, ToolStep}

  def echo(%{"text" => t}, tag), do: {:ok, %{tag => t}}
  def boom(_input), do: {:error, "nope"}
  def crash(_input), do: raise("kaput")

  def chat(%{model: model, prompt: prompt}, to) do
    send(to, {:chat, model, prompt})
    {:ok, "TITLE"}
  end

  test "ToolStep invokes an MFA callable with the input first, then extra_args" do
    assert {:ok, %{"echoed" => "hi"}} =
             ToolStep.run({__MODULE__, :echo, ["echoed"]}, %{"text" => "hi"}, [])
  end

  test "ToolStep surfaces a callable's errors" do
    assert {:error, "nope"} = ToolStep.run({__MODULE__, :boom, []}, %{}, [])
  end

  test "ToolStep wraps a raised callable as {:error, _}" do
    assert {:error, {:tool_crashed, %RuntimeError{}}} =
             ToolStep.run({__MODULE__, :crash, []}, %{}, [])
  end

  test "ToolStep rejects anything but an MFA, closures and {module, function} included" do
    for callable <- ["nope", fn _ -> :ok end, {__MODULE__, :boom}] do
      assert {:error, {:not_a_callable, ^callable}} = ToolStep.run(callable, %{}, [])
    end
  end

  test "LlmStep makes exactly one chat call with the routed model" do
    name = :"steps_test_#{System.unique_integer([:positive])}"
    Process.register(self(), name)

    assert {:ok, "TITLE"} =
             LlmStep.run("one-line title",
               model: %{"model" => "fleet-fast"},
               chat: {__MODULE__, :chat, [name]}
             )

    assert_receive {:chat, %{"model" => "fleet-fast"}, "one-line title"}
    refute_receive {:chat, _, _}, 10
  end

  @tag :without_req_llm
  test "LlmStep without :chat and without req_llm names the missing dependency" do
    refute Code.ensure_loaded?(ReqLLM),
           "req_llm is loaded: run this under MIMIR_WITHOUT_REQ_LLM=1"

    assert {:error, {:missing_dependency, :req_llm}} = LlmStep.run("x", model: %{})
  end
end
