defmodule MimirOrchestration.AgentRunner.RMATest do
  use ExUnit.Case, async: true
  alias MimirOrchestration.{AgentRunner, NodeResult}

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
end
