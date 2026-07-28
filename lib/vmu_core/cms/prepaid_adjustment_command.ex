defmodule VmuCore.CMS.PrepaidAdjustmentCommand do
  @moduledoc """
  Posts a `CMS.PrepaidAdjustment` — GL entry + ledger row + audit
  record, in one transaction. Card Products UX Parity Phase 2c
  (2026-07-28), mirrors `CMS.DebitAdjustmentCommand` exactly.

  CREDIT direction inserts a new ACTIVE `ADJUSTMENT` ledger row
  (spendable value, same shape as a LOAD — `PrepaidLedger.
  consumable_entry_types` includes ADJUSTMENT). DEBIT direction consumes
  ACTIVE loads FIFO via `PrepaidLedger.consume_active_loads/2` — the
  exact same consumption `PrepaidLedger.spend/3` uses, just tagged
  `ADJUSTMENT` instead of `SPEND` so it's distinguishable in the ledger.
  """

  import Ecto.Query

  alias VmuCore.{Repo, CMS.PrepaidAccount, CMS.PrepaidAdjustment, CMS.PrepaidLedger,
                 CMS.PrepaidLedgerEntry, CMS.InternalGlPoster}

  @doc """
  attrs = %{prepaid_account_id:, direction: "CREDIT" | "DEBIT", amount:,
            reason:, reference_id:, operator_id:, supervisor_id:}

  Returns `{:ok, %PrepaidAdjustment{}}` or `{:error, changeset | reason}`.
  """
  def post(attrs) do
    changeset = PrepaidAdjustment.changeset(%PrepaidAdjustment{}, attrs)

    with %Ecto.Changeset{valid?: true} <- changeset,
         prepaid_account_id <- Ecto.Changeset.get_field(changeset, :prepaid_account_id),
         %PrepaidAccount{} = account <- Repo.get!(PrepaidAccount, prepaid_account_id),
         true <- PrepaidAccount.active?(account) || {:error, :prepaid_account_not_active} do
      direction = Ecto.Changeset.get_field(changeset, :direction)
      amount = Ecto.Changeset.get_field(changeset, :amount)
      reason = Ecto.Changeset.get_field(changeset, :reason)
      reference_id = Ecto.Changeset.get_field(changeset, :reference_id)
      operator_id = Ecto.Changeset.get_field(changeset, :operator_id)

      idempotency_key = "prepaid_adj:#{prepaid_account_id}:#{reference_id}:#{System.unique_integer([:positive])}"
      narrative = "Prepaid adjustment (#{direction}) — #{reason}"

      Repo.transaction(fn ->
        with :ok <- apply_ledger_effect(prepaid_account_id, direction, amount, operator_id),
             {:ok, gl_entry} <-
               InternalGlPoster.post_prepaid_adjustment(
                 prepaid_account_id, amount, direction, Date.utc_today(), narrative, idempotency_key
               ),
             {:ok, record} <-
               changeset
               |> Ecto.Changeset.put_change(:ledger_entry_id, gl_entry.entry_id)
               |> Repo.insert() do
          record
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      %Ecto.Changeset{valid?: false} = cs -> {:error, cs}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Every adjustment for a prepaid account, newest first."
  def list_for(prepaid_account_id) do
    Repo.all(
      from a in PrepaidAdjustment,
        where: a.prepaid_account_id == ^prepaid_account_id,
        order_by: [desc: a.inserted_at]
    )
  end

  defp apply_ledger_effect(prepaid_account_id, "CREDIT", amount, operator_id) do
    %PrepaidLedgerEntry{}
    |> PrepaidLedgerEntry.changeset(%{
      prepaid_account_id: prepaid_account_id, entry_type: "ADJUSTMENT", amount: amount,
      remaining_amount: amount, status: "ACTIVE",
      posted_by: operator_id, posting_date: Date.utc_today()
    })
    |> Repo.insert()
    |> case do
      {:ok, _entry} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_ledger_effect(prepaid_account_id, "DEBIT", amount, operator_id) do
    case PrepaidLedger.consume_active_loads(prepaid_account_id, amount) do
      {:ok, consumed} ->
        %PrepaidLedgerEntry{}
        |> PrepaidLedgerEntry.changeset(%{
          prepaid_account_id: prepaid_account_id, entry_type: "ADJUSTMENT", amount: amount,
          consumed_from: Enum.map(consumed, fn %{load_entry_id: id, amount: amt} ->
            %{"load_entry_id" => id, "amount" => Decimal.to_string(amt)}
          end),
          posted_by: operator_id, posting_date: Date.utc_today()
        })
        |> Repo.insert()
        |> case do
          {:ok, _entry} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, :insufficient_funds} ->
        {:error, :insufficient_funds}
    end
  end
end
