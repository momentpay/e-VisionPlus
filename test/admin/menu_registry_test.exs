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

  @known_nav_modules Enum.map(AdminLive.nav_modules(), & &1.id)

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

  test "every module declares a known nav_module, group, order, label and icon" do
    for {mod, meta} <- AdminLive.menu_registry() do
      assert meta[:nav_module] in @known_nav_modules,
             "#{mod} has nav_module #{inspect(meta[:nav_module])}, which is not in nav_modules/0"

      assert is_binary(meta[:group]) and meta.group != "", "#{mod} is missing a :group"
      assert is_integer(meta[:order]), "#{mod} is missing an :order"
      assert is_binary(meta[:label]) and meta.label != "", "#{mod} is missing a label"
      assert is_binary(meta[:icon]) and meta.icon != "", "#{mod} is missing an icon"
    end
  end

  test "order is unique within each nav module, so the sidebar is deterministic" do
    AdminLive.menu_registry()
    |> Enum.group_by(fn {_mod, meta} -> meta.nav_module end)
    |> Enum.each(fn {nav_module, items} ->
      orders = Enum.map(items, fn {_mod, meta} -> meta.order end)

      assert length(orders) == length(Enum.uniq(orders)),
             "duplicate :order values in nav module #{nav_module}: #{inspect(Enum.sort(orders))}"
    end)
  end

  test "coming-soon placeholders declare a known nav_module, unique id, order, label and icon" do
    live_ids = MapSet.new(registry_modules())

    for item <- AdminLive.coming_soon_registry() do
      assert item.nav_module in @known_nav_modules,
             "#{item.id} has nav_module #{inspect(item.nav_module)}, which is not in nav_modules/0"

      assert is_nil(item.group) or (is_binary(item.group) and item.group != ""),
             "#{item.id} has an invalid :group"

      assert is_integer(item.order), "#{item.id} is missing an :order"
      assert is_binary(item.label) and item.label != "", "#{item.id} is missing a label"
      assert is_binary(item.icon) and item.icon != "", "#{item.id} is missing an icon"

      refute MapSet.member?(live_ids, item.id),
             "#{item.id} collides with a live module id in @modules"
    end

    ids = Enum.map(AdminLive.coming_soon_registry(), & &1.id)
    assert length(ids) == length(Enum.uniq(ids)), "duplicate ids in @coming_soon"
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
