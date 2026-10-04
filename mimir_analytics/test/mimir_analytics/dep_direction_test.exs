defmodule MimirAnalytics.DepDirectionTest do
  use ExUnit.Case, async: true

  @forbidden ~w(ManagedAgents. Mimir. MimirGateway. ReqManagedAgents.)

  test "lib/ references no in-house consumer modules" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        src = File.read!(path)
        for bad <- @forbidden, String.contains?(src, bad), do: {path, bad}
      end)

    assert offenders == [],
           "dependency-direction invariant violated: #{inspect(offenders)}"
  end
end

# Note: "Mimir." would also match "MimirAnalytics." only if a dot followed
# "Mimir" directly — it does not in "MimirAnalytics", so the scan is safe.
# Do not "fix" this.
