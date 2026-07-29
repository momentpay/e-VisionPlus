defmodule VmuCore.NTS.TokensTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Network Tokenization Service
  Phase A (2026-07-29) — `NTS.Tokens` context unit tests. See
  docs/wallet/WALLET_Module_Requirements.md and the NTS implementation
  plan.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.Account
  alias VmuCore.CTA.{Card, CardLifecycle}
  alias VmuCore.NTS.Tokens
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp card_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test", card_validity_years: 4}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Nts", last_name: "Test#{n}", id_type: "PASSPORT", id_number: "NTS-#{n}"})
      |> Repo.insert!()

    account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
        block_id: block_id, pan_token: "nts-existing-pan-#{n}", last_four: "0000",
        expiry_date: "1230", credit_limit: D.new("5000.00"), emboss_name: "NTS TEST#{n}"
      })
      |> Repo.insert!()

    {:ok, card} = CardLifecycle.issue_new(account, activate: true)
    card
  end

  test "create/1 defaults to status PENDING" do
    card = card_fixture()
    assert {:ok, token} = Tokens.create(%{"card_id" => card.card_id, "scheme" => "MASTERCARD", "wallet" => "GOOGLE_PAY"})
    assert token.status == "PENDING"
  end

  test "transition/2 walks PENDING -> ACTIVE -> SUSPENDED -> ACTIVE -> DELETED, stamping timestamps" do
    card = card_fixture()
    {:ok, token} = Tokens.create(%{"card_id" => card.card_id, "scheme" => "MASTERCARD", "wallet" => "GOOGLE_PAY"})

    assert {:ok, active} = Tokens.transition(token, "ACTIVE")
    assert active.status == "ACTIVE"
    assert active.provisioned_at

    assert {:ok, suspended} = Tokens.transition(active, "SUSPENDED")
    assert suspended.suspended_at

    assert {:ok, resumed} = Tokens.transition(suspended, "ACTIVE")
    assert resumed.provisioned_at == active.provisioned_at

    assert {:ok, deleted} = Tokens.transition(resumed, "DELETED")
    assert deleted.status == "DELETED"
    assert deleted.deleted_at
  end

  test "transition/2 rejects an invalid transition instead of silently no-op-ing" do
    card = card_fixture()
    {:ok, token} = Tokens.create(%{"card_id" => card.card_id, "scheme" => "MASTERCARD", "wallet" => "GOOGLE_PAY"})

    assert {:error, :invalid_transition} = Tokens.transition(token, "SUSPENDED")
  end

  test "by_dpan/1 finds a token by its cleartext DPAN" do
    card = card_fixture()
    {:ok, token} = Tokens.create(%{"card_id" => card.card_id, "scheme" => "MASTERCARD", "wallet" => "GOOGLE_PAY", "dpan" => "4111000000009999"})

    found = Tokens.by_dpan("4111000000009999")
    assert found.token_id == token.token_id
  end

  test "list_for_card/1 excludes DELETED tokens" do
    card = card_fixture()
    {:ok, live} = Tokens.create(%{"card_id" => card.card_id, "scheme" => "MASTERCARD", "wallet" => "GOOGLE_PAY"})
    {:ok, dead} = Tokens.create(%{"card_id" => card.card_id, "scheme" => "MASTERCARD", "wallet" => "GOOGLE_PAY"})
    {:ok, _} = Tokens.transition(dead, "DELETED")

    ids = Tokens.list_for_card(card.card_id) |> Enum.map(& &1.token_id)
    assert live.token_id in ids
    refute dead.token_id in ids
  end

  test "migrate_card_id/2 re-points live tokens without any status change" do
    card = card_fixture()
    other_card = card_fixture()
    {:ok, token} = Tokens.create(%{"card_id" => card.card_id, "scheme" => "MASTERCARD", "wallet" => "GOOGLE_PAY"})

    Tokens.migrate_card_id(card.card_id, other_card.card_id)

    reloaded = Tokens.get(token.token_id)
    assert reloaded.card_id == other_card.card_id
    assert reloaded.status == "PENDING"
  end
end
