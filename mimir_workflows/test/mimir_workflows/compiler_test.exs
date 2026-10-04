defmodule MimirWorkflows.CompilerTest do
  use ExUnit.Case, async: true
  alias MimirWorkflows.{Compiler, Diagnostic, Spec}

  defmodule RejectAllPass do
    @behaviour MimirWorkflows.Compiler.Pass
    @impl true
    def check(%Spec{steps: steps}, tag) do
      Enum.map(
        steps,
        &%Diagnostic{
          pass: :reject_all,
          severity: :error,
          step_id: &1.id,
          message: "denied by #{tag}"
        }
      )
    end
  end

  defmodule WarnPass do
    @behaviour MimirWorkflows.Compiler.Pass
    @impl true
    def check(_spec, _ctx),
      do: [%Diagnostic{pass: :warn, severity: :warning, step_id: nil, message: "advisory"}]
  end

  @valid %{
    "name" => "brief",
    "version" => 1,
    "params" => ["month"],
    "steps" => [
      %{
        "id" => "analyze",
        "kind" => "agent",
        "depends_on" => [],
        "input" => %{"q" => "KPIs for {{params.month}}"}
      },
      %{
        "id" => "narrate",
        "kind" => "agent",
        "depends_on" => ["analyze"],
        "input" => "{{analyze}}"
      }
    ]
  }

  test "valid spec compiles; warnings ride alongside" do
    assert {:ok, %Spec{}, [%Diagnostic{pass: :warn}]} =
             Compiler.compile(@valid, passes: [{WarnPass, nil}])
  end

  test "diagnostics accumulate across ALL passes, built-in and host" do
    bad =
      @valid
      |> put_in(["steps", Access.at(1), "depends_on"], ["ghost"])
      |> put_in(["steps", Access.at(0), "input"], "{{narrate}}")

    assert {:error, diags} = Compiler.compile(bad, passes: [{RejectAllPass, "tenant-x"}])
    passes = diags |> Enum.map(& &1.pass) |> Enum.uniq() |> Enum.sort()
    assert :dag in passes and :refs in passes and :reject_all in passes
  end

  test "a ref not covered by depends_on is a refs error even when the step exists" do
    bad = put_in(@valid, ["steps", Access.at(0), "input"], "{{narrate}}")
    assert {:error, [%Diagnostic{pass: :refs, step_id: "analyze"} | _]} = Compiler.compile(bad)
  end

  test "cycles surface as dag diagnostics, not crashes" do
    bad = put_in(@valid, ["steps", Access.at(0), "depends_on"], ["narrate"])

    assert {:error, diags} = Compiler.compile(bad)
    assert Enum.any?(diags, &(&1.pass == :dag and &1.message =~ "cycle"))
  end
end
