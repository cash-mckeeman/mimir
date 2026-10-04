defmodule MimirFamily.MixProject do
  @moduledoc false
  use Mix.Project

  # Publish order. A package is published only while it is listed here.
  @publish ~w(mimir)

  # Every sibling, in dependency order. The root aliases run in each one.
  @siblings ~w(mimir)

  def project do
    [app: :mimir_family, version: "0.0.0", elixir: "~> 1.18", deps: [], aliases: aliases()]
  end

  defp aliases do
    [
      publish_order: fn _args -> Enum.each(@publish, &IO.puts/1) end,
      "deps.get": &each_sibling(["deps.get" | &1]),
      format: &each_sibling(["format" | &1]),
      test: &each_sibling(["test" | &1])
    ]
  end

  defp each_sibling(argv), do: Enum.each(@siblings, &run_in!(&1, argv))

  defp run_in!(dir, argv) do
    Mix.shell().info("==> #{dir}: mix #{Enum.join(argv, " ")}")

    case System.cmd("mix", argv, cd: dir, into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("mix #{Enum.join(argv, " ")} failed in #{dir}/ (exit #{status})")
    end
  end
end
