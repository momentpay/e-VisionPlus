defmodule VmuCore.CMS.Oban.OtbReconciliationSweepJobTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Confirms the periodic write-back
  keeps `cms_accounts.open_to_buy`/`cash_open_to_buy` in sync with active
  holds, and — the actual reason this job's population is an exclusion list
  rather than an inclusion list — that CLOSED/WRITTEN_OFF accounts are left
  alone (an inclusion list keyed on "ACTIVE" would silently un-zero a
  written-off account's OTB back to its full limit on the very next sweep).
  """

  use VmuCore.DataCase, async: false

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.CMS.{Account, Oban.OtbReconciliationSweepJob}
  alias VmuCore.FAS.{AuthorizationRecord, PendingHold}
  alias VmuCore.Shared.Customer
  alias Decimal, as: D

  defp pan_token(pan), do: :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)

  defp seed_account(credit_limit, status \\ "ACTIVE", open_to_buy \\ nil) do
    {:ok, customer} =
      Repo.insert(Customer.changeset(%Customer{}, %{
        sys_id: "0001", bank_id: "0010", first_name: "Test", last_name: "SweepFixture"
      }))

    # "WRITTEN_OFF" isn't in Account.changeset/2's own @valid_statuses list
    # (real, pre-existing: COL.WriteOffProcessor sets it via Repo.update_all,
    # which bypasses the changeset validation entirely - the DB column
    # accepts it, the changeset's inclusion list is just stale). Insert as
    # ACTIVE via the changeset, then force the real status the same way
    # WriteOffProcessor does, so this fixture matches how the status
    # actually gets set in production rather than what the changeset alone
    # would allow.
    {:ok, account} =
      Repo.insert(Account.changeset(%Account{}, %{
        customer_id:    customer.customer_id,
        sys_id:         "0001",
        bank_id:        "0010",
        logo_id:        "0100",
        block_id:       "1000",
        pan_token:      pan_token("543210#{System.unique_integer([:positive])}"),
        last_four:      "1234",
        expiry_date:    "1228",
        credit_limit:   credit_limit,
        open_to_buy:    open_to_buy || credit_limit,
        account_status: "ACTIVE"
      }))

    if status != "ACTIVE" do
      Repo.update_all(from(a in Account, where: a.account_id == ^account.account_id),
        set: [account_status: status])
    end

    %{account | account_status: status}
  end

  defp seed_active_hold(account, amount) do
    {:ok, auth} =
      Repo.insert(AuthorizationRecord.changeset(%AuthorizationRecord{}, %{
        pan_token: account.pan_token, account_id: account.account_id, amount: amount,
        currency: "AED", channel: "pos", mcc: "5411", mti: "0100", rc: "00"
      }))

    {:ok, hold} =
      Repo.insert(PendingHold.changeset(%PendingHold{}, %{
        fas_authorization_id: auth.id, account_id: account.account_id, hold_amount: amount,
        hold_type: "standard", expires_at: DateTime.add(DateTime.utc_now(), 7, :day)
      }))

    hold
  end

  defp perform_job(worker, args \\ %{}), do: worker.perform(%Oban.Job{args: args})

  test "an active hold is written back into open_to_buy" do
    account = seed_account(D.new("5000.00"))
    seed_active_hold(account, D.new("300.00"))

    assert :ok = perform_job(OtbReconciliationSweepJob)

    reloaded = Repo.get!(Account, account.account_id)
    assert D.equal?(reloaded.open_to_buy, D.new("4700.00"))
  end

  test "a CLOSED account's zeroed open_to_buy is left untouched even with no active holds" do
    account = seed_account(D.new("5000.00"), "CLOSED", D.new("0.00"))

    assert :ok = perform_job(OtbReconciliationSweepJob)

    reloaded = Repo.get!(Account, account.account_id)
    assert D.equal?(reloaded.open_to_buy, D.new("0.00"))
  end

  test "a WRITTEN_OFF account's zeroed open_to_buy is left untouched" do
    account = seed_account(D.new("5000.00"), "WRITTEN_OFF", D.new("0.00"))
    seed_active_hold(account, D.new("2000.00"))

    assert :ok = perform_job(OtbReconciliationSweepJob)

    reloaded = Repo.get!(Account, account.account_id)
    assert D.equal?(reloaded.open_to_buy, D.new("0.00"))
  end

  test "a DELINQUENT account IS reconciled (write-off GL-accuracy depends on this)" do
    account = seed_account(D.new("5000.00"), "DELINQUENT")
    seed_active_hold(account, D.new("1200.00"))

    assert :ok = perform_job(OtbReconciliationSweepJob)

    reloaded = Repo.get!(Account, account.account_id)
    assert D.equal?(reloaded.open_to_buy, D.new("3800.00"))
  end

  test "a BLOCKED account IS reconciled" do
    account = seed_account(D.new("5000.00"), "BLOCKED")
    seed_active_hold(account, D.new("500.00"))

    assert :ok = perform_job(OtbReconciliationSweepJob)

    reloaded = Repo.get!(Account, account.account_id)
    assert D.equal?(reloaded.open_to_buy, D.new("4500.00"))
  end

  test "running the sweep twice is idempotent" do
    account = seed_account(D.new("5000.00"))
    seed_active_hold(account, D.new("400.00"))

    assert :ok = perform_job(OtbReconciliationSweepJob)
    assert :ok = perform_job(OtbReconciliationSweepJob)

    reloaded = Repo.get!(Account, account.account_id)
    assert D.equal?(reloaded.open_to_buy, D.new("4600.00"))
  end
end
