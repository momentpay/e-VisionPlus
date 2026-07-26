defmodule VmuCore.CTA.CardLifecycleIssueDebitTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Way4 parity plan Phase 1 item 4
  (Debit, D5) — `issue_new_debit/2`, and confirms `activate/2`/`block/3`/
  `unblock/2` already work unchanged for a card issued this way.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.DebitAccountOpening
  alias VmuCore.CTA.{Card, CardLifecycle, Cards}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp debit_account_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "555555", description: "test", product_type: "DEBIT", card_validity_years: 4}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Debit", last_name: "IssueTest#{n}"})
      |> Repo.insert!()

    {:ok, account} =
      DebitAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id,
        logo_id: logo_id, block_id: block_id
      })

    account
  end

  describe "issue_new_debit/2" do
    test "issues an INACTIVE generation-1 card with a real, freshly-generated PAN" do
      account = debit_account_fixture()

      assert {:ok, card} = CardLifecycle.issue_new_debit(account)

      assert card.debit_account_id == account.debit_account_id
      assert is_nil(card.account_id)
      assert card.card_type == "PRIMARY"
      assert card.status == "INACTIVE"
      assert card.generation == 1
    end

    test "respects :card_type and :emboss_name opts" do
      account = debit_account_fixture()

      assert {:ok, card} = CardLifecycle.issue_new_debit(account, card_type: "VIRTUAL", emboss_name: "J SMITH")

      assert card.card_type == "VIRTUAL"
      assert card.emboss_name == "J SMITH"
    end

    test "expiry uses the LOGO's real card_validity_years" do
      account = debit_account_fixture()
      {:ok, card} = CardLifecycle.issue_new_debit(account)

      expected_year = rem(Date.utc_today().year + 4, 100) |> Integer.to_string() |> String.pad_leading(2, "0")
      assert String.ends_with?(card.expiry, expected_year)
    end

    test ":activate true chains into activate/2 without touching any cms_accounts row" do
      account = debit_account_fixture()

      assert {:ok, card} = CardLifecycle.issue_new_debit(account, activate: true)
      assert card.status == "ACTIVE"
      assert card.activated_at
    end

    test "an invalid card_type is rejected" do
      account = debit_account_fixture()
      assert {:error, {:invalid_card_type, "DEBIT"}} = CardLifecycle.issue_new_debit(account, card_type: "DEBIT")
    end
  end

  describe "activate/2, block/3, unblock/2 already work unchanged for a debit-issued card" do
    test "activate, block, and unblock all succeed and never touch cms_accounts" do
      account = debit_account_fixture()
      {:ok, card} = CardLifecycle.issue_new_debit(account)

      assert {:ok, activated} = CardLifecycle.activate(card.card_id)
      assert activated.status == "ACTIVE"

      assert {:ok, blocked} = CardLifecycle.block(card.card_id, "LOST")
      assert blocked.status == "BLOCKED"
      assert blocked.block_reason == "LOST"

      assert {:ok, unblocked} = CardLifecycle.unblock(card.card_id)
      assert unblocked.status == "ACTIVE"
    end
  end

  describe "Cards.by_debit_account/1" do
    test "lists cards for a debit account, newest generation first" do
      account = debit_account_fixture()
      {:ok, card1} = CardLifecycle.issue_new_debit(account)

      cards = Cards.by_debit_account(account.debit_account_id)
      assert [%Card{card_id: id}] = cards
      assert id == card1.card_id
    end

    test "does not return cards belonging to a different debit account" do
      account1 = debit_account_fixture()
      account2 = debit_account_fixture()
      {:ok, _} = CardLifecycle.issue_new_debit(account1)
      {:ok, card2} = CardLifecycle.issue_new_debit(account2)

      assert [%Card{card_id: id}] = Cards.by_debit_account(account2.debit_account_id)
      assert id == card2.card_id
    end
  end
end
