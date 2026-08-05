defmodule VmuCore.CMS.FeeWaiver do
  @moduledoc """
  Fee waiver operator function — supervisor action that reverses a specific fee
  charge, reducing the cardholder's unpaid_fees balance.

  ## When fee waivers are used

  - First-time customer goodwill (late fee waiver after payment)
  - System-posted fee that should not have applied (incorrect logic bug)
  - Regulatory or complaint resolution requirement
  - Supervisor override of an EOD-generated fee

  ## Security model

  Fee waivers require supervisor approval (4-eyes):
    - `operator_id`    — agent who requests the waiver
    - `supervisor_id`  — supervisor who authorises it (must differ from operator)

  ## Mechanism

  A fee waiver is implemented as a **REVERSAL** GL entry that mirrors the
  original FEE posting with reversed debit/credit accounts:

  | Step | GL debit         | GL credit        |
  |------|------------------|------------------|
  | Original fee  | 1004 (fee recv) | 2002 (fee income) |
  | Waiver reversal | 2002 (fee income) | 1004 (fee recv) |

  After posting the reversal, `balance_bucket.unpaid_fees` is decremented by
  the waived amount within the same database transaction.

  ## Idempotency

  Idempotency key: `"WAIVER:\#{original_idempotency_key}:\#{supervisor_id}"`

  If the same waiver is attempted twice (Oban retry, double-click) the second
  call returns `{:error, :duplicate}` without posting again.

  ## Usage

      alias VmuCore.CMS.FeeWaiver

      # Waive a specific fee by its original idempotency key
      {:ok, reversal} = FeeWaiver.waive(
        account_id:             acc.account_id,
        original_idempotency_key: "LATE_FEE:\#{account_id}:2026-06-15",
        reason:                 "First-time waiver — customer paid within 48h",
        operator_id:            agent_id,
        supervisor_id:          supervisor_id
      )

      # Waive a specific fee by its ledger entry_id
      {:ok, reversal} = FeeWaiver.waive_by_entry_id(
        entry_id:     "6a4f...",
        account_id:   acc.account_id,
        reason:       "System error — fee incorrectly applied",
        operator_id:  agent_id,
        supervisor_id: supervisor_id
      )
  """

  import Ecto.Query

  alias VmuCore.{Repo, CMS.LedgerEntry, CMS.BalanceBucket}
  alias VmuCore.CMS.InternalGlPoster
  alias VmuCore.GL.LedgerQuery
  alias Decimal, as: D

  @doc """
  Waive a fee identified by its original idempotency key.

  ## Options

    - `:account_id`               — (required) target account UUID
    - `:original_idempotency_key` — (required) idempotency key of the FEE entry to reverse
    - `:reason`                   — (required) free-text justification (max 100 chars)
    - `:operator_id`              — (required) UUID of initiating agent
    - `:supervisor_id`            — (required) UUID of approving supervisor (must differ)
    - `:posting_date`             — `Date.t()` (default: `Date.utc_today/0`)

  Returns `{:ok, %LedgerEntry{}}` or `{:error, reason}`.
  """
  @spec waive(keyword()) :: {:ok, LedgerEntry.t()} | {:error, term()}
  def waive(opts) do
    original_key = Keyword.fetch!(opts, :original_idempotency_key)
    account_id   = Keyword.fetch!(opts, :account_id)

    case find_fee_entry(account_id, original_key) do
      nil ->
        {:error, {:fee_entry_not_found, original_key}}

      entry ->
        do_waive(entry, opts)
    end
  end

  @doc """
  Fee entries for an account, newest first — the list an operator picks from.

  GL Phase C2. Each entry is identified by its `:idempotency_key`, which is
  what `waive/1` takes.

  **This replaces the previous `entry_id` identifier.** `cms_ledger_entries`
  had a surrogate primary key; the posting tables have no single column that
  means the same thing, and the idempotency key is the better identifier in any
  case — it is stable across the two models, it is what the backfill joined on,
  and it is meaningful to read in an audit trail.
  """
  @spec list_fee_entries(binary(), keyword()) :: [map()]
  def list_fee_entries(account_id, opts \\ []) do
    LedgerQuery.entries(
      account_ref: account_id,
      transaction_code: "FEE",
      limit: Keyword.get(opts, :limit, 30)
    )
  end

  @doc """
  List all fee waivers (REVERSAL entries) for an account, newest first.
  """
  @spec list_for(binary()) :: [map()]
  def list_for(account_id) do
    # GL Phase C2 — see `GL.LedgerQuery`. Returns maps, not LedgerEntry structs.
    LedgerQuery.entries(account_ref: account_id, transaction_code: "REVERSAL")
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_waive(original_entry, opts) do
    with :ok <- validate_waiver_opts(opts) do
      account_id    = Keyword.fetch!(opts, :account_id)
      reason        = Keyword.fetch!(opts, :reason)
      operator_id   = Keyword.fetch!(opts, :operator_id)
      supervisor_id = Keyword.fetch!(opts, :supervisor_id)
      posting_date  = Keyword.get(opts, :posting_date, Date.utc_today())

      waiver_key =
        "WAIVER:#{original_entry.idempotency_key}:#{supervisor_id}"

      narrative =
        "Fee waiver | orig_key=#{String.slice(original_entry.idempotency_key, 0, 30)} " <>
        "op=#{String.slice(to_string(operator_id), 0, 8)} " <>
        "sup=#{String.slice(to_string(supervisor_id), 0, 8)} | #{reason}"

      # Post reversal and update unpaid_fees atomically
      Repo.transaction(fn ->
        result = InternalGlPoster.post(%{
          account_id:       account_id,
          idempotency_key:  waiver_key,
          transaction_code: "REVERSAL",
          # `amount` serves both sides: under double entry the legacy row's
          # dr_amount and cr_amount were always equal, and the posting tables
          # keep the single value.
          dr_amount:        original_entry.amount,
          cr_amount:        original_entry.amount,
          # Reverse the original: credit the receivable, debit the income
          gl_account_dr:    original_entry.cr_gl_account,
          gl_account_cr:    original_entry.dr_gl_account,
          posting_date:     posting_date,
          value_date:       posting_date,
          narrative:        narrative,
          source_ref:       original_entry.idempotency_key
        })

        case result do
          {:ok, reversal_entry} ->
            # Decrement balance_bucket.unpaid_fees by the waived amount
            decrement_unpaid_fees(account_id, original_entry.amount)
            reversal_entry

          {:error, :duplicate} ->
            Repo.rollback(:duplicate)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end
  end

  defp validate_waiver_opts(opts) do
    required = [:account_id, :reason, :operator_id, :supervisor_id]
    missing  = Enum.filter(required, &(!Keyword.has_key?(opts, &1)))

    cond do
      missing != [] ->
        {:error, {:missing_fields, missing}}

      Keyword.get(opts, :operator_id) == Keyword.get(opts, :supervisor_id) ->
        {:error, :operator_and_supervisor_must_differ}

      String.length(Keyword.get(opts, :reason, "")) > 100 ->
        {:error, :reason_too_long}

      true ->
        :ok
    end
  end

  # GL Phase C2 — see `GL.LedgerQuery`. The account and the FEE event type are
  # both still matched even though the idempotency key is unique on its own:
  # this is the lookup that decides what gets reversed, and it should not be
  # able to reverse another account's posting, or a non-fee one, on a key
  # collision.
  defp find_fee_entry(account_id, idempotency_key) do
    LedgerQuery.entries(
      account_ref: account_id,
      transaction_code: "FEE",
      idempotency_key: idempotency_key,
      limit: 1
    )
    |> List.first()
  end

  # Decrement the most recent balance_bucket.unpaid_fees by the waived amount.
  # Floor at zero — unpaid_fees should never go negative.
  defp decrement_unpaid_fees(account_id, amount) do
    bucket =
      Repo.one(
        from b in BalanceBucket,
          where: b.account_id == ^account_id,
          order_by: [desc: b.balance_date],
          limit: 1
      )

    if bucket do
      new_unpaid = D.max(D.sub(bucket.unpaid_fees, amount), D.new(0))

      bucket
      |> BalanceBucket.changeset(%{unpaid_fees: new_unpaid})
      |> Repo.update!()
    end
  end
end
