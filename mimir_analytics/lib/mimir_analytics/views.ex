defmodule MimirAnalytics.Views do
  @moduledoc "Re-appliable analytical views over the run-record tables."

  @spec apply(reference()) :: :ok
  def apply(conn) do
    :mimir_analytics
    |> :code.priv_dir()
    |> Path.join("views.sql")
    |> File.read!()
    |> String.split(";", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(fn stmt -> {:ok, _} = Duckdbex.query(conn, stmt) end)

    :ok
  end
end
