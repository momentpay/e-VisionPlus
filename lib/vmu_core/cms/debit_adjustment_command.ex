defmodule VmuCore.CMS.DebitAdjustmentCommand do
  @moduledoc """
  Posts a `CMS.DebitAdjustment` — GL entry + balance update + audit
  record, in one transaction. Card Products UX Parity Phase 1c
  (2026-07-28). The 4-eyes check itself (`operator_id != supervisor_id`)
  is enforced in `DebitAdjustment.changeset/2`; permission/authority
  validation of the checker happens one layer up, in the admin UI, via
  `ASM.Authz.validate_checker/4` — same split Credit's Temp Limit/Fee
  Waiver/Financial Adjustment already use.
  """

  import Ecto.Query

  alias VmuCore.{Repo, CMS.DebitAccount, CMS.DebitAdjustment, CMS.InternalGlPoster}

  @doc """
  attrs = %{debit_account_id:, direction: "CREDIT" | "DEBIT", amount:,
            reason:, reference_id:, operator_id:, supervisor_id:}

  Returns `{:ok, %DebitAdjustment{}}` or `{:error, changeset | reason}`.
  """
  def post(attrs) do
    changeset = DebitAdjustment.changeset(%DebitAdjustment{}, attrs)

    with %Ecto.Changeset{valid?: true} <- changeset,
         debit_account_id <- Ecto.Changeset.get_field(changeset, :debit_account_id),
         %DebitAccount{} = account <- Repo.get!(DebitAccount, debit_account_id),
         true <- DebitAccount.active?(account) || {:error, :debit_account_not_active} do
      direction = Ecto.Changeset.get_field(changeset, :direction)
      amount = Ecto.Changeset.get_field(changeset, :amount)
      reason = Ecto.Changeset.get_field(changeset, :reason)
      reference_id = Ecto.Changeset.get_field(changeset, :reference_id)

      idempotency_key = "debit_adj:#{debit_account_id}:#{reference_id}:#{System.unique_integer([:positive])}"
      narrative = "Debit adjustment (#{direction}) — #{reason}"

      Repo.transaction(fn ->
        with :ok <- apply_balance_delta(debit_account_id, direction, amount),
             {:ok, gl_entry} <-
               InternalGlPoster.post_debit_adjustment(
                 debit_account_id, amount, direction, Date.utc_today(), narrative, idempotency_key
               ),
             {:ok, record} <-
               changeset
               |> Ecto.Changeset.put_change(:ledger_entry_id, gl_entry.id)
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

  @doc "Every adjustment for a debit account, newest first."
  def list_for(debit_account_id) do
    Repo.all(
      from a in DebitAdjustment,
        where: a.debit_account_id == ^debit_account_id,
        order_by: [desc: a.inserted_at]
    )
  end

  # CREDIT never risks going negative — plain increment. DEBIT reuses the
  # same atomic `WHERE available_balance >= amount` guard `DebitAuthorization.
  # authorize/2` uses on the real-time auth path, so an adjustment can never
  # push the balance below zero.
  defp apply_balance_delta(debit_account_id, "CREDIT", amount) do
    {1, _} =
      Repo.update_all(
        from(d in DebitAccount, where: d.debit_account_id == ^debit_account_id),
        inc: [available_balance: amount]
      )

    :ok
  end

  defp apply_balance_delta(debit_account_id, "DEBIT", amount) do
    case Repo.update_all(
           from(d in DebitAccount,
             where: d.debit_account_id == ^debit_account_id and d.available_balance >= ^amount
           ),
           inc: [available_balance: Decimal.negate(amount)]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :insufficient_funds}
    end
  end
end
