defmodule MimirOrchestration.StepsTest do
  use ExUnit.Case, async: true
  alias MimirOrchestration.Steps.{LlmStep, ToolStep}
  alias MimirOrchestration.Test.Registered

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
    name = Registered.self_name()

    assert {:ok, "TITLE"} =
             LlmStep.run("one-line title",
               model: %{"model" => "fleet-fast"},
               chat: {__MODULE__, :chat, [name]}
             )

    assert_receive {:chat, %{"model" => "fleet-fast"}, "one-line title"}
    refute_receive {:chat, _, _}, 10
  end

  test "routed chat-completions selects its declared wire and per-call grant" do
    binding = route_binding(%{chat_completions: "http://127.0.0.1:8080/prefix/v1"})

    assert {:ok, "TITLE"} =
             LlmStep.run("q",
               binding: binding,
               chat: {__MODULE__, :capture_chat, [Registered.self_name()]}
             )

    assert_received {:chat_call,
                     %{
                       model: %{
                         provider: :openai,
                         id: "anthropic:claude-sonnet-4-6",
                         base_url: "http://127.0.0.1:8080/prefix/v1",
                         extra: %{wire: %{protocol: "openai_chat"}}
                       },
                       prompt: "q",
                       opts: [api_key: "vk-test-binding"]
                     }}

    refute_received {:chat_call, _}
  end

  test "control-plane routed model carries no grant credential" do
    assert {:ok, "TITLE"} =
             LlmStep.run("q",
               binding: route_binding(%{}),
               chat: {__MODULE__, :capture_chat, [Registered.self_name()]}
             )

    assert_received {:chat_call, %{model: "anthropic:claude-sonnet-4-6", opts: []}}
  end

  test "incompatible routed model target refuses before chat" do
    for {binding, reason} <- [
          {route_binding(%{managed_agents_api: "http://127.0.0.1:8080"}),
           {:plane, {:no_url_for, :chat_completions}}},
          {route_binding(%{}, "managed"), {:runtime, "managed", "local"}}
        ] do
      assert {:error, {:target_mismatch, ^reason}} =
               LlmStep.run("q",
                 binding: binding,
                 chat: {__MODULE__, :capture_chat, [Registered.self_name()]}
               )
    end

    refute_received {:chat_call, _}
  end

  def capture_chat(call, to) do
    send(to, {:chat_call, call})
    {:ok, "TITLE"}
  end

  defp route_binding(urls, runtime \\ "local") do
    {:ok, response} =
      Mimir.RouteResponse.new(%{
        "verdict" => "placement",
        "decision_id" => "decision-test",
        "placement" => %{"model" => "anthropic:claude-sonnet-4-6", "runtime" => runtime},
        "grant" => %{"key" => "vk-test-binding"}
      })

    {:ok, binding} = Mimir.Binding.new(response, data_plane: urls)
    binding
  end

  @tag :without_req_llm
  test "LlmStep without :chat and without req_llm names the missing dependency" do
    refute Code.ensure_loaded?(ReqLLM),
           "req_llm is loaded: run this under MIMIR_WITHOUT_REQ_LLM=1"

    assert {:error, {:missing_dependency, :req_llm}} = LlmStep.run("x", model: %{})
  end
end
