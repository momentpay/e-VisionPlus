defmodule VmuCore.NTS.TokenLifecycleTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Network Tokenization Service
  Phase A (2026-07-29) — `NTS.TokenLifecycle`, exercised against the
  default `Stub` TSP provider (honest failure) and a local accepting
  test adapter (success path), same `Application.put_env(:vmu_core,
  :tsp_provider, ...)` override style already used for `:rail_provider`
  this session.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.CMS.Account
  alias VmuCore.CTA.{Card, CardLifecycle}
  alias VmuCore.NTS.{Token, Tokens, TokenLifecycle}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    on_exit(fn -> Application.delete_env(:vmu_core, :tsp_provider) end)
    :ok
  end

  defmodule AcceptingTsp do
    @behaviour VmuCore.NTS.TokenServiceProvider
    @impl true
    def provision_token(_card, _device_info, _wallet), do: {:ok, %{token_reference_id: "TSP-REF-1", dpan: "4111000000001234", status: "ACTIVE"}}
    @impl true
    def suspend_token(_token), do: {:ok, %{}}
    @impl true
    def resume_token(_token), do: {:ok, %{}}
    @impl true
    def delete_token(_token), do: {:ok, %{}}
  end

  defmodule DecliningTsp do
    @behaviour VmuCore.NTS.TokenServiceProvider
    @impl true
    def provision_token(_card, _device_info, _wallet), do: {:error, :issuer_declined}
    @impl true
    def suspend_token(_token), do: {:error, :network_error}
    @impl true
    def resume_token(_token), do: {:error, :network_error}
    @impl true
    def delete_token(_token), do: {:error, :network_error}
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
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Nts", last_name: "Lifecycle#{n}", id_type: "PASSPORT", id_number: "NTSL-#{n}"})
      |> Repo.insert!()

    account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
        block_id: block_id, pan_token: "ntsl-existing-pan-#{n}", last_four: "0000",
        expiry_date: "1230", credit_limit: D.new("5000.00"), emboss_name: "NTS LIFECYCLE#{n}"
      })
      |> Repo.insert!()

    {:ok, card} = CardLifecycle.issue_new(account, activate: true)
    card
  end

  describe "provision/4" do
    test "with no TSP configured (the real default), fails honestly and marks the token DELETED" do
      card = card_fixture()

      assert {:error, {:tsp_error, :tsp_not_configured}} =
               TokenLifecycle.provision(card, %{"device_id" => "dev1"}, "GOOGLE_PAY")

      [token] = Repo.all(from t in Token, where: t.card_id == ^card.card_id)
      assert token.status == "DELETED"
    end

    test "with an accepting TSP, activates the token with the real DPAN/reference" do
      Application.put_env(:vmu_core, :tsp_provider, AcceptingTsp)
      card = card_fixture()

      assert {:ok, token} = TokenLifecycle.provision(card, %{"device_id" => "dev1"}, "GOOGLE_PAY")
      assert token.status == "ACTIVE"
      assert token.dpan == "4111000000001234"
      assert token.token_reference_id == "TSP-REF-1"
    end
  end

  describe "suspend_for_card/2 and resume_for_card/2" do
    test "suspend then resume round-trips a token's status against an accepting TSP" do
      Application.put_env(:vmu_core, :tsp_provider, AcceptingTsp)
      card = card_fixture()
      {:ok, token} = TokenLifecycle.provision(card, %{}, "GOOGLE_PAY")

      :ok = TokenLifecycle.suspend_for_card(card.card_id)
      assert Tokens.get(token.token_id).status == "SUSPENDED"

      :ok = TokenLifecycle.resume_for_card(card.card_id)
      assert Tokens.get(token.token_id).status == "ACTIVE"
    end

    test "a TSP failure during suspend doesn't crash and leaves the token untouched" do
      Application.put_env(:vmu_core, :tsp_provider, AcceptingTsp)
      card = card_fixture()
      {:ok, token} = TokenLifecycle.provision(card, %{}, "GOOGLE_PAY")

      Application.put_env(:vmu_core, :tsp_provider, DecliningTsp)
      assert :ok = TokenLifecycle.suspend_for_card(card.card_id)

      assert Tokens.get(token.token_id).status == "ACTIVE"
    end
  end

  describe "delete_for_card/2" do
    test "deletes every live token for the card against an accepting TSP" do
      Application.put_env(:vmu_core, :tsp_provider, AcceptingTsp)
      card = card_fixture()
      {:ok, token} = TokenLifecycle.provision(card, %{}, "GOOGLE_PAY")

      :ok = TokenLifecycle.delete_for_card(card.card_id)
      assert Tokens.get(token.token_id).status == "DELETED"
    end
  end
end
