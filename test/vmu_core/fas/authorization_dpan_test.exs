defmodule VmuCore.FAS.AuthorizationDpanTest do
  @moduledoc """
  End-to-end proof that a synthetic DPAN-bearing transaction resolves to
  the correct account through `FAS.Authorization.process/1` — NTS Phase D
  (2026-08-01). Real Postgres, real ETS (`FAS.DpanCache`/`ParameterEngine`
  tables), no mocking.

  Uses the raw-ETS-insert style `authorization_integration_test.exs`
  already established for `:vmu_parameter_cache` (a real, already-running
  GenServer's table — this simulates "MDES's real token BIN range has
  been registered," a real, still-open data gap this test deliberately
  works around to isolate what Phase D's own code is responsible for).
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.FAS.{Authorization, DpanCache}
  alias VmuCore.CMS.Account
  alias VmuCore.CTA.Cards
  alias VmuCore.NTS.Tokens
  alias VmuCore.Shared.Customer

  @param_table :vmu_parameter_cache

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp seed_bin(sys_id, bank_id, logo_id, block_id, bin_prefix) do
    if :ets.whereis(@param_table) == :undefined do
      :ets.new(@param_table, [:named_table, :set, :public, {:read_concurrency, true}])
    end

    :ets.insert(@param_table, {{:sys, sys_id, :base_currency}, "AED"})
    :ets.insert(@param_table, {{:bank, sys_id, bank_id, :country_code}, "ARE"})
    :ets.insert(@param_table, {{:logo, sys_id, bank_id, logo_id, :bin_prefix}, bin_prefix})
    :ets.insert(@param_table, {{:logo, sys_id, bank_id, logo_id, :description}, "DPAN test logo"})
    :ets.insert(@param_table, {{:block, sys_id, bank_id, logo_id, block_id, :apr_percentage}, Decimal.new("24.00")})
    :ets.insert(@param_table, {{:block, sys_id, bank_id, logo_id, block_id, :credit_limit_default}, Decimal.new("5000.00")})
  end

  defp pan_token(pan), do: :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)

  defp fixture(credit_limit \\ Decimal.new("500.00"), account_status \\ "ACTIVE") do
    n = System.unique_integer([:positive])
    sys_id = "D#{100 + rem(n, 900)}"
    bank_id = "E#{100 + rem(n, 900)}"
    logo_id = "F#{100 + rem(n, 900)}"
    block_id = "G#{100 + rem(n, 900)}"
    # bin_prefix must be exactly 6 chars — ParameterEngine.resolve_bin/1
    # does an exact match against String.slice(pan, 0, 6).
    bin_prefix = "77" <> to_string(1000 + rem(n, 9000))
    dpan = bin_prefix <> "0000000#{rem(n, 10)}"
    real_pan = bin_prefix <> "1111111#{rem(n, 10)}"

    seed_bin(sys_id, bank_id, logo_id, block_id, bin_prefix)

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "AuthDpan", last_name: "Test#{n}"})
      |> Repo.insert!()

    account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
        block_id: block_id, pan_token: pan_token(real_pan), last_four: "0000",
        expiry_date: "1230", credit_limit: credit_limit, open_to_buy: credit_limit,
        emboss_name: "AUTH DPAN#{n}", account_status: account_status
      })
      |> Repo.insert!()

    # Cards.issue/1 directly (not CardLifecycle.issue_new/2) — the latter's
    # PanGenerator needs a real Shared.LogoParameter DB row, a separate
    # mechanism from the ETS :vmu_parameter_cache table this file seeds
    # for FAS's own BIN resolution; authorization_integration_test.exs's
    # own fixtures make the same choice for the same reason.
    {:ok, card} =
      Cards.issue(%{
        account_id: account.account_id, pan_token: pan_token(real_pan),
        card_type: "PRIMARY", status: "ACTIVE"
      })

    {:ok, token} = Tokens.create(%{"card_id" => card.card_id, "scheme" => "MASTERCARD", "wallet" => "GOOGLE_PAY", "dpan" => dpan})
    {:ok, _} = Tokens.transition(token, "ACTIVE")
    :ok = DpanCache.refresh()

    {dpan, account}
  end

  test "a DPAN transaction approves against the real underlying account's OTB" do
    {dpan, _account} = fixture(Decimal.new("500.00"))

    request = %{pan: dpan, amount: Decimal.new("100.00"), channel: :pos, mcc: "5411"}
    assert {:ok, "00", approval_code} = Authorization.process(request)
    assert Regex.match?(~r/^\d{6}$/, approval_code)
  end

  test "a DPAN transaction declines when it exceeds the underlying account's OTB (RC 51)" do
    {dpan, _account} = fixture(Decimal.new("50.00"))

    request = %{pan: dpan, amount: Decimal.new("500.00"), channel: :pos, mcc: "5411"}
    assert {:error, "51"} = Authorization.process(request)
  end

  test "a DPAN whose underlying account is blocked declines (RC 14 — treated as unresolvable)" do
    {dpan, account} = fixture(Decimal.new("500.00"))
    account |> Account.changeset(%{block_code: "F"}) |> Repo.update!()
    :ok = DpanCache.refresh()

    request = %{pan: dpan, amount: Decimal.new("50.00"), channel: :pos, mcc: "5411"}
    assert {:error, "14"} = Authorization.process(request)
  end

  test "an unknown DPAN (never tokenized) still falls through to real-PAN resolution and declines cleanly" do
    n = System.unique_integer([:positive])
    sys_id = "D#{100 + rem(n, 900)}"
    bank_id = "E#{100 + rem(n, 900)}"
    logo_id = "F#{100 + rem(n, 900)}"
    block_id = "G#{100 + rem(n, 900)}"
    bin_prefix = "78" <> to_string(1000 + rem(n, 9000))
    seed_bin(sys_id, bank_id, logo_id, block_id, bin_prefix)

    request = %{pan: bin_prefix <> "9999999", amount: Decimal.new("50.00"), channel: :pos, mcc: "5411"}
    assert {:error, "14"} = Authorization.process(request)
  end
end
