defmodule VmuCoreWeb.Live.Admin.MenuRegistryTest do
  @moduledoc """
  Guards the admin navigation contract described in
  `docs/shared/Admin_Menu_Standard.md`.

  Every assertion here corresponds to a real failure: the General Ledger
  screen was fully built, registered and working, yet invisible in the
  sidebar — because it was missing from the permission whitelist and from the
  hand-written nav list. Nothing errored; it simply never rendered.
  """
  use ExUnit.Case, async: true

  alias VmuCore.ASM.RolePermission
  alias VmuCoreWeb.Admin.Nav
  alias VmuCoreWeb.Icons
  alias VmuCoreWeb.Live.Admin.AdminLive

  # `module_config` deliberately piggybacks on the `system` permission rather
  # than having rows of its own — see the standard §6. Excluded here so the
  # guard does not fail on known, documented debt.
  @permission_exempt ~w[module_config]

  @nav_module_ids Nav.nav_module_ids()

  defp permissionable_ids do
    Enum.reject(Nav.live_ids(), &(&1 in @permission_exempt))
  end

  describe "live screens and permissions" do
    test "every live screen is permissionable" do
      missing = Enum.reject(permissionable_ids(), &(&1 in RolePermission.modules()))

      assert missing == [],
             "in the menu but not in RolePermission.modules/0, so invisible to " <>
               "every non-ADMIN operator: #{inspect(missing)}"
    end

    test "every live screen is granted to at least one role" do
      granted = MapSet.new(RolePermission.default_matrix(), fn {_role, mod, _actions} -> mod end)

      ungranted =
        permissionable_ids()
        |> Enum.reject(&MapSet.member?(granted, &1))
        # ADMIN-only is a decision, declared explicitly — not the same as being
        # forgotten, which is what this test exists to catch.
        |> Enum.reject(&(&1 in RolePermission.admin_only()))

      assert ungranted == [],
             "registered but granted to no role, so only ADMIN can see it: #{inspect(ungranted)}"
    end

    test "admin_only modules are genuinely granted to nobody" do
      granted = MapSet.new(RolePermission.default_matrix(), fn {_role, mod, _actions} -> mod end)

      leaked = Enum.filter(RolePermission.admin_only(), &MapSet.member?(granted, &1))

      assert leaked == [], "declared ADMIN-only but granted to a role: #{inspect(leaked)}"
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
      assert Nav.live?("gl")
      assert "gl" in RolePermission.modules()

      roles =
        RolePermission.default_matrix()
        |> Enum.filter(fn {_role, mod, actions} -> mod == "gl" and "view" in actions end)
        |> Enum.map(fn {role, _, _} -> role end)

      assert "SUPERVISOR" in roles
      assert "OPS" in roles
    end
  end

  describe "taxonomy shape" do
    test "every item declares a known nav module, group, orders, label and icon" do
      for item <- Nav.items() do
        assert item.nav_module in @nav_module_ids,
               "#{item.id} has nav_module #{inspect(item.nav_module)}, not in nav_modules/0"

        assert is_binary(item.group) and item.group != "", "#{item.id} is missing a :group"
        assert is_integer(item.group_order), "#{item.id} is missing a :group_order"
        assert is_integer(item.order), "#{item.id} is missing an :order"
        assert is_binary(item.label) and item.label != "", "#{item.id} is missing a label"
        assert item.status in [:live, :planned], "#{item.id} has an invalid :status"
      end
    end

    test "item ids are unique" do
      ids = Enum.map(Nav.items(), & &1.id)
      dupes = ids -- Enum.uniq(ids)
      assert dupes == [], "duplicate item ids: #{inspect(dupes)}"
    end

    test "an item id never collides with a nav module id" do
      collisions = Enum.filter(Nav.items(), &(&1.id in @nav_module_ids))

      assert collisions == [],
             "these item ids shadow a nav module id, so /visionplus/admin/<id> is ambiguous: " <>
               inspect(Enum.map(collisions, & &1.id))
    end

    test "nav module ids and accents are unique" do
      ids = Enum.map(Nav.nav_modules(), & &1.id)
      assert ids == Enum.uniq(ids)

      accents = Enum.map(Nav.nav_modules(), & &1.accent)

      assert accents == Enum.uniq(accents),
             "two modules share an accent, so they read as the same domain: " <>
               inspect(accents -- Enum.uniq(accents))
    end

    test "order is unique within each group, so the sidebar is deterministic" do
      Nav.items()
      |> Enum.group_by(&{&1.nav_module, &1.group})
      |> Enum.each(fn {key, items} ->
        orders = Enum.map(items, & &1.order)

        assert length(orders) == length(Enum.uniq(orders)),
               "duplicate :order values in #{inspect(key)}: #{inspect(Enum.sort(orders))}"
      end)
    end

    test "a group has one group_order across every item that names it" do
      Nav.items()
      |> Enum.group_by(&{&1.nav_module, &1.group}, & &1.group_order)
      |> Enum.each(fn {key, group_orders} ->
        assert Enum.uniq(group_orders) |> length() == 1,
               "#{inspect(key)} is declared with conflicting group_order values: " <>
                 inspect(Enum.uniq(group_orders))
      end)
    end

    test "every nav module has at least one item, so no dock tile is a dead end" do
      for nav <- Nav.nav_modules() do
        items = Enum.filter(Nav.items(), &(&1.nav_module == nav.id))
        assert items != [], "nav module #{nav.id} has no items at all"
      end
    end

    test "every icon referenced by the taxonomy exists in the sprite" do
      referenced =
        (Enum.map(Nav.nav_modules(), & &1.icon) ++ Enum.map(Nav.items(), & &1.icon))
        |> Enum.uniq()

      missing = Enum.reject(referenced, &Icons.known?/1)

      assert missing == [],
             "referenced but not defined in VmuCoreWeb.Icons, so they render as a dash: " <>
               inspect(missing)
    end
  end

  describe "derivation used by the shell" do
    test "dock_target lands a module with no visible live item on itself" do
      for nav <- Nav.nav_modules() do
        assert Nav.dock_target(nav.id, MapSet.new()) == nav.id
      end
    end

    test "dock_target lands a module with visible items on its first live item" do
      assert Nav.dock_target("finance", MapSet.new(["gl", "cms_eod"])) == "gl"
    end

    test "nav_module_for resolves a leaf item back to its owning module" do
      assert Nav.nav_module_for("gl") == "finance"
      assert Nav.nav_module_for("customer") == "party"
      assert Nav.nav_module_for("cms_eod") == "billing"
    end

    test "nav_module_landing? distinguishes a module id from a leaf id" do
      assert Nav.nav_module_landing?("loyalty")
      refute Nav.nav_module_landing?("gl")
    end

    test "sidebar_groups hides live items the operator cannot see but keeps planned ones" do
      groups = Nav.sidebar_groups("party", MapSet.new())
      ids = groups |> Enum.flat_map(fn {_g, items} -> items end) |> Enum.map(& &1.id)

      refute "customer" in ids, "a live screen leaked past the permission filter"
      assert "party_360" in ids, "planned items should not be permission-gated"
    end

    test "sidebar_groups orders groups by group_order and items by order" do
      groups = Nav.sidebar_groups("party", MapSet.new(Nav.live_ids()))

      assert [{"Customer Management", _} | _] = groups

      {_, first_group_items} = hd(groups)
      assert ["customer", "party_360", "relationships"] = Enum.map(first_group_items, & &1.id)
    end

    test "every nav module yields sidebar groups when everything is visible" do
      visible = MapSet.new(Nav.live_ids())

      for nav <- Nav.nav_modules() do
        assert Nav.sidebar_groups(nav.id, visible) != [],
               "#{nav.id} renders an empty sidebar"
      end
    end
  end

  describe "AdminLive delegation" do
    test "menu_registry exposes live screens keyed by id" do
      registry = AdminLive.menu_registry()

      assert is_map(registry)
      assert Map.has_key?(registry, "gl")
      assert registry["gl"].label == "General Ledger"
      refute Map.has_key?(registry, "party_360"), "planned items must not appear as live screens"
    end

    test "nav_modules is exposed for the dock" do
      assert length(AdminLive.nav_modules()) == length(Nav.nav_modules())
    end
  end
end
