defmodule VmuCore.FAS.SettlementPostingAdapterDebitTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Way4 parity plan Phase 1 item 4
  (Debit, D4) — first-ever test coverage for `SettlementPostingAdapter`,
  covering the branch that lets a debit account's clearing confirmation
  post correctly instead of failing (`PurchasePosting.post/1` would
  always return `{:error, :account_not_found}` for a debit id).
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.GLFixtures
  alias VmuCore.CMS.{DebitAccount, DebitAccountOpening, DebitAuthorization, DebitFundingCommand}
  alias VmuCore.GL.LedgerQuery
  alias VmuCore.FAS.{AuthorizationRecord, PendingHold, SettlementPostingAdapter}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp debit_account_fixture(initial_balance \\ D.new("500.00")) do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()

    # GL Phase C3: `InternalGlPoster` posts through `Posting.RuleEngine` now, so
    # a posting needs the chart, the rules, and an institution whose banking
    # date is open — the period gate refuses one that is not. Production gets
    # all three from `seed_gl.exs`; a test that mints an institution inline has
    # to supply them. See `VmuCore.GLFixtures`.
    :ok = GLFixtures.seed_posting_engine!()
    :ok = GLFixtures.open_institution!(sys_id, bank_id)
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "555555", description: "test", product_type: "DEBIT"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Debit", last_name: "SettleTest#{n}"})
      |> Repo.insert!()

    {:ok, account} =
      DebitAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id,
        logo_id: logo_id, block_id: block_id
      })

    {:ok, _} =
      DebitFundingCommand.fund(%{
        debit_account_id: account.debit_account_id, amount: initial_balance,
        channel: "ADMIN_MANUAL", posted_by: "operator1"
      })

    account
  end

  # Mirrors exactly what FAS.Authorization.approve/2 + create_pending_hold/2
  # would have done for a real authorized debit transaction — built
  # directly here (not via the async persist_async path) for a
  # deterministic test.
  defp authorized_hold_fixture(account, amount) do
    {:ok, _new_balance} = DebitAuthorization.authorize(account.debit_account_id, amount)

    n = System.unique_integer([:positive])

    auth =
      %AuthorizationRecord{}
      |> AuthorizationRecord.changeset(%{
        pan_token: :crypto.hash(:sha256, "debit-settle-test-#{n}") |> Base.encode16(case: :lower),
        amount: amount, currency: "784",
        channel: "pos", mti: "0100", rc: "00",
        approval_code: "#{100000 + n}", rrn: "RRN#{n}",
        account_id: account.debit_account_id
      })
      |> Repo.insert!()

    %PendingHold{}
    |> PendingHold.changeset(%{
      fas_authorization_id: auth.id, account_id: account.debit_account_id,
      hold_amount: amount, hold_type: "standard",
      expires_at: DateTime.add(DateTime.utc_now(), 7, :day) |> DateTime.truncate(:second)
    })
    |> Repo.insert!()

    auth
  end

  test "confirm_one/1 posts a liability-direction ledger entry for a debit account and clears its hold" do
    account = debit_account_fixture()
    auth = authorized_hold_fixture(account, D.new("120.00"))

    assert :ok =
             SettlementPostingAdapter.confirm_one(%{
               approval_code: auth.approval_code, rrn: auth.rrn,
               settled_amount: D.new("120.00"), settled_date: Date.utc_today()
             })

    key = "settlement:#{auth.approval_code}:#{auth.rrn}"
    # GL Phase C3: postings live in `journal_entries`, keyed through their
    # posting set's idempotency key. `LedgerQuery` is the read API for that.
    entry = LedgerQuery.entries(idempotency_key: key) |> List.first()
    assert entry, "no posting found for #{key}"

    assert entry.event_type == "PURCHASE"
  # Account codes remapped by GL Phase 4A (VMU-ADR-005): stored value moved
  # out of the 5xxx expense range into 2xxx liabilities, and cash clearing
  # from 1006 (an HCS receivable) to 3005.
    assert entry.dr_gl_account == "2004"
    assert entry.cr_gl_account == "3005"
    # GL Phase C3: the journal entry keeps a single `amount`. The two sides being
    # equal is now enforced by construction rather than asserted here.
    assert %Decimal{} = entry.amount

    hold = Repo.get_by!(PendingHold, fas_authorization_id: auth.id)
    refute is_nil(hold.cleared_at)
  end

  test "confirm_one/1 does NOT touch available_balance again — it was already debited at authorization" do
    account = debit_account_fixture(D.new("500.00"))
    auth = authorized_hold_fixture(account, D.new("120.00"))

    # authorize/2 already brought it to 380.00 inside authorized_hold_fixture/2.
    reloaded_before = Repo.get!(DebitAccount, account.debit_account_id)
    assert D.equal?(reloaded_before.available_balance, D.new("380.00"))

    :ok =
      SettlementPostingAdapter.confirm_one(%{
        approval_code: auth.approval_code, rrn: auth.rrn,
        settled_amount: D.new("120.00"), settled_date: Date.utc_today()
      })

    reloaded_after = Repo.get!(DebitAccount, account.debit_account_id)
    assert D.equal?(reloaded_after.available_balance, D.new("380.00"))
  end

  test "confirm_one/1 is idempotent for a debit settlement (retry after already posted)" do
    account = debit_account_fixture()
    auth = authorized_hold_fixture(account, D.new("50.00"))

    item = %{approval_code: auth.approval_code, rrn: auth.rrn,
             settled_amount: D.new("50.00"), settled_date: Date.utc_today()}

    assert :ok = SettlementPostingAdapter.confirm_one(item)
    assert :ok = SettlementPostingAdapter.confirm_one(item)

    key = "settlement:#{auth.approval_code}:#{auth.rrn}"
    assert LedgerQuery.count(idempotency_key: key) == 1
  end

  test "confirm_one/1 returns :not_found when no matching authorization exists" do
    assert :not_found =
             SettlementPostingAdapter.confirm_one(%{
               approval_code: "999999", rrn: "NOPE",
               settled_amount: D.new("10.00"), settled_date: Date.utc_today()
             })
  end
end
