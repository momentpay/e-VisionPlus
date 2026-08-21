defmodule VmuCore.CTA.CardLifecycleIssueTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking — covers `issue_new/2` and
  `issue_virtual_with_credentials/2` (Way4 parity plan Phase 1 item 1,
  2026-07-25), the first real callers of `PanGenerator`/`CredentialVault`.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.Account
  alias VmuCore.CTA.{Card, CardLifecycle, CredentialVault}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp account_fixture do
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
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Issue", last_name: "Test#{n}",
        id_type: "PASSPORT", id_number: "ISSUE-TEST-#{n}"
      })
      |> Repo.insert!()

    %Account{}
    |> Account.changeset(%{
      customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
      block_id: block_id, pan_token: "existing-pan-token-#{n}", last_four: "0000",
      expiry_date: "1230", credit_limit: D.new("5000.00"), emboss_name: "ISSUE TEST#{n}"
    })
    |> Repo.insert!()
  end

  describe "issue_new/2" do
    test "issues an INACTIVE generation-1 card with a real, freshly-generated PAN" do
      account = account_fixture()

      assert {:ok, card} = CardLifecycle.issue_new(account)

      assert card.account_id == account.account_id
      assert card.card_type == "PRIMARY"
      assert card.status == "INACTIVE"
      assert card.generation == 1
      assert card.emboss_name == account.emboss_name
      refute card.pan_token == account.pan_token
    end

    test "respects :card_type and :emboss_name opts" do
      account = account_fixture()

      assert {:ok, card} = CardLifecycle.issue_new(account, card_type: "SUPPLEMENTARY", emboss_name: "J SMITH")

      assert card.card_type == "SUPPLEMENTARY"
      assert card.emboss_name == "J SMITH"
    end

    test "expiry uses the LOGO's real card_validity_years" do
      account = account_fixture()
      {:ok, card} = CardLifecycle.issue_new(account)

      expected_year = rem(Date.utc_today().year + 4, 100) |> Integer.to_string() |> String.pad_leading(2, "0")
      assert String.ends_with?(card.expiry, expected_year)
    end

    test ":activate true chains into activate/2, stamping activated_at and syncing the account" do
      account = account_fixture()

      assert {:ok, card} = CardLifecycle.issue_new(account, activate: true)
      assert card.status == "ACTIVE"
      assert card.activated_at

      reloaded_account = Repo.get!(Account, account.account_id)
      assert reloaded_account.pan_token == card.pan_token
    end

    test "an invalid card_type is rejected" do
      account = account_fixture()
      assert {:error, {:invalid_card_type, "DEBIT"}} = CardLifecycle.issue_new(account, card_type: "DEBIT")
    end

    test "an unknown LOGO is a clean error" do
      account = account_fixture()
      bad_account = %{account | logo_id: "NOPE"}
      assert {:error, :logo_not_found} = CardLifecycle.issue_new(bad_account)
    end
  end

  describe "issue_virtual_with_credentials/2" do
    test "issues, activates, and vaults real one-time-reveal credentials" do
      account = account_fixture()

      assert {:ok, card} = CardLifecycle.issue_virtual_with_credentials(account)

      assert card.card_type == "VIRTUAL"
      assert card.status == "ACTIVE"

      assert {:ok, %{pan: pan, cvv: cvv, expiry: expiry}} = CredentialVault.reveal(card.card_id)
      assert String.length(pan) == 16
      assert String.length(cvv) == 3
      assert expiry == card.expiry

      # Exactly-once — the same card_id can't be revealed twice.
      assert {:error, :not_found} = CredentialVault.reveal(card.card_id)
    end

    test "the vaulted PAN's token matches the persisted card's pan_token" do
      account = account_fixture()
      {:ok, card} = CardLifecycle.issue_virtual_with_credentials(account)

      {:ok, %{pan: raw_pan}} = CredentialVault.reveal(card.card_id)
      assert :crypto.hash(:sha256, raw_pan) |> Base.encode16(case: :lower) == card.pan_token
    end
  end
end
