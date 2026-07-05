defmodule Mimir.SmokeTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Guards the end-to-end smoke under `mix test` / CI so the composed public
  surface is verified on every build, not only on explicit smoke runs.
  """

  alias Mix.Tasks.Mimir.Smoke

  test "run_smoke/0 returns {:ok, results} with every stage passing" do
    assert {:ok, results} = Smoke.run_smoke()

    failures = Enum.filter(results, fn {_, status, _} -> status == :fail end)

    assert failures == [],
           "Failing stages:\n" <>
             Enum.map_join(failures, "\n", fn {name, _, detail} ->
               "  [FAIL] #{name} — #{detail}"
             end)

    assert length(results) >= 9
  end
end
