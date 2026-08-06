defmodule VmuCoreWeb.Live.Admin.MenuRegistryTest do
  @moduledoc """
  Guards the admin menu contract described in
  `docs/shared/Admin_Menu_Standard.md`.

  Every assertion here corresponds to a real failure: the General Ledger
  screen was fully built, registered and working, yet invisible in the
  sidebar — because it was missing from the permission whitelist and from the
  hand-written nav list. Nothing errored; it simply never rendered.
  """
  use ExUnit.Case, async: true

  alias VmuCore.ASM.RolePermission
  alias VmuCoreWeb.Live.Admin.AdminLive

  # `module_config` deliberately piggybacks on the `system` permission rather
  # than having rows of its own — see the standard §6. Excluded here so the
  # guard does not fail on known, documented debt.
  @permission_exempt ~w[module_config]

  @known_sections Enum.map(AdminLive.sections(), fn {id, _label} -> id end)

  defp registry_modules do
    AdminLive.menu_registry() |> Map.keys() |> Enum.reject(&(&1 in @permission_exempt))
  end

  test "every menu module is permissionable" do
    missing = Enum.reject(registry_modules(), &(&1 in RolePermission.modules()))

    assert missing == [],
           "in the menu but not in RolePermission.modules/0, so invisible to " <>
             "every non-ADMIN operator: #{inspect(missing)}"
  end

  test "every menu module is granted to at least one role" do
    granted = MapSet.new(RolePermission.default_matrix(), fn {_role, mod, _actions} -> mod end)

    ungranted =
      registry_modules()
      |> Enum.reject(&MapSet.member?(granted, &1))
      # ADMIN-only is a decision, declared explicitly — not the same as being
      # forgotten, which is what this test exists to catch.
      |> Enum.reject(&(&1 in RolePermission.admin_only()))

    assert ungranted == [],
           "registered but granted to no role, so only ADMIN can see it: #{inspect(ungranted)}"
  end

  test "every module declares a known section, order, label and icon" do
    for {mod, meta} <- AdminLive.menu_registry() do
      assert meta[:section] in @known_sections,
             "#{mod} has section #{inspect(meta[:section])}, which is not in sections/0"

      assert is_integer(meta[:order]), "#{mod} is missing an :order"
      assert is_binary(meta[:label]) and meta.label != "", "#{mod} is missing a label"
      assert is_binary(meta[:icon]) and meta.icon != "", "#{mod} is missing an icon"
    end
  end

  test "order is unique within each section, so the sidebar is deterministic" do
    AdminLive.menu_registry()
    |> Enum.group_by(fn {_mod, meta} -> meta.section end)
    |> Enum.each(fn {section, items} ->
      orders = Enum.map(items, fn {_mod, meta} -> meta.order end)

      assert length(orders) == length(Enum.uniq(orders)),
             "duplicate :order values in section #{section}: #{inspect(Enum.sort(orders))}"
    end)
  end

  test "admin_only modules are genuinely granted to nobody" do
    granted = MapSet.new(RolePermission.default_matrix(), fn {_role, mod, _actions} -> mod end)

    leaked = Enum.filter(RolePermission.admin_only(), &MapSet.member?(granted, &1))

    assert leaked == [],
           "declared ADMIN-only but granted to a role: #{inspect(leaked)}"
  end

  test "permission matrix references no unknown module" do
    unknown =
      RolePermission.default_matrix()
      |> Enum.map(fn {_role, mod, _actions} -> mod end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in RolePermission.modules()))

    assert unknown == [], "granted but not whitelisted: #{inspect(unknown)}"
  end

  test "general ledger specifically is reachable" do
    assert Map.has_key?(AdminLive.menu_registry(), "gl")
    assert "gl" in RolePermission.modules()

    roles =
      RolePermission.default_matrix()
      |> Enum.filter(fn {_role, mod, actions} -> mod == "gl" and "view" in actions end)
      |> Enum.map(fn {role, _, _} -> role end)

    assert "SUPERVISOR" in roles
    assert "OPS" in roles
  end
end
