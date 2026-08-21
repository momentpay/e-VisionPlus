defmodule VmuCoreWeb.Live.Admin.CmsResegmentationComponentTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Reuses the self-contained
  parameter-hierarchy + account fixture pattern from
  `VmuCore.CMS.CycleResegmentationTest` / the DPS test suite.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}
  alias VmuCore.CMS.Account
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, ModuleConfigWriter, SysParameter}
  alias Decimal, as: D

  @endpoint VmuCoreWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Authz.seed_default_matrix()
    Authz.refresh()
    :ok
  end

  defp operator_fixture(role) do
    %Operator{}
    |> Operator.changeset(%{
      username: "reseg_ui_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "Reseg UI Test #{role}",
      pw_hash: "x",
      pw_salt: "x",
      role: role,
      status: "ACTIVE"
    })
    |> Repo.insert!()
  end

  defp authed_conn(operator) do
    build_conn()
    |> init_test_session(%{"operator_id" => operator.operator_id, "logged_in_at" => System.os_time(:second)})
  end

  defp parameter_hierarchy_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()

    %BankParameter{}
    |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"})
    |> Repo.insert!()

    %LogoParameter{}
    |> LogoParameter.changeset(%{
      sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test"
    })
    |> Repo.insert!()

    %BlockParameter{}
    |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id})
    |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  defp account_fixture({sys_id, bank_id, logo_id, block_id}, overrides) do
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Reseg", last_name: "UI#{n}",
        id_type: "PASSPORT", id_number: "RESEG-UI-#{n}"
      })
      |> Repo.insert!()

    attrs =
      Map.merge(
        %{
          customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
          block_id: block_id, pan_token: "reseg-ui-pan-#{n}", last_four: "9999",
          expiry_date: "1230", credit_limit: D.new("5000.00"), cycle_code: 1
        },
        overrides
      )

    %Account{} |> Account.changeset(attrs) |> Repo.insert!()
  end

  defp load_scope(view, sys_id, bank_id, logo_id) do
    view
    |> form("form[phx-submit=load_scope]", %{"sys_id" => sys_id, "bank_id" => bank_id, "logo_id" => logo_id})
    |> render_submit()
  end

  describe "SUPERVISOR — full flow" do
    test "loads a scope, proposes and applies a rebalance, then cancels the pending change" do
      {sys_id, bank_id, logo_id, _} = scope = parameter_hierarchy_fixture()

      ModuleConfigWriter.put(
        "cms", "allowed_cycle_codes", [1, 2],
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil
      )

      ModuleConfigWriter.put(
        "cms", "resegmentation_rebalance_threshold_pct", 10,
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil
      )

      overloaded = for _ <- 1..5, do: account_fixture(scope, %{cycle_code: 1})
      account_fixture(scope, %{cycle_code: 2})

      operator = operator_fixture("SUPERVISOR")
      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/cms_resegmentation")

      html = load_scope(view, sys_id, bank_id, logo_id)
      assert html =~ "Total active accounts"
      assert html =~ "6"

      html = view |> element("button", "Propose Rebalance") |> render_click()
      assert html =~ "Proposed Rebalance"
      assert html =~ "account(s) proposed to move"

      html = view |> element("button", "Schedule These Moves") |> render_click()
      assert html =~ "Scheduled"

      pending_ids =
        overloaded
        |> Enum.map(& &1.account_id)
        |> Enum.map(&Repo.get!(Account, &1))
        |> Enum.filter(&(&1.pending_cycle_code == 2))

      assert pending_ids != []
      assert html =~ "Pending Changes"

      first_pending = hd(pending_ids)

      html =
        view
        |> with_target("#cms-resegmentation-component")
        |> render_click("cancel_pending", %{"id" => first_pending.account_id})

      assert html =~ "Pending change cancelled."
      reloaded = Repo.get!(Account, first_pending.account_id)
      assert is_nil(reloaded.pending_cycle_code)
    end

    test "shows :balanced when nothing needs to move" do
      {sys_id, bank_id, logo_id, _} = scope = parameter_hierarchy_fixture()

      ModuleConfigWriter.put(
        "cms", "allowed_cycle_codes", [1, 2],
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil
      )

      account_fixture(scope, %{cycle_code: 1})
      account_fixture(scope, %{cycle_code: 2})

      operator = operator_fixture("SUPERVISOR")
      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/cms_resegmentation")

      load_scope(view, sys_id, bank_id, logo_id)
      html = view |> element("button", "Propose Rebalance") |> render_click()

      assert html =~ "Distribution is within the configured threshold"
    end
  end

  describe "role gating (COMPLIANCE — view only)" do
    test "can load a scope and propose, but has no apply/cancel controls" do
      {sys_id, bank_id, logo_id, _} = scope = parameter_hierarchy_fixture()

      ModuleConfigWriter.put(
        "cms", "allowed_cycle_codes", [1, 2],
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil
      )

      ModuleConfigWriter.put(
        "cms", "resegmentation_rebalance_threshold_pct", 10,
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil
      )

      for _ <- 1..5, do: account_fixture(scope, %{cycle_code: 1})
      account_fixture(scope, %{cycle_code: 2})

      operator = operator_fixture("COMPLIANCE")
      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/cms_resegmentation")

      load_scope(view, sys_id, bank_id, logo_id)
      refute has_element?(view, "button", "Propose Rebalance")
    end
  end
end
