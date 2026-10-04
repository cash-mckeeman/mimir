defmodule Mimir.PlacementTest do
  use ExUnit.Case, async: true

  test "builds with enforced model and optional lane/runtime" do
    p = %Mimir.Placement{
      lane: "anthropic",
      model: "anthropic:claude-sonnet-4-6",
      runtime: "managed"
    }

    assert p.model == "anthropic:claude-sonnet-4-6"
    assert p.lane == "anthropic"
    assert p.runtime == "managed"
  end

  test "model is enforced" do
    assert_raise ArgumentError, fn -> struct!(Mimir.Placement, %{lane: "x"}) end
  end
end
