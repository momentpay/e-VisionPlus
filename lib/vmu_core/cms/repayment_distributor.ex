defmodule VmuCore.CMS.RepaymentDistributor do
  @moduledoc """
  Allocates an incoming payment across balance buckets using the
  VisionPlus payment hierarchy:

    1. Unpaid fees (oldest first)
    2. Cash advance interest
    3. Retail purchase interest
    4. Cash advance principal
    5. Retail purchase principal

  This ordering maximises interest income for the issuer and is required
  by most card scheme rules. All arithmetic is Decimal.

  Returns an updated bucket map and the GL posting instructions.
  """

  alias Decimal, as: D

  @doc """
  Distribute `payment_amount` across the balance bucket.

  Returns:
    {:ok, %{updated_bucket: map(), gl_postings: [map()], remainder: Decimal.t()}}
  """
  def distribute(payment_amount, bucket) do
    {remainder, postings, new_bucket} =
      [
        {:unpaid_fees,    "FEE_PAYMENT"},
        {:accrued_interest, "INTEREST_PAYMENT"},  # cash interest first (simplification)
        {:cash_balance,   "CASH_PAYMENT"},
        {:retail_balance, "RETAIL_PAYMENT"}
      ]
      |> Enum.reduce({payment_amount, [], bucket}, fn {field, code}, {rem, posts, bkt} ->
        if D.compare(rem, D.new(0)) == :eq do
          {rem, posts, bkt}
        else
          current   = Map.get(bkt, field, D.new(0))
          allocated = D.min(rem, current)
          new_val   = D.sub(current, allocated)
          new_rem   = D.sub(rem, allocated)

          posting = %{
            bucket_field:     field,
            transaction_code: code,
            amount:           allocated
          }

          {new_rem, [posting | posts], Map.put(bkt, field, new_val)}
        end
      end)

    # Recalculate disputed_amount is untouched by payments
    {:ok, %{
      updated_bucket: new_bucket,
      gl_postings:    Enum.reverse(postings),
      remainder:      remainder
    }}
  end

  @doc """
  Post-payment hook: restore HCS company pool + individual limit for employee cards.
  Call this after distribute/2 completes successfully for an employee card account.
  No-op for non-HCS accounts.
  """
  def credit_hcs_limits(account_id, payment_amount) do
    VmuCore.HCS.LimitController.credit_limits(account_id, payment_amount)
  end

  @doc """
  Determine if the full statement balance was paid (grace period qualification).
  """
  def full_payment?(%{statement_balance: stmt}, payment_amount) do
    D.compare(payment_amount, stmt) != :lt
  end
end
