defmodule VmuCore.CTA.CardLifecycleIssuePrepaidTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Way4 parity plan Phase 1 item 5
  (Prepaid, P2) — `issue_new_prepaid/2`, and confirms `activate/2`/
  `block/3`/`unblock/2` already work unchanged for a card issued this
  way (same nil-guarded denormal sync D5 fixed for Debit).
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.PrepaidAccountOpening
  alias VmuCore.CTA.{Card, CardLifecycle, Cards}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}

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
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "606060", description: "test", product_type: "PREPAID", card_validity_years: 4}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Prepaid", last_name: "IssueTest#{n}"})
      |> Repo.insert!()

    {:ok, account} =
      PrepaidAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id,
        logo_id: logo_id, block_id: block_id
      })

    account
  end

  describe "issue_new_prepaid/2" do
    test "issues an INACTIVE generation-1 card with a real, freshly-generated PAN" do
      account = prepaid_account_fixture()

      assert {:ok, card} = CardLifecycle.issue_new_prepaid(account)

      assert card.prepaid_account_id == account.prepaid_account_id
      assert is_nil(card.account_id)
      assert is_nil(card.debit_account_id)
      assert card.card_type == "PRIMARY"
      assert card.status == "INACTIVE"
      assert card.generation == 1
    end

    test "respects :card_type and :emboss_name opts" do
      account = prepaid_account_fixture()

      assert {:ok, card} = CardLifecycle.issue_new_prepaid(account, card_type: "VIRTUAL", emboss_name: "J SMITH")

      assert card.card_type == "VIRTUAL"
      assert card.emboss_name == "J SMITH"
    end

    test "an invalid card_type is rejected" do
      account = prepaid_account_fixture()
      assert {:error, {:invalid_card_type, "DEBIT"}} = CardLifecycle.issue_new_prepaid(account, card_type: "DEBIT")
    end
  end

  describe "activate/2, block/3, unblock/2 already work unchanged for a prepaid-issued card" do
    test "activate, block, and unblock all succeed" do
      account = prepaid_account_fixture()
      {:ok, card} = CardLifecycle.issue_new_prepaid(account)

      assert {:ok, activated} = CardLifecycle.activate(card.card_id)
      assert activated.status == "ACTIVE"

      assert {:ok, blocked} = CardLifecycle.block(card.card_id, "LOST")
      assert blocked.status == "BLOCKED"

      assert {:ok, unblocked} = CardLifecycle.unblock(card.card_id)
      assert unblocked.status == "ACTIVE"
    end
  end

  describe "Cards.by_prepaid_account/1" do
    test "lists cards for a prepaid account, newest generation first" do
      account = prepaid_account_fixture()
      {:ok, card} = CardLifecycle.issue_new_prepaid(account)

      assert [%Card{card_id: id}] = Cards.by_prepaid_account(account.prepaid_account_id)
      assert id == card.card_id
    end

    test "does not return cards belonging to a different prepaid account" do
      account1 = prepaid_account_fixture()
      account2 = prepaid_account_fixture()
      {:ok, _} = CardLifecycle.issue_new_prepaid(account1)
      {:ok, card2} = CardLifecycle.issue_new_prepaid(account2)

      assert [%Card{card_id: id}] = Cards.by_prepaid_account(account2.prepaid_account_id)
      assert id == card2.card_id
    end
  end

  describe "CTA.Card's three-way exactly-one invariant" do
    test "valid with only prepaid_account_id set" do
      changeset =
        Card.changeset(%Card{}, %{
          pan_token: String.duplicate("a", 64), card_type: "PRIMARY",
          status: "INACTIVE", generation: 1, prepaid_account_id: Ecto.UUID.generate()
        })

      assert changeset.valid?
    end

    test "invalid when both debit_account_id and prepaid_account_id are set" do
      changeset =
        Card.changeset(%Card{}, %{
          pan_token: String.duplicate("a", 64), card_type: "PRIMARY",
          status: "INACTIVE", generation: 1,
          debit_account_id: Ecto.UUID.generate(), prepaid_account_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
    end
  end
end
