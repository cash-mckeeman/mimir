defmodule MimirAnalytics.Ingest.GatewayAccountingBuffer do
  @moduledoc "Publishes digest-named accounting pages; publication alone does not acknowledge them."
  alias MimirAnalytics.Accounting.{Error, Page}
  alias MimirAnalytics.Store

  @spec publish(Page.t(), Path.t()) :: {:ok, Page.t(), Path.t()} | {:error, Error.t()}
  def publish(%Page{} = page, dir) when is_binary(dir) do
    bytes = Page.to_buffer(page)
    basename = "gateway_accounting-#{Store.digest(bytes)}.jsonl"
    path = Path.join(dir, basename)
    temp = Path.join(dir, ".#{basename}.#{System.unique_integer([:positive])}.tmp")

    try do
      with :ok <- File.mkdir_p(dir),
           :ok <- publish_bytes(path, temp, bytes),
           {:ok, receipt} <- Page.from_buffer(bytes, basename) do
        {:ok, receipt, path}
      else
        _ -> Error.result(:buffer_error)
      end
    after
      File.rm(temp)
    end
  end

  def publish(_, _), do: Error.result(:buffer_error)

  defp publish_bytes(path, temp, bytes) do
    case File.read(path) do
      {:ok, ^bytes} ->
        :ok

      {:ok, _} ->
        :collision

      {:error, :enoent} ->
        with :ok <- File.write(temp, bytes, [:binary, :exclusive, :sync]),
             :ok <- File.rename(temp, path),
             {:ok, ^bytes} <- File.read(path) do
          :ok
        end

      {:error, _} ->
        :unavailable
    end
  end
end
