defmodule VmuCore.CMS.AccountStateCoordinatorDurabilityTest do
  @moduledoc """
  Proves the actual bug this phase exists to fix: before
  `OtbReconciliation`, a live approval reduced `open_to_buy` purely
  in-memory — nothing durable backed it, so a coordinator restart (crash,
  30-minute idle-timeout, node bounce) silently forgot the approval and OTB
  reverted to the stale `cms_accounts` column. This test drives a real
  approval through `FAS.Authorization.process/1`, forces the coordinator to
  restart, and asserts the restarted state still reflects the approval.
  """

  use VmuCore.DataCase, async: false

  alias VmuCore.FAS.{Authorization, STIP, PendingHold}
  alias VmuCore.GLFixtures
  alias VmuCore.CMS.{Account, AccountStateCoordinator}
  alias VmuCore.CTA.Cards
  alias VmuCore.Shared.Customer
  alias Decimal, as: D

  @table :vmu_parameter_cache

  defp seed_parameter_hierarchy do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, {:read_concurrency, true}])
    else
      :ets.delete_all_objects(@table)
    end

    :ets.insert(@table, {{:sys,  "0001", :base_currency}, "AED"})
    :ets.insert(@table, {{:bank, "0001", "0010", :country_code}, "ARE"})
    :ets.insert(@table, {{:logo, "0001", "0010", "0100", :bin_prefix}, "543210"})
    :ets.insert(@table, {{:logo, "0001", "0010", "0100", :description}, "Test Logo"})
  end

  defp pan_token(pan), do: :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)

  defp seed_account(pan, credit_limit) do
    {:ok, customer} =
      Repo.insert(Customer.changeset(%Customer{}, %{
        sys_id: "0001", bank_id: "0010", first_name: "Test", last_name: "DurabilityFixture"
      }))

    {:ok, account} =
      Repo.insert(Account.changeset(%Account{}, %{
        customer_id:    customer.customer_id,
        sys_id:         "0001",
        bank_id:        "0010",
        logo_id:        "0100",
        block_id:       "1000",
        pan_token:      pan_token(pan),
        last_four:      String.slice(pan, -4, 4),
        expiry_date:    "1228",
        credit_limit:   credit_limit,
        open_to_buy:    credit_limit,
        account_status: "ACTIVE"
      }))

    {:ok, _card} =
      Cards.issue(%{
        account_id: account.account_id, pan_token: pan_token(pan),
        card_type: "PRIMARY", status: "ACTIVE"
      })

    account
  end

  # persist_async/5 writes the PendingHold via a bare Task.start/1 - no
  # handle to await. {:shared, self()} sandbox mode makes the write visible
  # to this process once committed, but gives no synchronization signal, so
  # poll briefly rather than assume it landed synchronously with the
  # response.
  defp wait_for_hold(account_id, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_hold(account_id, deadline)
  end

  defp do_wait_for_hold(account_id, deadline) do
    case Repo.get_by(PendingHold, account_id: account_id) do
      %PendingHold{} = hold ->
        hold

      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          do_wait_for_hold(account_id, deadline)
        else
          flunk("fas_pending_holds row never landed for account #{account_id}")
        end
    end
  end

  setup do
    seed_parameter_hierarchy()
    STIP.init_cache()
    :ok = GLFixtures.seed_posting_engine!()
    :ok = GLFixtures.open_institution!("0001", "0010")
    :ok
  end

  test "a coordinator restart after a real approval reflects the durable hold, not the stale DB column" do
    pan = "5432109999000011"
    account = seed_account(pan, D.new("1000.00"))

    request = %{pan: pan, amount: D.new("300.00"), channel: :pos, mcc: "5411"}
    assert {:ok, "00", _approval_code} = Authorization.process(request)

    # The durable side effect this whole fix depends on: a real hold landed,
    # asynchronously, off the response path.
    wait_for_hold(account.account_id)

    # Before this phase's fix, the stored `cms_accounts.open_to_buy` column
    # is never written to on approval - it's still the original credit
    # limit here, which is exactly the bug: a coordinator reload would have
    # silently forgotten the approval.
    stale_column = Repo.get!(Account, account.account_id).open_to_buy
    assert D.equal?(stale_column, D.new("1000.00"))

    # Force a real reload - the same code path a crash/restart/idle-timeout
    # takes (load_state/1), not a simulated shortcut.
    assert :ok = AccountStateCoordinator.refresh(account.account_id)

    # The next authorize/3 call sees the reconstructed state. A second
    # approval that would only fit within the POST-approval OTB (700.00,
    # not the stale 1000.00) proves the restart genuinely remembered the
    # first approval rather than reverting to the stale column.
    assert {:declined, "51", :insufficient_otb} =
             AccountStateCoordinator.authorize(account.account_id, D.new("800.00"))

    assert {:approved, "00", _, _} =
             AccountStateCoordinator.authorize(account.account_id, D.new("600.00"))
  end
end
