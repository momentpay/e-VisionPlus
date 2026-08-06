defmodule VmuCore.CMS.Oban.PrepaidExpiryJobTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking (Oban runs `:inline` in test env
  — see `config/test.exs`). Way4 parity plan Phase 1 item 5 (Prepaid,
  P5) — the daily expiry sweep.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.GLFixtures
  alias VmuCore.CMS.{Oban.PrepaidExpiryJob, PrepaidAccountOpening, PrepaidLedger, PrepaidLedgerEntry}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp prepaid_account_fixture do
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
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "606060", description: "test", product_type: "PREPAID"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Prepaid", last_name: "ExpiryTest#{n}"})
      |> Repo.insert!()

    {:ok, account} =
      PrepaidAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id,
        logo_id: logo_id, block_id: block_id
      })

    account
  end

  test "an expired load is removed from the balance and a real EXPIRE entry is posted" do
    account = prepaid_account_fixture()
    yesterday = Date.add(Date.utc_today(), -1)

    {:ok, %{load_entry: load}} =
      PrepaidLedger.load(%{
        prepaid_account_id: account.prepaid_account_id, amount: D.new("80.00"),
        channel: "ADMIN_MANUAL", posted_by: "op1", expiry_date: yesterday
      })

    assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new("80.00"))

    assert :ok = perform_job(PrepaidExpiryJob, %{})

    assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new(0))

    reloaded_load = Repo.get!(PrepaidLedgerEntry, load.id)
    assert reloaded_load.status == "EXPIRED"

    expire_entry = Repo.get_by!(PrepaidLedgerEntry, prepaid_account_id: account.prepaid_account_id, entry_type: "EXPIRE")
    assert D.equal?(expire_entry.amount, D.new("80.00"))
  end

  test "a load with a future expiry_date is left untouched" do
    account = prepaid_account_fixture()
    tomorrow = Date.add(Date.utc_today(), 1)

    {:ok, _} =
      PrepaidLedger.load(%{
        prepaid_account_id: account.prepaid_account_id, amount: D.new("50.00"),
        channel: "ADMIN_MANUAL", posted_by: "op1", expiry_date: tomorrow
      })

    assert :ok = perform_job(PrepaidExpiryJob, %{})
    assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new("50.00"))
  end

  test "a load with no expiry_date is never expired" do
    account = prepaid_account_fixture()

    {:ok, _} =
      PrepaidLedger.load(%{
        prepaid_account_id: account.prepaid_account_id, amount: D.new("30.00"),
        channel: "ADMIN_MANUAL", posted_by: "op1"
      })

    assert :ok = perform_job(PrepaidExpiryJob, %{})
    assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new("30.00"))
  end

  test "a partially-spent expired load only expires its actual remaining_amount" do
    account = prepaid_account_fixture()
    yesterday = Date.add(Date.utc_today(), -1)

    {:ok, %{load_entry: load}} =
      PrepaidLedger.load(%{
        prepaid_account_id: account.prepaid_account_id, amount: D.new("100.00"),
        channel: "ADMIN_MANUAL", posted_by: "op1", expiry_date: yesterday
      })

    # Directly simulate a partial spend having already reduced remaining_amount
    # (spend/3 itself won't consume an already-past-expiry load — this
    # models a load that was spent against before its expiry date passed).
    load |> PrepaidLedgerEntry.changeset(%{}) |> Ecto.Changeset.change(remaining_amount: D.new("40.00")) |> Repo.update!()

    assert :ok = perform_job(PrepaidExpiryJob, %{})

    expire_entry = Repo.get_by!(PrepaidLedgerEntry, prepaid_account_id: account.prepaid_account_id, entry_type: "EXPIRE")
    assert D.equal?(expire_entry.amount, D.new("40.00"))
  end

  test "running the sweep twice does not double-post the EXPIRE entry (idempotent)" do
    account = prepaid_account_fixture()
    yesterday = Date.add(Date.utc_today(), -1)

    {:ok, _} =
      PrepaidLedger.load(%{
        prepaid_account_id: account.prepaid_account_id, amount: D.new("20.00"),
        channel: "ADMIN_MANUAL", posted_by: "op1", expiry_date: yesterday
      })

    assert :ok = perform_job(PrepaidExpiryJob, %{})
    assert :ok = perform_job(PrepaidExpiryJob, %{})

    count =
      Repo.aggregate(
        from(l in PrepaidLedgerEntry,
          where: l.prepaid_account_id == ^account.prepaid_account_id and l.entry_type == "EXPIRE"),
        :count
      )

    assert count == 1
  end

  defp perform_job(worker, args) do
    worker.perform(%Oban.Job{args: args})
  end
end
