defmodule VmuCore.CMS.OtbReconciliationTest do
  @moduledoc """
  Unit tests for `OtbReconciliation.reconstruct/1` — the boot-time OTB
  reconstruction that makes `AccountStateCoordinator` crash/restart-durable.
  """

  use VmuCore.DataCase, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{Account, OtbReconciliation}
  alias VmuCore.FAS.{AuthorizationRecord, PendingHold}
  alias VmuCore.Shared.Customer
  alias Decimal, as: D

  defp pan_token(pan), do: :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)

  defp seed_account(credit_limit, cash_limit \\ nil) do
    {:ok, customer} =
      Repo.insert(Customer.changeset(%Customer{}, %{
        sys_id: "0001", bank_id: "0010", first_name: "Test", last_name: "OtbFixture"
      }))

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
        cash_limit:     cash_limit,
        account_status: "ACTIVE"
      }))

    account
  end

  defp seed_authorization(account, amount, channel \\ "pos", mcc \\ "5411") do
    {:ok, record} =
      Repo.insert(AuthorizationRecord.changeset(%AuthorizationRecord{}, %{
        pan_token:  account.pan_token,
        account_id: account.account_id,
        amount:     amount,
        currency:   "AED",
        channel:    channel,
        mcc:        mcc,
        mti:        "0100",
        rc:         "00"
      }))

    record
  end

  defp seed_hold(account, auth_record, amount, opts \\ []) do
    {:ok, hold} =
      Repo.insert(PendingHold.changeset(%PendingHold{}, %{
        fas_authorization_id: auth_record.id,
        account_id:           account.account_id,
        hold_amount:          amount,
        hold_type:            Keyword.get(opts, :hold_type, "standard"),
        expires_at:           Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 7, :day)),
        cleared_at:           Keyword.get(opts, :cleared_at),
        reversal_at:          Keyword.get(opts, :reversal_at)
      }))

    hold
  end

  describe "reconstruct/1" do
    test "an account with no holds reconstructs to the full credit limit" do
      account = seed_account(D.new("5000.00"))

      assert %{open_to_buy: otb, cash_open_to_buy: nil} = OtbReconciliation.reconstruct(account)
      assert D.equal?(otb, D.new("5000.00"))
    end

    test "one active hold reduces open_to_buy by exactly its amount" do
      account = seed_account(D.new("5000.00"))
      auth = seed_authorization(account, D.new("300.00"))
      seed_hold(account, auth, D.new("300.00"))

      assert %{open_to_buy: otb} = OtbReconciliation.reconstruct(account)
      assert D.equal?(otb, D.new("4700.00"))
    end

    test "a cleared hold is excluded from the reconstruction" do
      account = seed_account(D.new("5000.00"))
      auth = seed_authorization(account, D.new("300.00"))
      seed_hold(account, auth, D.new("300.00"), cleared_at: DateTime.utc_now())

      assert %{open_to_buy: otb} = OtbReconciliation.reconstruct(account)
      assert D.equal?(otb, D.new("5000.00"))
    end

    test "a reversed hold is excluded from the reconstruction" do
      account = seed_account(D.new("5000.00"))
      auth = seed_authorization(account, D.new("300.00"))
      seed_hold(account, auth, D.new("300.00"), reversal_at: DateTime.utc_now())

      assert %{open_to_buy: otb} = OtbReconciliation.reconstruct(account)
      assert D.equal?(otb, D.new("5000.00"))
    end

    test "an expired-but-unswept hold still counts as active (matches live OTB behavior)" do
      account = seed_account(D.new("5000.00"))
      auth = seed_authorization(account, D.new("300.00"))
      seed_hold(account, auth, D.new("300.00"), expires_at: DateTime.add(DateTime.utc_now(), -30, :day))

      assert %{open_to_buy: otb} = OtbReconciliation.reconstruct(account)
      assert D.equal?(otb, D.new("4700.00"))
    end

    test "a cash-channel (ATM) hold reduces both open_to_buy and cash_open_to_buy" do
      account = seed_account(D.new("5000.00"), D.new("1000.00"))
      auth = seed_authorization(account, D.new("200.00"), "atm")
      seed_hold(account, auth, D.new("200.00"))

      assert %{open_to_buy: otb, cash_open_to_buy: cash_otb} = OtbReconciliation.reconstruct(account)
      assert D.equal?(otb, D.new("4800.00"))
      assert D.equal?(cash_otb, D.new("800.00"))
    end

    test "a cash-MCC hold reduces cash_open_to_buy even on a non-ATM channel" do
      account = seed_account(D.new("5000.00"), D.new("1000.00"))
      auth = seed_authorization(account, D.new("150.00"), "pos", "6011")
      seed_hold(account, auth, D.new("150.00"))

      assert %{cash_open_to_buy: cash_otb} = OtbReconciliation.reconstruct(account)
      assert D.equal?(cash_otb, D.new("850.00"))
    end

    test "a non-cash hold does not reduce cash_open_to_buy" do
      account = seed_account(D.new("5000.00"), D.new("1000.00"))
      auth = seed_authorization(account, D.new("300.00"), "pos", "5411")
      seed_hold(account, auth, D.new("300.00"))

      assert %{open_to_buy: otb, cash_open_to_buy: cash_otb} = OtbReconciliation.reconstruct(account)
      assert D.equal?(otb, D.new("4700.00"))
      assert D.equal?(cash_otb, D.new("1000.00"))
    end

    test "cash_limit: nil yields cash_open_to_buy: nil regardless of holds" do
      account = seed_account(D.new("5000.00"), nil)
      auth = seed_authorization(account, D.new("200.00"), "atm")
      seed_hold(account, auth, D.new("200.00"))

      assert %{cash_open_to_buy: nil} = OtbReconciliation.reconstruct(account)
    end
  end
end
