defmodule MimirAnalytics.Ingest.GatewayAccountingBuffer.FileSystem do
  @moduledoc "Filesystem operations for accounting publication; context belongs to the adapter."
  @type context :: pid() | nil
  @type result :: :ok | {:error, File.posix()}
  @callback read(Path.t(), context()) :: {:ok, binary()} | {:error, File.posix()}
  @callback write(Path.t(), binary(), [:binary | :exclusive | :sync], context()) :: result()
  @callback mkdir_p(Path.t(), context()) :: result()
  @callback ln(Path.t(), Path.t(), context()) :: result()
  @callback rm(Path.t(), context()) :: result()
end

defmodule MimirAnalytics.Ingest.GatewayAccountingBuffer do
  @moduledoc "Publishes digest-named accounting pages; publication alone does not acknowledge them."
  alias MimirAnalytics.Accounting.{Error, Page}
  alias MimirAnalytics.Ingest.GatewayAccountingBuffer.FileSystem
  alias MimirAnalytics.Store

  @type options :: [file_system: File | {module(), FileSystem.context()}]
  @doc "The file_system option accepts native File or a scoped FileSystem adapter/context."
  @spec publish(Page.t(), Path.t(), options()) :: {:ok, Page.t(), Path.t()} | {:error, Error.t()}
  def publish(page, dir, opts \\ [])

  def publish(%Page{} = page, dir, opts) when is_binary(dir) do
    file_system = Keyword.get(opts, :file_system, File)
    bytes = Page.to_buffer(page)
    basename = "gateway_accounting-#{Store.digest(bytes)}.jsonl"
    path = Path.join(dir, basename)
    nonce = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    temp = Path.join(dir, ".#{basename}.#{nonce}.tmp")

    with :ok <- file_command(file_system, :mkdir_p, [dir]),
         :ok <- publish_bytes(path, temp, bytes, file_system),
         {:ok, receipt} <- Page.from_buffer(bytes, basename) do
      {:ok, receipt, path}
    else
      _ -> Error.result(:buffer_error)
    end
  end

  def publish(_, _, _), do: Error.result(:buffer_error)

  defp publish_bytes(path, temp, bytes, file_system) do
    case file_command(file_system, :read, [path]) do
      {:ok, ^bytes} ->
        :ok

      {:ok, _} ->
        :collision

      {:error, :enoent} ->
        with :ok <- file_command(file_system, :write, [temp, bytes, [:binary, :exclusive, :sync]]) do
          publish_owned_temp(file_system, temp, path, bytes)
        end

      {:error, _} ->
        :unavailable
    end
  end

  defp publish_owned_temp(file_system, temp, path, bytes) do
    link_destination(file_system, temp, path, bytes)
  after
    file_command(file_system, :rm, [temp])
  end

  defp link_destination(file_system, temp, path, bytes) do
    case file_command(file_system, :ln, [temp, path]) do
      result when result in [:ok, {:error, :eexist}] ->
        case file_command(file_system, :read, [path]) do
          {:ok, ^bytes} -> :ok
          _ -> :collision
        end

      error ->
        error
    end
  end

  defp file_command(File, operation, args), do: apply(File, operation, args)

  defp file_command({module, context}, operation, args),
    do: apply(module, operation, args ++ [context])
end
