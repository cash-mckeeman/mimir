defmodule MimirAnalytics.Store.DB do
  @moduledoc "Leased connection commands for accounting transactions. SQL rows and parameters are boundary values."
  alias MimirAnalytics.Store
  @type context :: pid() | nil
  @type command :: :begin | :commit | :rollback | {:query, String.t(), list()}
  @type failure :: :conflict | :constraint | :unavailable
  @callback lease(Store.t(), context()) :: {:ok, Store.t()} | {:error, :unavailable}
  @callback release(Store.t(), context()) :: :ok
  @callback command(Store.t(), command(), context()) :: {:ok, [[term()]]} | {:error, failure()}
end
