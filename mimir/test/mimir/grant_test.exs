defmodule Mimir.GrantTest do
  use ExUnit.Case, async: true

  test "builds with enforced key and optional budget/expiry" do
    g = %Mimir.Grant{key: "vk-1", expires_at: nil, budget_microdollars: 50_000}
    assert g.key == "vk-1"
    assert g.budget_microdollars == 50_000
    assert g.expires_at == nil
  end

  test "key is enforced" do
    assert_raise ArgumentError, fn -> struct!(Mimir.Grant, %{}) end
  end
end
