defmodule VmuCore.CMS.PaymentAllocation do
  @moduledoc """
  Sub-allocates a bucket-level payment amount (already assigned to one
  balance bucket by `VmuCore.CMS.RepaymentDistributor`'s hierarchy) across
  the account's real outstanding `VmuCore.CMS.TransactionAllocation` rows
  for that bucket — FR-067's transaction-level precision, on top of the
  purchase-posting pipeline `VmuCore.CMS.PurchasePosting` builds.

  Only applies to the three buckets that have transaction-level detail:
  `retail_balance`, `cash_balance`, `bt_balance`. Fee/interest/EMI
  postings from `RepaymentDistributor` are period-based accruals (or, for
  EMI, already tracked by `PlanSegment`) — not individual purchase
  transactions — and are left untouched by this module.

  Allocation method (`fifo`/`lifo`/`highest_amount_first`/`proportional`)
  and whether disputed transactions are skipped are both bank-configurable
  (`VmuCore.CMS.ConfigCatalog`), not hardcoded — see that module's
  `payment_allocation_method`/`exclude_disputed_from_allocation` entries.
  """

  import Ecto.Query
  require Logger

  alias VmuCore.{Repo, CMS.Account, CMS.TransactionAllocation}
  alias VmuCore.Shared.ModuleConfigEngine
  alias Decimal, as: D

  @allocatable_buckets ~w[retail_balance cash_balance bt_balance]

  @doc """
  Allocate `amount` (a `Decimal`, already assigned to `bucket_field` by
  RepaymentDistributor) across `account`'s real outstanding transactions
  in that bucket. `bucket_field` may be an atom or string. No-op
  (`{:ok, []}`) for buckets with no transaction-level detail (fees,
  interest, EMI) or when there's nothing outstanding to apply against —
  the amount was already correctly applied to the aggregate `BalanceBucket`
  by `RepaymentDistributor`; this only adds the transaction-level detail
  on top, it never re-decides how much goes to which bucket.
  """
  @spec allocate_payment(Account.t(), atom() | String.t(), Decimal.t()) ::
          {:ok, [%{allocation_id: Ecto.UUID.t(), applied: Decimal.t()}]}
  def allocate_payment(%Account{} = account, bucket_field, %D{} = amount) do
    bucket_str = to_string(bucket_field)

    cond do
      bucket_str not in @allocatable_buckets ->
        {:ok, []}

      D.compare(amount, D.new(0)) != :gt ->
        {:ok, []}

      true ->
        {:ok, method_str} =
          ModuleConfigEngine.get("cms", "payment_allocation_method", account.sys_id, account.bank_id, account.logo_id)

        {:ok, exclude_disputed} =
          ModuleConfigEngine.get("cms", "exclude_disputed_from_allocation", account.sys_id, account.bank_id, account.logo_id)

        method = safe_method_atom(method_str)
        outstanding = TransactionAllocation.outstanding(account.account_id, bucket_str, method, exclude_disputed)

        case method do
          :proportional -> allocate_proportional(outstanding, amount)
          _ -> allocate_sequential(outstanding, amount)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # fifo/lifo/highest_amount_first all "pay this one off fully, then move to
  # the next" — they differ only in TransactionAllocation.outstanding/4's
  # ordering, not in how the amount is applied once ordered.
  defp allocate_sequential(outstanding, amount) do
    {applied, _remaining} =
      Enum.reduce(outstanding, {[], amount}, fn alloc, {acc, remaining} ->
        if D.compare(remaining, D.new(0)) == :eq do
          {acc, remaining}
        else
          apply_amt = D.min(remaining, alloc.remaining_amount)
          apply_to_allocation(alloc, apply_amt)
          {[%{allocation_id: alloc.allocation_id, applied: apply_amt} | acc], D.sub(remaining, apply_amt)}
        end
      end)

    {:ok, Enum.reverse(applied)}
  end

  defp allocate_proportional([], _amount), do: {:ok, []}

  defp allocate_proportional(outstanding, amount) do
    total_outstanding = Enum.reduce(outstanding, D.new(0), &D.add(&2, &1.remaining_amount))
    count = length(outstanding)

    if D.compare(total_outstanding, D.new(0)) == :eq do
      {:ok, []}
    else
      {applied, _remaining} =
        outstanding
        |> Enum.with_index(1)
        |> Enum.reduce({[], amount}, fn {alloc, idx}, {acc, remaining} ->
          apply_amt =
            if idx == count do
              # Last one absorbs whatever's left — never strands a
              # rounding remainder unapplied.
              D.min(remaining, alloc.remaining_amount)
            else
              share = amount |> D.mult(D.div(alloc.remaining_amount, total_outstanding)) |> D.round(2)
              share |> D.min(remaining) |> D.min(alloc.remaining_amount)
            end

          apply_to_allocation(alloc, apply_amt)
          {[%{allocation_id: alloc.allocation_id, applied: apply_amt} | acc], D.sub(remaining, apply_amt)}
        end)

      {:ok, Enum.reverse(applied)}
    end
  end

  defp apply_to_allocation(%TransactionAllocation{} = alloc, apply_amt) do
    new_allocated = D.add(alloc.allocated_amount, apply_amt)
    new_remaining = D.sub(alloc.remaining_amount, apply_amt)

    status =
      cond do
        D.compare(new_remaining, D.new(0)) != :gt -> "PAID"
        D.compare(new_allocated, D.new(0)) == :gt -> "PARTIALLY_PAID"
        true -> "OUTSTANDING"
      end

    Repo.update_all(
      from(a in TransactionAllocation, where: a.allocation_id == ^alloc.allocation_id),
      set: [allocated_amount: new_allocated, remaining_amount: new_remaining, status: status]
    )
  end

  defp safe_method_atom("lifo"), do: :lifo
  defp safe_method_atom("highest_amount_first"), do: :highest_amount_first
  defp safe_method_atom("proportional"), do: :proportional
  defp safe_method_atom(_), do: :fifo
end
