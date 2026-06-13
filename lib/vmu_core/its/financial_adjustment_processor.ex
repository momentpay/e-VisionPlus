defmodule VmuCore.ITS.FinancialAdjustmentProcessor do
  @moduledoc """
  Processes Financial Adjustment Records (FARs) received from card schemes.

  FARs are scheme-generated corrections for:
    - Misrouted transactions
    - Processing errors
    - Compliance failures
    - Interchange rate corrections

  Auto-accept threshold: AED 1000. FARs above this are queued for manual review.
  """

  alias VmuCore.ITS.FinancialAdjustment
  alias VmuCore.CMS.InternalGlPoster
  alias VmuCore.Repo

  @auto_accept_threshold Decimal.new("1000")

  @doc """
  Ingests a FAR received from scheme in ITS2 batch.
  Idempotent via reference_no unique constraint.
  """
  def ingest_far(far_attrs) do
    %FinancialAdjustment{}
    |> FinancialAdjustment.changeset(Map.merge(far_attrs, %{
      status:        "RECEIVED",
      received_date: Date.utc_today()
    }))
    |> Repo.insert(on_conflict: :nothing, conflict_target: :reference_no)
    |> case do
      {:ok, %FinancialAdjustment{id: nil}} -> {:error, :duplicate}
      result -> result
    end
  end

  @doc """
  Accepts and applies an FAR — posts the GL entry and marks ACCEPTED.
  For positive amounts: DR far_recv / CR far_income.
  For negative amounts: DR far_expense / CR far_payable.
  """
  def accept(adjustment_id) do
    Repo.transaction(fn ->
      adj = Repo.get!(FinancialAdjustment, adjustment_id)

      {gl_dr, gl_cr} =
        if Decimal.gt?(adj.adjustment_amount, Decimal.new(0)) do
          {"its_far_recv", "its_far_income"}
        else
          {"its_far_expense", "its_far_payable"}
        end

      abs_amount = Decimal.abs(adj.adjustment_amount)

      case InternalGlPoster.post(%{
        account_id:       "SYSTEM",
        idempotency_key:  "its_far_gl_#{adj.id}",
        transaction_code: "FAR_#{adj.adjustment_type}",
        dr_amount:        abs_amount,
        cr_amount:        abs_amount,
        gl_account_dr:    gl_dr,
        gl_account_cr:    gl_cr,
        posting_date:     adj.received_date,
        value_date:       Date.utc_today(),
        narrative:        "FAR #{adj.reference_no} #{adj.adjustment_type}"
      }) do
        {:ok, gl_entry} ->
          adj
          |> FinancialAdjustment.changeset(%{
            status:      "ACCEPTED",
            applied_date: Date.utc_today(),
            gl_entry_id:  gl_entry.id
          })
          |> Repo.update!()

        {:error, :duplicate} ->
          # GL already posted — just mark accepted
          adj
          |> FinancialAdjustment.changeset(%{status: "ACCEPTED", applied_date: Date.utc_today()})
          |> Repo.update!()

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Returns true if this FAR should be auto-accepted (amount < threshold).
  FARs at or above threshold require manual review.
  """
  def auto_acceptable?(%FinancialAdjustment{adjustment_amount: amount}) do
    Decimal.lt?(Decimal.abs(amount), @auto_accept_threshold)
  end
end
