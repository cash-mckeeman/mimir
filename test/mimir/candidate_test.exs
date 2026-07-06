defmodule Mimir.CandidateTest do
  use ExUnit.Case, async: true

  test "builds with id and verdict" do
    assert %Mimir.Candidate{id: "claude", verdict: :chosen}.verdict == :chosen
    assert %Mimir.Candidate{id: "c2", verdict: :ranked}.verdict == :ranked

    assert %Mimir.Candidate{id: "c3", verdict: {:excluded, {:cost, 1}}}.verdict ==
             {:excluded, {:cost, 1}}
  end

  test "id and verdict are enforced" do
    assert_raise ArgumentError, fn -> struct!(Mimir.Candidate, %{id: "x"}) end
  end
end
