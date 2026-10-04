defmodule MimirWorkflows.ResultTest do
  use ExUnit.Case, async: true
  alias MimirWorkflows.Result

  test "folds usage across steps, tolerating absent and partial usage maps" do
    results = %{
      "a" => %{"usage" => %{"input_tokens" => 100, "output_tokens" => 20, "calls" => 1}},
      "b" => %{"usage" => %{"input_tokens" => 50}},
      "c" => %{"no_usage_here" => true}
    }

    assert Result.usage(results) == %{"input_tokens" => 150, "output_tokens" => 20, "calls" => 1}
  end

  test "empty results fold to zeros" do
    assert Result.usage(%{}) == %{"input_tokens" => 0, "output_tokens" => 0, "calls" => 0}
  end
end
