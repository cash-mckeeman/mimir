defmodule MimirAnalytics.Capture do
  @moduledoc """
  Session-finish capture: writes `{"meta": ..., "result": ...}` as a one-line
  JSONL file into a sessions spool directory. Explicit call from the
  step-runner / eval harness rather than a telemetry attachment. Takes plain maps; structs must be Jason-encoded to maps by the
  caller.

  Each call writes its own file and publishes it by rename: the line is
  written to a dot-prefixed temporary sibling, which is then renamed to
  `session-<UTC date>-<random>.jsonl`. A visible file is therefore complete
  and never changes afterwards, which is the spool's write protocol (see
  `mix mimir_analytics.ingest`).
  """

  @spec write(map(), map(), Path.t()) :: {:ok, Path.t()}
  def write(result, meta, dir) when is_map(result) and is_map(meta) do
    File.mkdir_p!(dir)
    name = "session-#{Date.to_iso8601(Date.utc_today())}-#{random_suffix()}.jsonl"
    path = Path.join(dir, name)
    tmp = Path.join(dir, "." <> name <> ".tmp")
    File.write!(tmp, Jason.encode!(%{"meta" => meta, "result" => result}) <> "\n")
    File.rename!(tmp, path)
    {:ok, path}
  end

  defp random_suffix, do: 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
