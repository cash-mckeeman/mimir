defmodule Mix.Tasks.MimirAnalytics.Setup do
  @shortdoc "One-time provisioning: install the DuckDB extensions the schema loads"
  @moduledoc """
  Downloads the `json` and `core_functions` DuckDB extensions into the local
  extension directory (network). Run once per machine / CI runner; after
  that, `Schema.apply/1` only LOADs from disk and tests stay offline.
  """
  use Mix.Task

  @impl true
  def run(_argv) do
    {:ok, db} = Duckdbex.open(":memory:")
    {:ok, conn} = Duckdbex.connection(db)

    for ext <- ~w(json core_functions) do
      {:ok, _} = Duckdbex.query(conn, "INSTALL #{ext}")
      Mix.shell().info("installed #{ext}")
    end
  end
end
