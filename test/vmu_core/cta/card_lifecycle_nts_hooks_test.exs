defmodule VmuCore.CTA.CardLifecycleNtsHooksTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Network Tokenization Service
  Phase A (2026-07-29) — proves `CTA.CardLifecycle`'s block/unblock/
  replace/renew hooks keep a card's provisioned wallet tokens in sync,
  exercised against a local accepting test TSP adapter (same override
  style as `NTS.TokenLifecycleTest`). See the NTS implementation plan.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.Account
  alias VmuCore.CTA.{Card, CardLifecycle}
  alias VmuCore.NTS.{Tokens, TokenLifecycle}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, ModuleConfigWriter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Application.put_env(:vmu_core, :tsp_provider, __MODULE__.AcceptingTsp)
    on_exit(fn -> Application.delete_env(:vmu_core, :tsp_provider) end)
    :ok
  end

  defmodule AcceptingTsp do
    @behaviour VmuCore.NTS.TokenServiceProvider
    @impl true
    def provision_token(_card, _device_info, _wallet), do: {:ok, %{token_reference_id: "REF", dpan: "4111000000005678", status: "ACTIVE"}}
    @impl true
    def suspend_token(_token), do: {:ok, %{}}
    @impl true
    def resume_token(_token), do: {:ok, %{}}
    @impl true
    def delete_token(_token), do: {:ok, %{}}
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

    {:ok, _} =
      ModuleConfigWriter.put("cta", "wallet_tokenization_mode", "scheme_token",
        %{scope_type: "logo", sys_id: sys_id, bank_id: bank_id, logo_id: logo_id}, nil)

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Nts", last_name: "Hooks#{n}", id_type: "PASSPORT", id_number: "NTSH-#{n}"})
      |> Repo.insert!()

    account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
        block_id: block_id, pan_token: "ntsh-existing-pan-#{n}", last_four: "0000",
        expiry_date: "1230", credit_limit: D.new("5000.00"), emboss_name: "NTS HOOKS#{n}"
      })
      |> Repo.insert!()

    {:ok, card} = CardLifecycle.issue_new(account, activate: true)
    card
  end

  test "block/3 suspends every live token for the card" do
    card = card_fixture()
    {:ok, token} = TokenLifecycle.provision(card, %{}, "GOOGLE_PAY")

    assert {:ok, _} = CardLifecycle.block(card.card_id, "LOST")
    assert Tokens.get(token.token_id).status == "SUSPENDED"
  end

  test "unblock/2 resumes every suspended token for the card" do
    card = card_fixture()
    {:ok, token} = TokenLifecycle.provision(card, %{}, "GOOGLE_PAY")
    {:ok, _} = CardLifecycle.block(card.card_id, "LOST")

    assert {:ok, _} = CardLifecycle.unblock(card.card_id)
    assert Tokens.get(token.token_id).status == "ACTIVE"
  end

  test "replace/3 with a genuine PAN change deletes the old card's tokens" do
    card = card_fixture()
    {:ok, token} = TokenLifecycle.provision(card, %{}, "GOOGLE_PAY")
    new_pan = :crypto.hash(:sha256, "replacement-pan-#{System.unique_integer()}") |> Base.encode16(case: :lower)

    assert {:ok, %{new: new_card}} =
             CardLifecycle.replace(card.card_id, "LOST", new_pan_token: new_pan, new_last_four: "9999")

    assert Tokens.get(token.token_id).status == "DELETED"
    assert Tokens.list_for_card(new_card.card_id) == []
  end

  test "replace/3 with the same PAN (DAMAGED) migrates tokens to the new card generation instead of deleting them" do
    card = card_fixture()
    {:ok, token} = TokenLifecycle.provision(card, %{}, "GOOGLE_PAY")

    assert {:ok, %{new: new_card}} = CardLifecycle.replace(card.card_id, "DAMAGED")

    reloaded = Tokens.get(token.token_id)
    assert reloaded.status == "ACTIVE"
    assert reloaded.card_id == new_card.card_id
  end

  test "renew/2 migrates tokens to the new card generation without any TSP call" do
    card = card_fixture()
    {:ok, token} = TokenLifecycle.provision(card, %{}, "GOOGLE_PAY")

    assert {:ok, %{new: new_card}} = CardLifecycle.renew(card.card_id)

    reloaded = Tokens.get(token.token_id)
    assert reloaded.status == "ACTIVE"
    assert reloaded.card_id == new_card.card_id
  end
end
