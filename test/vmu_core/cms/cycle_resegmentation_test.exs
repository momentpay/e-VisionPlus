defmodule VmuCore.CMS.CycleResegmentationTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Self-contained parameter
  hierarchy + account fixtures (same pattern as the DPS test suite) since
  this test DB carries no seeded SYS/BANK/LOGO/BLOCK rows.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{Account, CycleResegmentation}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, ModuleConfigWriter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
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

  defp account_fixture({sys_id, bank_id, logo_id, block_id}, overrides \\ %{}) do
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Reseg", last_name: "Test#{n}",
        id_type: "PASSPORT", id_number: "RESEG-TEST-#{n}"
      })
      |> Repo.insert!()

    attrs =
      Map.merge(
        %{
          customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
          block_id: block_id, pan_token: "reseg-test-pan-#{n}", last_four: "9999",
          expiry_date: "1230", credit_limit: D.new("5000.00"), cycle_code: 1
        },
        overrides
      )

    %Account{} |> Account.changeset(attrs) |> Repo.insert!()
  end

  describe "schedule_resegmentation/3" do
    test "sets pending fields with a real notice-period effective date and audits it" do
      scope = parameter_hierarchy_fixture()
      account = account_fixture(scope)

      assert {:ok, effective_date} = CycleResegmentation.schedule_resegmentation(account.account_id, 15, nil)
      assert Date.diff(effective_date, Date.utc_today()) == 30

      reloaded = Repo.get!(Account, account.account_id)
      assert reloaded.pending_cycle_code == 15
      assert reloaded.cycle_change_effective_date == effective_date
      assert reloaded.cycle_change_proration_method == "prorate"
      assert reloaded.cycle_code == 1
    end

    test "honors a bank-configured notice period" do
      {sys_id, bank_id, logo_id, _block_id} = scope = parameter_hierarchy_fixture()
      account = account_fixture(scope)

      ModuleConfigWriter.put("cms", "resegmentation_notice_days", 45, %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

      assert {:ok, effective_date} = CycleResegmentation.schedule_resegmentation(account.account_id, 15, nil)
      assert Date.diff(effective_date, Date.utc_today()) == 45
    end

    test "rejects a duplicate schedule while one is already pending" do
      scope = parameter_hierarchy_fixture()
      account = account_fixture(scope)

      assert {:ok, _} = CycleResegmentation.schedule_resegmentation(account.account_id, 15, nil)
      assert {:error, :already_pending} = CycleResegmentation.schedule_resegmentation(account.account_id, 20, nil)
    end

    test "rejects scheduling the same cycle_code the account already has" do
      scope = parameter_hierarchy_fixture()
      account = account_fixture(scope)

      assert {:error, :same_cycle_code} = CycleResegmentation.schedule_resegmentation(account.account_id, 1, nil)
    end

    test "rejects a cycle_code outside a bank-configured allow-list" do
      {sys_id, bank_id, logo_id, _block_id} = scope = parameter_hierarchy_fixture()
      account = account_fixture(scope)

      ModuleConfigWriter.put("cms", "allowed_cycle_codes", [1, 15], %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

      assert {:error, :cycle_code_not_allowed} = CycleResegmentation.schedule_resegmentation(account.account_id, 22, nil)
      assert {:ok, _} = CycleResegmentation.schedule_resegmentation(account.account_id, 15, nil)
    end

    test "enforces the minimum interval since the account's last real change" do
      scope = parameter_hierarchy_fixture()
      account = account_fixture(scope, %{cycle_code_changed_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)})

      assert {:error, :too_soon_since_last_change} = CycleResegmentation.schedule_resegmentation(account.account_id, 15, nil)
    end

    test "allows a change once the configured interval has passed" do
      scope = parameter_hierarchy_fixture()

      long_ago =
        NaiveDateTime.utc_now() |> NaiveDateTime.add(-400 * 86_400, :second) |> NaiveDateTime.truncate(:second)

      account = account_fixture(scope, %{cycle_code_changed_at: long_ago})

      assert {:ok, _} = CycleResegmentation.schedule_resegmentation(account.account_id, 15, nil)
    end
  end

  describe "cancel_pending/2" do
    test "clears a pending change" do
      scope = parameter_hierarchy_fixture()
      account = account_fixture(scope)

      {:ok, _} = CycleResegmentation.schedule_resegmentation(account.account_id, 15, nil)
      assert :ok = CycleResegmentation.cancel_pending(account.account_id, nil)

      reloaded = Repo.get!(Account, account.account_id)
      assert is_nil(reloaded.pending_cycle_code)
      assert is_nil(reloaded.cycle_change_effective_date)
    end

    test "errors when nothing is pending" do
      scope = parameter_hierarchy_fixture()
      account = account_fixture(scope)

      assert {:error, :no_pending_change} = CycleResegmentation.cancel_pending(account.account_id, nil)
    end
  end

  describe "apply_due_changes/1" do
    test "does not apply a change before its effective date" do
      scope = parameter_hierarchy_fixture()
      account = account_fixture(scope)

      {:ok, _effective_date} = CycleResegmentation.schedule_resegmentation(account.account_id, 15, nil)

      applied = CycleResegmentation.apply_due_changes(Date.utc_today())
      assert applied == 0

      reloaded = Repo.get!(Account, account.account_id)
      assert reloaded.cycle_code == 1
      assert reloaded.pending_cycle_code == 15
    end

    test "applies a change on/after its effective date, clears pending fields, stamps changed_at" do
      scope = parameter_hierarchy_fixture()
      account = account_fixture(scope)

      {:ok, effective_date} = CycleResegmentation.schedule_resegmentation(account.account_id, 15, nil)

      applied = CycleResegmentation.apply_due_changes(effective_date)
      assert applied >= 1

      reloaded = Repo.get!(Account, account.account_id)
      assert reloaded.cycle_code == 15
      assert is_nil(reloaded.pending_cycle_code)
      assert is_nil(reloaded.cycle_change_effective_date)
      refute is_nil(reloaded.cycle_code_changed_at)
    end
  end

  describe "analyze_distribution/3 + propose_rebalance/3" do
    test "reports :balanced when accounts are evenly spread across allowed codes" do
      {sys_id, bank_id, logo_id, _} = scope = parameter_hierarchy_fixture()
      ModuleConfigWriter.put("cms", "allowed_cycle_codes", [1, 2], %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

      account_fixture(scope, %{cycle_code: 1})
      account_fixture(scope, %{cycle_code: 2})

      assert {:ok, %{status: :balanced}} = CycleResegmentation.propose_rebalance(sys_id, bank_id, logo_id)
    end

    test "proposes real moves off an overloaded cycle_code onto an underloaded one" do
      {sys_id, bank_id, logo_id, _} = scope = parameter_hierarchy_fixture()
      ModuleConfigWriter.put("cms", "allowed_cycle_codes", [1, 2], %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)
      ModuleConfigWriter.put("cms", "resegmentation_rebalance_threshold_pct", 10, %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

      overloaded = for _ <- 1..5, do: account_fixture(scope, %{cycle_code: 1})
      account_fixture(scope, %{cycle_code: 2})

      assert {:ok, %{status: :imbalanced, moves: moves}} = CycleResegmentation.propose_rebalance(sys_id, bank_id, logo_id)
      assert moves != []
      assert Enum.all?(moves, &(&1.from_cycle_code == 1 and &1.to_cycle_code == 2))

      moved_ids = MapSet.new(moves, & &1.account_id)
      overloaded_ids = MapSet.new(overloaded, & &1.account_id)
      assert MapSet.subset?(moved_ids, overloaded_ids)
    end

    test "excludes accounts that already have a pending change from proposed moves" do
      {sys_id, bank_id, logo_id, _} = scope = parameter_hierarchy_fixture()
      ModuleConfigWriter.put("cms", "allowed_cycle_codes", [1, 2], %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)
      ModuleConfigWriter.put("cms", "resegmentation_rebalance_threshold_pct", 10, %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

      already_pending = account_fixture(scope, %{cycle_code: 1})
      {:ok, _} = CycleResegmentation.schedule_resegmentation(already_pending.account_id, 2, nil)

      for _ <- 1..4, do: account_fixture(scope, %{cycle_code: 1})
      account_fixture(scope, %{cycle_code: 2})

      {:ok, %{moves: moves}} = CycleResegmentation.propose_rebalance(sys_id, bank_id, logo_id)
      refute Enum.any?(moves, &(&1.account_id == already_pending.account_id))
    end
  end

  describe "run_auto_rebalance/0" do
    test "schedules moves for a scope configured resegmentation_mode: auto, leaves manual scopes untouched" do
      {sys_id, bank_id, logo_id, _} = auto_scope = parameter_hierarchy_fixture()
      ModuleConfigWriter.put("cms", "resegmentation_mode", "auto", %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)
      ModuleConfigWriter.put("cms", "allowed_cycle_codes", [1, 2], %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)
      ModuleConfigWriter.put("cms", "resegmentation_rebalance_threshold_pct", 10, %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

      for _ <- 1..5, do: account_fixture(auto_scope, %{cycle_code: 1})
      account_fixture(auto_scope, %{cycle_code: 2})

      manual_scope = parameter_hierarchy_fixture()
      {msys, mbank, mlogo, _} = manual_scope
      ModuleConfigWriter.put("cms", "allowed_cycle_codes", [1, 2], %{scope_type: "bank", sys_id: msys, bank_id: mbank}, nil)
      ModuleConfigWriter.put("cms", "resegmentation_rebalance_threshold_pct", 10, %{scope_type: "bank", sys_id: msys, bank_id: mbank}, nil)
      for _ <- 1..5, do: account_fixture(manual_scope, %{cycle_code: 1})
      account_fixture(manual_scope, %{cycle_code: 2})

      scheduled_count = CycleResegmentation.run_auto_rebalance()
      assert scheduled_count > 0

      auto_pending = CycleResegmentation.list_pending(sys_id, bank_id, logo_id)
      assert auto_pending != []

      manual_pending = CycleResegmentation.list_pending(msys, mbank, mlogo)
      assert manual_pending == []
    end
  end
end
