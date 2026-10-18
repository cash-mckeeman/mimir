defmodule MimirOrchestration.AgentRunner.RMARunTest do
  use ExUnit.Case, async: true
  @moduletag :rma
  alias MimirOrchestration.AgentRunner.RMA
  alias MimirOrchestration.AgentRunner.RMA.{Reference, Run}
  alias MimirOrchestration.{Compiler, Exec, NodeResult, Policy}
  alias MimirOrchestration.Test.RMARunProvider, as: Provider

  defmodule Tools do
    def handle_tool_call(_, _, _), do: {:ok, "continue"}
  end

  defmodule Router do
    @behaviour Mimir.RouterClient
    @impl true
    def route(_, _),
      do:
        Mimir.RouteResponse.new(%{
          "verdict" => "placement",
          "decision_id" => "decision-test",
          "placement" => %{"model" => "scripted:model", "runtime" => "local"},
          "grant" => %{"key" => "vk-test-binding"}
        })
  end

  test "a later Session failure retains the completed turn only for its run" do
    outcome = Run.capture(Provider, session_opts(steps: [:checkpoint, :fail]))
    assert outcome.return == {:error, :later_failure}
    assert outcome.authority == :partial_result
    result = outcome.session_result
    assert result.session_id == "shared-session-id"
    assert result.terminal == :terminated
    assert result.turns == 1
    assert result.usage.input_tokens == 12
    assert result.usage.output_tokens == 4
    assert result.usage.cache_read_input_tokens == 3
    assert result.usage.cache_creation_input_tokens == 2
    assert result.usage.input_token_basis == :inclusive
    assert result.usage.complete? == true
    assert result.usage.raw == [%{"source" => "scripted"}]

    assert {:error, :later_failure} =
             RMA.run(reference(steps: [:checkpoint, :fail]), "q", handler: Tools)
  end

  test "success and its notification are counted once and leave no result in the caller mailbox" do
    outcome = Run.capture(Provider, session_opts())
    assert {:ok, result} = outcome.return
    assert outcome.authority == :session_result
    assert outcome.session_result == result
    assert result.usage.input_tokens == 12
    assert result.usage.raw == [%{"source" => "scripted"}]
    assert result.in_flight == :none
    refute_received {:managed_agents_session, _}
  end

  test "normal completion stops its per-call supervisor" do
    assert {:ok, _} = Run.capture(Provider, session_opts(report_to: self(), tag: :normal)).return
    assert_received {:collector, :normal, collector}
    assert_down(monitors([collector]))
  end

  test "stale outer notifications are neither consumed nor attributed" do
    {:ok, stale} = Run.capture(Provider, session_opts(count: 777)).return
    assert stale.session_id == "shared-session-id"
    assert stale.usage.input_tokens == 777
    send(self(), {:managed_agents_session, stale})
    outcome = Run.capture(Provider, session_opts(open_failure: true))
    assert outcome.return == {:error, :open_failure}
    assert outcome.authority == :unknown
    assert outcome.session_result == nil
    assert_received {:managed_agents_session, ^stale}
  end

  test "sequential runs sharing a remote session ID do not reuse previous usage" do
    first = Run.capture(Provider, session_opts(steps: [:checkpoint, :fail]))
    second = Run.capture(Provider, session_opts(steps: [:fail]))
    assert first.session_result.session_id == second.session_result.session_id
    assert first.session_result.usage.input_tokens == 12
    assert second.session_result.usage.input_tokens == 0
    assert second.session_result.turns == 0
    assert second.return == {:error, :later_failure}
  end

  test "concurrent runs sharing a remote session ID retain independent facts" do
    tasks =
      for count <- [12, 90],
          do:
            Task.async(fn ->
              Run.capture(Provider, session_opts(steps: [:checkpoint, :fail], count: count))
            end)

    [first, second] = Enum.map(tasks, &Task.await/1)
    assert first.session_result.session_id == second.session_result.session_id
    assert first.session_result.usage.input_tokens == 12
    assert second.session_result.usage.input_tokens == 90
    assert first.return == {:error, :later_failure}
    assert second.return == {:error, :later_failure}
  end

  test "successful projection keeps literal counts and coverage" do
    assert {:ok, %NodeResult{} = result} = RMA.run(reference(), "q", handler: Tools)

    assert result.usage == %{
             "input_tokens" => 12,
             "output_tokens" => 4,
             "cache_read_input_tokens" => 3,
             "cache_creation_input_tokens" => 2,
             "input_token_basis" => "inclusive",
             "complete?" => true
           }

    assert result.raw.usage.raw == [%{"source" => "scripted"}]
    assert result.raw.in_flight == :none
  end

  test "missing cache measurements stay missing while measured zero stays zero" do
    assert {:ok, missing} = RMA.run(reference(coverage: :missing), "q", handler: Tools)

    assert missing.usage == %{
             "input_tokens" => 12,
             "output_tokens" => 4,
             "cache_read_input_tokens" => nil,
             "cache_creation_input_tokens" => nil,
             "input_token_basis" => "unknown",
             "complete?" => false
           }

    assert {:ok, zero} = RMA.run(reference(coverage: :zero), "q", handler: Tools)

    assert zero.usage == %{
             "input_tokens" => 12,
             "output_tokens" => 4,
             "cache_read_input_tokens" => 0,
             "cache_creation_input_tokens" => 0,
             "input_token_basis" => "inclusive",
             "complete?" => true
           }
  end

  test "a provider crash remains an error without killing the caller" do
    outcome = Run.capture(Provider, session_opts(steps: [:crash]))

    assert {:error, {:provider_error, %RuntimeError{message: "scripted provider crash"}}} =
             outcome.return

    assert outcome.authority == :partial_result
  end

  test "worker death returns a local failure and reaps its Session and provider work" do
    name = self_name()

    capture =
      Task.async(fn ->
        Run.capture(
          Provider,
          session_opts(report_to: name, tag: :worker, steps: [:checkpoint, :block])
        )
      end)

    assert_receive {:opened, :worker, session, worker, consumer}, 1_000
    assert_receive {:blocked, :worker, poll}, 1_000
    monitors = monitors([session, consumer, poll])
    Process.exit(worker, :kill)
    outcome = Task.await(capture)
    assert outcome.return == {:error, {:run_worker_exit, :killed}}
    assert outcome.authority == :unknown
    assert outcome.session_result == nil
    assert_down(monitors)
  end

  @tag capture_log: true
  test "owner death reaps the collector, Session and provider tasks" do
    name = self_name()
    supervisor = start_supervised!(Task.Supervisor)

    owner =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Run.capture(
          Provider,
          session_opts(report_to: name, tag: :owner, steps: [:checkpoint, :block])
        )
      end)

    assert_receive {:opened, :owner, session, worker, consumer}, 1_000
    assert_receive {:blocked, :owner, poll}, 1_000
    {:links, [collector]} = Process.info(worker, :links)
    monitors = monitors([collector, session, worker, consumer, poll])
    Task.shutdown(owner, :brutal_kill)
    assert_down(monitors)
  end

  @tag capture_log: true
  test "the real Executor step timeout reaps the per-run owner and Session work" do
    name = self_name()
    compiled = compiled(reference(report_to: name, tag: :executor, steps: [:checkpoint, :block]))

    task =
      Task.async(fn ->
        Exec.run(compiled, %{},
          router: {Router, []},
          agent_runner_opts: [handler: Tools],
          step_timeout: 1_000
        )
      end)

    assert_receive {:opened, :executor, session, worker, consumer}, 1_000
    assert_receive {:blocked, :executor, poll}, 1_000
    {:links, [collector]} = Process.info(worker, :links)
    monitors = monitors([collector, session, worker, consumer, poll])
    assert Task.await(task) == {:error, {:step_crashed, "ask", :timeout}}
    assert_down(monitors)
  end

  defp session_opts(extra \\ []), do: Keyword.merge([handler: Tools, prompt: "q"], extra)

  defp reference(extra \\ []) do
    {:ok, ref} =
      Reference.new(provider: Provider, runtime: "local", resource: {:handle, Map.new(extra)})

    ref
  end

  defp self_name do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} when name != [] ->
        name

      _ ->
        name = :"rma_run_#{System.unique_integer([:positive])}"
        Process.register(self(), name)
        name
    end
  end

  defp monitors(pids), do: Enum.map(pids, &{&1, Process.monitor(&1)})

  defp assert_down(monitors) do
    for {pid, ref} <- monitors do
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
      refute Process.alive?(pid)
    end
  end

  defp compiled(reference) do
    spec = %{
      "name" => "owner",
      "version" => 1,
      "params" => [],
      "steps" => [
        %{
          "id" => "ask",
          "kind" => "agent",
          "agent" => "assistant",
          "input" => "q",
          "descriptor" => %{"budget_ceiling_microdollars" => 1},
          "depends_on" => []
        }
      ]
    }

    {:ok, compiled} =
      Compiler.compile(spec, %Policy{
        agent_registry: %{"assistant" => reference},
        budget_ceiling_microdollars: 1
      })

    compiled
  end
end
