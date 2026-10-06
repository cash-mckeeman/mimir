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

  test "non-map results contribute nothing, like maps without usage" do
    results = %{
      "a" => %{"usage" => %{"input_tokens" => 5, "output_tokens" => 2, "calls" => 1}},
      "b" => %{"no_usage" => true},
      "c" => {:did, 1}
    }

    assert Result.usage(results) == %{"input_tokens" => 5, "output_tokens" => 2, "calls" => 1}
  end

  test "results that are all non-maps fold to zero" do
    assert Result.usage(%{"a" => {:did, 1}, "b" => "text"}) ==
             %{"input_tokens" => 0, "output_tokens" => 0, "calls" => 0}
  end
end
