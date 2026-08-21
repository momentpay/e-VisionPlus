defmodule VmuCore.CMS.Oban.PrepaidExpiryJob do
  @moduledoc """
  Daily Oban job — expires ACTIVE `LOAD`/`REFUND` rows whose
  `expiry_date` has passed (Way4 parity plan Phase 1 item 5, P5).

  For each expired row: flips its `status` to `EXPIRED` (excluding it
  from `PrepaidLedger.balance/1` and future `spend/3` consumption — both
  already filter on `status == "ACTIVE"`) and posts an `EXPIRE` ledger
  entry recording exactly how much unspent value was lost, for audit.
  The original row's `remaining_amount` is left as-is — it already IS
  the amount that expired, no separate zeroing needed.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.CMS.PrepaidLedgerEntry

  @consumable_entry_types ["LOAD", "REFUND"]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    today = Date.utc_today()

    expired =
      Repo.all(
        from l in PrepaidLedgerEntry,
          where: l.entry_type in ^@consumable_entry_types and l.status == "ACTIVE"
            and not is_nil(l.expiry_date) and l.expiry_date < ^today
            and l.remaining_amount > 0
      )

    Logger.info("[CMS/PrepaidExpiry] #{length(expired)} load(s) to expire as of #{today}")

    Enum.each(expired, &expire_load(&1, today))
    :ok
  end

  defp expire_load(load, today) do
    Repo.transaction(fn ->
      Repo.update_all(
        from(l in PrepaidLedgerEntry, where: l.id == ^load.id),
        set: [status: "EXPIRED"]
      )

      # idempotency_key is nullable (most rows have none), so its unique
      # index is partial (`WHERE idempotency_key IS NOT NULL`) — Postgres
      # requires ON CONFLICT's target to match that exact partial index,
      # not a bare column list, or it errors "no unique or exclusion
      # constraint matching the ON CONFLICT specification".
      %PrepaidLedgerEntry{}
      |> PrepaidLedgerEntry.changeset(%{
        prepaid_account_id: load.prepaid_account_id, entry_type: "EXPIRE",
        amount: load.remaining_amount, posted_by: "system", posting_date: today,
        idempotency_key: "prepaid_expire:#{load.id}"
      })
      |> Repo.insert(
           on_conflict: :nothing,
           conflict_target: {:unsafe_fragment, "(idempotency_key) WHERE idempotency_key IS NOT NULL"}
         )
    end)
  end
end
