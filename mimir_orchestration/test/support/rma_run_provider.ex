if Code.ensure_loaded?(ReqManagedAgents.Provider) do
  defmodule MimirOrchestration.Test.RMARunProvider do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    alias ReqManagedAgents.{ToolUse, TurnResult, Usage}

    @impl true
    def mode, do: :request_response
    @impl true
    def provision(spec, _opts), do: {:ok, spec}
    @impl true
    def open(opts, _subscriber) do
      if opts[:open_failure] do
        {:error, :open_failure}
      else
        {:ok, consumer} = Agent.start_link(fn -> Keyword.get(opts, :steps, [:success]) end)

        conn = %{
          consumer: consumer,
          owner: opts[:report_to],
          tag: opts[:tag],
          count: Keyword.get(opts, :count, 12),
          coverage: opts[:coverage]
        }

        {:links, [collector]} = Process.info(opts[:caller], :links)
        report(conn, {:collector, conn.tag, collector})
        report(conn, {:opened, conn.tag, self(), opts[:caller], consumer})
        {:ok, conn}
      end
    end

    @impl true
    def session_id(_conn), do: "shared-session-id"
    @impl true
    def ref(_conn), do: nil
    @impl true
    def consumer(conn), do: conn.consumer
    @impl true
    def resumed?(_conn), do: false
    @impl true
    def supports_runtime_model?, do: true
    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(input), do: input
    @impl true
    def resume_input(_tools, _results), do: :resume
    @impl true
    def poll_turn(conn, _input) do
      step = Agent.get_and_update(conn.consumer, fn [step | rest] -> {step, rest} end)

      case step do
        :fail ->
          {:error, :later_failure}

        :crash ->
          raise "scripted provider crash"

        :block ->
          report(conn, {:blocked, conn.tag, self()})
          receive do: (:release -> turn(conn, :success))

        terminal ->
          turn(conn, terminal)
      end
    end

    defp turn(conn, terminal),
      do:
        {:ok, [%{"terminal" => terminal, "count" => conn.count, "coverage" => conn.coverage}],
         conn}

    @impl true
    def normalize([event] = events) do
      terminal = if event["terminal"] == :checkpoint, do: :requires_action, else: :end_turn

      attrs = %{
        input_tokens: event["count"],
        output_tokens: 4,
        cache_read_input_tokens: 3,
        cache_creation_input_tokens: 2,
        input_token_basis: :inclusive,
        raw: [%{"source" => "scripted"}]
      }

      attrs =
        case event["coverage"] do
          :missing ->
            %{
              attrs
              | cache_read_input_tokens: nil,
                cache_creation_input_tokens: nil,
                input_token_basis: :unknown
            }

          :zero ->
            %{attrs | cache_read_input_tokens: 0, cache_creation_input_tokens: 0}

          _ ->
            attrs
        end

      {:ok, usage} = Usage.new(attrs)

      tools =
        if terminal == :requires_action,
          do: [%ToolUse{id: "tool-1", name: "continue", input: %{}}],
          else: []

      %TurnResult{
        terminal: terminal,
        stop_reason: "stop",
        text: "ok",
        usage: usage,
        events: events,
        custom_tool_uses: tools
      }
    end

    defp report(%{owner: nil}, _message), do: :ok
    defp report(conn, message), do: send(conn.owner, message)
  end
end
