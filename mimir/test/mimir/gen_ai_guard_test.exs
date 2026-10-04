defmodule Mimir.GenAIGuardTest do
  @moduledoc """
  `gen_ai` is a wire format at the OTel export edge, not a domain model
  (spec: "Event Vocabulary — Domain-Typed Events, `gen_ai` Demoted to the
  OTel Edge"). This test enforces that demotion mechanically: the substring
  `gen_ai` may only survive in `lib/mimir/event/otel.ex`, where it names the
  OTel GenAI semantic-convention attributes being rendered.
  """
  use ExUnit.Case, async: true

  test "gen_ai survives only at the OTel export edge" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(&(&1 == "lib/mimir/event/otel.ex"))
      |> Enum.filter(&(File.read!(&1) =~ "gen_ai"))

    assert offenders == [], "gen_ai outside the export edge: #{inspect(offenders)}"
  end
end
