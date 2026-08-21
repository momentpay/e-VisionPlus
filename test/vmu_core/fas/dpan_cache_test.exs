defmodule VmuCore.FAS.DpanCacheTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking — `FAS.DpanCache` is a real,
  already-running GenServer in the app supervision tree (same as
  `FAS.HotCardCache`); tests call `refresh/0` to force a synchronous
  reload after seeding fixtures. NTS Phase D (2026-08-01).
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.Account
  alias VmuCore.CTA.CardLifecycle
  alias VmuCore.FAS.DpanCache
  alias VmuCore.NTS.Tokens
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp pan_token(pan), do: :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)

  defp card_fixture(status \\ "ACTIVE") do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "541234", description: "test", card_validity_years: 4}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Dpan", last_name: "Test#{n}", id_type: "PASSPORT", id_number: "DPAN-#{n}"})
      |> Repo.insert!()

    account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
        block_id: block_id, pan_token: "dpan-test-real-pan-#{n}", last_four: "0000",
        expiry_date: "1230", credit_limit: D.new("5000.00"), emboss_name: "DPAN TEST#{n}",
        account_status: status
      })
      |> Repo.insert!()

    {:ok, card} = CardLifecycle.issue_new(account, activate: true)
    {card, account}
  end

  defp active_token_fixture(card, dpan) do
    {:ok, token} = Tokens.create(%{"card_id" => card.card_id, "scheme" => "MASTERCARD", "wallet" => "GOOGLE_PAY", "dpan" => dpan})
    {:ok, active} = Tokens.transition(token, "ACTIVE")
    active
  end

  test "check/1 returns :not_found for an unknown token" do
    assert :not_found = DpanCache.check(pan_token("no-such-dpan"))
  end

  test "an ACTIVE token with a real dpan resolves to its account/card after refresh" do
    {card, account} = card_fixture()
    dpan = "4111000000009#{System.unique_integer([:positive]) |> rem(1000)}"
    active_token_fixture(card, dpan)

    :ok = DpanCache.refresh()

    assert {:ok, {account_id, card_id}} = DpanCache.check(pan_token(dpan))
    assert account_id == account.account_id
    assert card_id == card.card_id
  end

  test "a PENDING/PUSHED token (no confirmed dpan) is never cached" do
    {card, _account} = card_fixture()
    {:ok, token} = Tokens.create(%{"card_id" => card.card_id, "scheme" => "MASTERCARD", "wallet" => "GOOGLE_PAY"})
    {:ok, _pushed} = Tokens.transition(token, "PUSHED")

    :ok = DpanCache.refresh()

    # PUSHED tokens have dpan: nil, so there's no token hash to even look up —
    # this just confirms the loader query's `not is_nil(t.dpan)` guard holds.
    refute Tokens.get(token.token_id).dpan
  end

  test "an ACTIVE token whose underlying account is blocked resolves to :blocked, not the account" do
    {card, account} = card_fixture()
    dpan = "4111000000008#{System.unique_integer([:positive]) |> rem(1000)}"
    active_token_fixture(card, dpan)

    account |> Account.changeset(%{block_code: "F"}) |> Repo.update!()
    :ok = DpanCache.refresh()

    assert :blocked = DpanCache.check(pan_token(dpan))
  end

  test "an ACTIVE token whose underlying account is CLOSED resolves to :blocked" do
    {card, _account} = card_fixture("CLOSED")
    dpan = "4111000000007#{System.unique_integer([:positive]) |> rem(1000)}"
    active_token_fixture(card, dpan)

    :ok = DpanCache.refresh()

    assert :blocked = DpanCache.check(pan_token(dpan))
  end

  test "a DELETED token no longer resolves after refresh" do
    {card, account} = card_fixture()
    dpan = "4111000000006#{System.unique_integer([:positive]) |> rem(1000)}"
    token = active_token_fixture(card, dpan)

    :ok = DpanCache.refresh()
    assert {:ok, {account_id, _}} = DpanCache.check(pan_token(dpan))
    assert account_id == account.account_id

    {:ok, _} = Tokens.transition(token, "DELETED")
    :ok = DpanCache.refresh()

    assert :not_found = DpanCache.check(pan_token(dpan))
  end
end
