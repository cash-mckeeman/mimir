if Code.ensure_loaded?(Jido.Action) do
  defmodule MimirOrchestration.AgentTool do
    @moduledoc """
    Wraps an agent reference as a Jido.Action. Requires the optional `jido`
    dependency.

    Context keys `:metadata` and `:runtime` pass correlation metadata and override
    the tool's runtime. `:agent_runner` selects the implementation; `:owner` is
    forwarded to it. Returned errors are converted to strings.
    """

    defmacro __using__(opts) do
      agent_ref = Keyword.fetch!(opts, :agent_ref)
      name = Keyword.fetch!(opts, :name)
      description = Keyword.fetch!(opts, :description)
      default_runtime = Keyword.get(opts, :runtime)

      quote do
        use Jido.Action,
          name: unquote(name),
          description: unquote(description),
          schema: [
            input: [type: :string, required: true, doc: "the request to hand to the sub-agent"]
          ]

        @impl true
        def run(%{input: input}, ctx) do
          ctx = ctx || %{}

          opts =
            []
            |> Keyword.put(:runtime, Map.get(ctx, :runtime, unquote(default_runtime)))
            |> Keyword.put(:metadata, Map.get(ctx, :metadata))
            |> Keyword.put(
              :agent_runner,
              Map.get(ctx, :agent_runner, MimirOrchestration.AgentRunner.RMA)
            )
            |> Keyword.put(:owner, Map.get(ctx, :owner))
            |> Enum.reject(fn {_k, v} -> is_nil(v) end)

          case MimirOrchestration.run_agent(unquote(agent_ref), input, opts) do
            {:ok, projected} -> {:ok, projected}
            {:error, reason} -> {:error, inspect(reason)}
          end
        end
      end
    end
  end
else
  defmodule MimirOrchestration.AgentTool do
    @moduledoc "Requires the optional :jido dep — add {:jido, \"~> 2.2\"} to use AgentTool."
    defmacro __using__(_opts) do
      raise "MimirOrchestration.AgentTool requires the optional :jido dependency"
    end
  end
end
