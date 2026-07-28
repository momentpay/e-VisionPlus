defmodule VmuCore.HCS.EmployeeCardCommand do
  @moduledoc """
  Card Products UX Parity Phase 3 (2026-07-28) — Employee Card's
  account-level Block/Unblock and Change-Limits operations.

  Unlike Debit/Prepaid (Phase 1e/2d), Employee Card doesn't need its own
  parallel block-history/non-monetary-event tables: `add_employee_card/3`
  already provisions a real `CMS.Account` row (`employee_account_id`,
  `account_type: "EMPLOYEE_CARD"`) — the exact same `cms_accounts` table
  Credit uses — so `CMS.BlockCodeHistory`/`CMS.NonMonetaryEvent` (which
  both carry a genuine FK to `cms_accounts` specifically, confirmed while
  building Phase 1e) already work unchanged.

  What Employee Card *does* need that Debit/Prepaid didn't: a real block
  here has to cascade to three places, not one —

    1. `cms_accounts.block_code` (via `BlockCodeHistory`) — audit trail,
       parity with every other product's account-level block.
    2. `HCS.EmployeeCard.status` — `HCS.LimitController.get_active_card/1`
       gates spend purely on this field (`status == "ACTIVE"`), NOT on
       `block_code` — confirmed by reading `limit_controller.ex` before
       writing this. A block that only set `block_code` would be
       silently ignored by HCS's own spend-limit enforcement.
    3. Any real `CTA.Card` issued against the account (`CardLifecycle.
       block/3`) — so real-time FAS authorization also declines
       immediately, not just the two DB-level gates above.

  `change_limit/4` reuses the exact same company-pool math
  `CompanyOnboarding.add_employee_card/3` already enforces (existing
  ACTIVE cards' limits must not exceed `company.credit_limit`) — a
  limit *change* must exclude the card's own current limit from
  "existing allocated" before re-checking the new proposed limit,
  otherwise every card would appear to double-count against the pool.
  """

  import Ecto.Query
  alias VmuCore.Repo
  alias VmuCore.HCS.{Company, EmployeeCard}
  alias VmuCore.CMS.{Account, BlockCodeHistory, NonMonetaryEvent}
  alias VmuCore.CTA.{Card, CardLifecycle}
  alias Decimal, as: D

  @spec apply_block(EmployeeCard.t(), String.t(), String.t(), String.t() | nil, Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, EmployeeCard.t()} | {:error, term()}
  def apply_block(%EmployeeCard{} = card, block_code, reason_code, reason_text, operator_id, operator_role \\ "AGENT", opts \\ []) do
    with {:ok, _hist} <-
           BlockCodeHistory.record_block(card.employee_account_id, block_code, reason_code, reason_text, operator_id, operator_role),
         {:ok, updated_card} <-
           card |> EmployeeCard.changeset(%{status: "SUSPENDED"}) |> Repo.update() do
      cascade_card_block(card.employee_account_id, opts[:current_operator])
      {:ok, updated_card}
    end
  end

  @spec remove_block(EmployeeCard.t(), String.t(), String.t() | nil, Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, EmployeeCard.t()} | {:error, term()}
  def remove_block(%EmployeeCard{} = card, reason_code, reason_text, operator_id, operator_role \\ "AGENT", opts \\ []) do
    account = Repo.get!(Account, card.employee_account_id)

    with {:ok, _hist} <-
           BlockCodeHistory.record_unblock(card.employee_account_id, account.block_code || "L", reason_code, reason_text, operator_id, operator_role),
         {:ok, updated_card} <-
           card |> EmployeeCard.changeset(%{status: "ACTIVE"}) |> Repo.update() do
      cascade_card_unblock(card.employee_account_id, opts[:current_operator])
      {:ok, updated_card}
    end
  end

  @spec change_limit(EmployeeCard.t(), Decimal.t(), Decimal.t() | nil, Ecto.UUID.t()) ::
          {:ok, EmployeeCard.t()} | {:error, term()}
  def change_limit(%EmployeeCard{} = card, new_individual_limit, new_monthly_cap, operator_id) do
    company = Repo.get!(Company, card.company_id)

    existing_allocated =
      from(ec in EmployeeCard,
        where: ec.company_id == ^card.company_id and ec.status == "ACTIVE" and ec.id != ^card.id,
        select: coalesce(sum(ec.individual_limit), 0)
      )
      |> Repo.one()
      |> Kernel.||(D.new(0))

    remaining_pool = D.sub(company.credit_limit, existing_allocated)

    if D.gt?(new_individual_limit, remaining_pool) do
      {:error, :individual_limit_exceeds_company_pool}
    else
      old_limit = card.individual_limit
      old_cap = card.monthly_spend_cap

      case card
           |> EmployeeCard.changeset(%{
             individual_limit: new_individual_limit,
             available_individual: new_individual_limit,
             monthly_spend_cap: new_monthly_cap
           })
           |> Repo.update() do
        {:ok, updated_card} ->
          NonMonetaryEvent.record(
            account_id: card.employee_account_id,
            event_type: "limit_change",
            old_value: %{"individual_limit" => D.to_string(old_limit), "monthly_spend_cap" => old_cap && D.to_string(old_cap)},
            new_value: %{"individual_limit" => D.to_string(new_individual_limit), "monthly_spend_cap" => new_monthly_cap && D.to_string(new_monthly_cap)},
            reason: "Employee card limit change",
            operator_id: operator_id
          )

          {:ok, updated_card}

        {:error, _} = err ->
          err
      end
    end
  end

  defp cascade_card_block(employee_account_id, operator) do
    case Repo.one(
           from c in Card,
             where: c.account_id == ^employee_account_id and c.status == "ACTIVE",
             limit: 1
         ) do
      nil -> :ok
      card -> CardLifecycle.block(card.card_id, "ADMIN", operator: operator)
    end
  end

  defp cascade_card_unblock(employee_account_id, operator) do
    case Repo.one(
           from c in Card,
             where: c.account_id == ^employee_account_id and c.status == "BLOCKED",
             limit: 1
         ) do
      nil -> :ok
      card -> CardLifecycle.unblock(card.card_id, operator: operator)
    end
  end
end
