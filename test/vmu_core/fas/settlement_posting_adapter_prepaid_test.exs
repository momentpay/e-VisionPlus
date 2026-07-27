defmodule VmuCore.FAS.SettlementPostingAdapterPrepaidTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Way4 parity plan Phase 1 item 5
  (Prepaid, P4) — a prepaid account's clearing confirmation posts
  correctly instead of failing (`PurchasePosting.post/1` would always
  return `{:error, :account_not_found}` for a prepaid id, same class of
  gap Debit's D4 already fixed).
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.CMS.{PrepaidAccountOpening, PrepaidLedger, PrepaidLedgerEntry, LedgerEntry}
  alias VmuCore.FAS.{AuthorizationRecord, PendingHold, SettlementPostingAdapter}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp prepaid_account_fixture(initial_balance \\ D.new("500.00")) do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "606060", description: "test", product_type: "PREPAID"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Prepaid", last_name: "SettleTest#{n}"})
      |> Repo.insert!()

    {:ok, account} =
      PrepaidAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id,
        logo_id: logo_id, block_id: block_id
      })

    {:ok, _} =
      PrepaidLedger.load(%{
        prepaid_account_id: account.prepaid_account_id, amount: initial_balance,
        channel: "ADMIN_MANUAL", posted_by: "operator1"
      })

    account
  end

  # Mirrors exactly what FAS.Authorization.approve/2 + create_pending_hold/2
  # would have done for a real authorized prepaid transaction.
  defp authorized_hold_fixture(account, amount) do
    {:ok, _spend} = PrepaidLedger.spend(account.prepaid_account_id, amount)

    n = System.unique_integer([:positive])

    auth =
      %AuthorizationRecord{}
      |> AuthorizationRecord.changeset(%{
        pan_token: :crypto.hash(:sha256, "prepaid-settle-test-#{n}") |> Base.encode16(case: :lower),
        amount: amount, currency: "784",
        channel: "pos", mti: "0100", rc: "00",
        approval_code: "#{200000 + n}", rrn: "PRRN#{n}",
        account_id: account.prepaid_account_id
      })
      |> Repo.insert!()

    %PendingHold{}
    |> PendingHold.changeset(%{
      fas_authorization_id: auth.id, account_id: account.prepaid_account_id,
      hold_amount: amount, hold_type: "standard",
      expires_at: DateTime.add(DateTime.utc_now(), 7, :day) |> DateTime.truncate(:second)
    })
    |> Repo.insert!()

    auth
  end

  test "confirm_one/1 posts a liability-direction ledger entry for a prepaid account and clears its hold" do
    account = prepaid_account_fixture()
    auth = authorized_hold_fixture(account, D.new("120.00"))

    assert :ok =
             SettlementPostingAdapter.confirm_one(%{
               approval_code: auth.approval_code, rrn: auth.rrn,
               settled_amount: D.new("120.00"), settled_date: Date.utc_today()
             })

    key = "settlement:#{auth.approval_code}:#{auth.rrn}"
    entry = Repo.get_by!(LedgerEntry, idempotency_key: key)

    assert entry.transaction_code == "PURCHASE"
    assert entry.gl_account_dr == "5002"
    assert entry.gl_account_cr == "1006"
    assert D.equal?(entry.dr_amount, entry.cr_amount)

    hold = Repo.get_by!(PendingHold, fas_authorization_id: auth.id)
    refute is_nil(hold.cleared_at)
  end

  test "confirm_one/1 does NOT touch the ledger again — it was already debited at authorization" do
    account = prepaid_account_fixture(D.new("500.00"))
    auth = authorized_hold_fixture(account, D.new("120.00"))

    assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new("380.00"))

    :ok =
      SettlementPostingAdapter.confirm_one(%{
        approval_code: auth.approval_code, rrn: auth.rrn,
        settled_amount: D.new("120.00"), settled_date: Date.utc_today()
      })

    assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new("380.00"))
  end

  test "confirm_one/1 is idempotent for a prepaid settlement (retry after already posted)" do
    account = prepaid_account_fixture()
    auth = authorized_hold_fixture(account, D.new("50.00"))

    item = %{approval_code: auth.approval_code, rrn: auth.rrn,
             settled_amount: D.new("50.00"), settled_date: Date.utc_today()}

    assert :ok = SettlementPostingAdapter.confirm_one(item)
    assert :ok = SettlementPostingAdapter.confirm_one(item)

    key = "settlement:#{auth.approval_code}:#{auth.rrn}"
    assert Repo.aggregate(from(e in LedgerEntry, where: e.idempotency_key == ^key), :count) == 1
  end

  test "an expired hold released by the sweep restores balance via a REFUND row, not the original load" do
    account = prepaid_account_fixture(D.new("100.00"))
    auth = authorized_hold_fixture(account, D.new("30.00"))

    hold = Repo.get_by!(PendingHold, fas_authorization_id: auth.id)
    assert {:ok, _entry} = PrepaidLedger.refund(hold.account_id, hold.hold_amount)

    assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new("100.00"))
    assert Repo.get_by(PrepaidLedgerEntry, prepaid_account_id: account.prepaid_account_id, entry_type: "REFUND")
  end
end
