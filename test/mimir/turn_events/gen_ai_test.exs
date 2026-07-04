defmodule Mimir.TurnEvents.GenAITest do
  use ExUnit.Case, async: true

  alias Mimir.TurnEvents.GenAI

  test "reasoning/1 builds a milestone map" do
    assert GenAI.reasoning(%{milestone: :plan}) == %{"milestone" => "plan"}
    assert GenAI.reasoning(%{}) == %{"milestone" => ""}
  end

  test "tool_use/1 accepts atom or string keys" do
    assert GenAI.tool_use(%{name: "search", id: "t1"}) ==
             %{"gen_ai.tool.name" => "search", "gen_ai.tool.call.id" => "t1"}

    assert GenAI.tool_use(%{"name" => "search", "id" => "t1"}) ==
             %{"gen_ai.tool.name" => "search", "gen_ai.tool.call.id" => "t1"}
  end

  test "usage/2 builds the OTel usage pair" do
    assert GenAI.usage(10, 5) ==
             %{"gen_ai.usage.input_tokens" => 10, "gen_ai.usage.output_tokens" => 5}
  end
end
