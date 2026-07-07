defmodule VmuCore.TRAMS.AdjustmentCommand do
  @moduledoc """
  Post-posting amount corrections with maker-checker control (TRAM-P4 4B,
  spec 06 §3.3–3.4).

  ## Rules enforced

  - Adjustments apply only to transactions in POSTED / STATEMENTED / PAID —
    pre-posting corrections are reversals, not adjustments.
  - Zero-delta requests are rejected.
  - Above the approval threshold, the adjustment parks in PENDING_APPROVAL
    and a **different** operator must approve it (maker ≠ checker); at or
    below threshold it posts immediately.
  - Posting writes a GL correction through `CMS.InternalGlPoster` with
    idempotency key `"adjustment:<adjustment_id>"`, updates the aggregate's
    `settled_amount`, and appends an `adjustment_applied` event (audit-only —
    the lifecycle state does not change).

  ## GL direction

  - **DEBIT** adjustment (customer owes more — merchant under-charged):
    DR 1001 Card Receivables / CR 2001 Credit Liability (purchase direction)
  - **CREDIT** adjustment (customer owes less — merchant over-charged):
    DR 2001 Credit Liability / CR 1001 Card Receivables (reversal direction)

  ## Configuration

      config :vmu_core, :trams_adjustment_approval_threshold, "1000.00"  # default
  """

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.TRAMS.{Transaction, Adjustment, EventStore}
  alias VmuCore.CMS.InternalGlPoster
  alias VmuCore.FAS.GL.CardAccountCodes

  @adjustable_states ~w[POSTED STATEMENTED PAID]

  @doc """
  Request an adjustment.

  Attrs: `:transaction_id`, `:new_amount` (Decimal), `:reason_code`,
  `:requested_by`, optional `:narrative`.

  Returns:
    - `{:ok, :posted, adjustment}` — at/below threshold, posted immediately
    - `{:ok, :pending_approval, adjustment}` — parked for a second approver
    - `{:error, reason}`
  """
  @spec request(map()) ::
          {:ok, :posted | :pending_approval, Adjustment.t()} | {:error, term()}
  def request(%{transaction_id: transaction_id, new_amount: new_amount,
                reason_code: reason_code, requested_by: requested_by} = attrs) do
    with {:ok, txn}       <- fetch_adjustable(transaction_id),
         {:ok, old, delta} <- compute_delta(txn, new_amount) do
      direction = if Decimal.compare(delta, 0) == :gt, do: "DEBIT", else: "CREDIT"

      adjustment_attrs = %{
        transaction_id: transaction_id,
        old_amount:     old,
        new_amount:     new_amount,
        delta:          delta,
        direction:      direction,
        reason_code:    reason_code,
        narrative:      attrs[:narrative],
        requested_by:   requested_by
      }

      if requires_approval?(delta) do
        park_for_approval(adjustment_attrs)
      else
        insert_and_post(adjustment_attrs, txn)
      end
    end
  end

  @doc """
  Approve a PENDING_APPROVAL adjustment (checker step). The approver must be
  a different operator than the requester.
  """
  @spec approve(Ecto.UUID.t(), String.t()) :: {:ok, Adjustment.t()} | {:error, term()}
  def approve(adjustment_id, approved_by) do
    with %Adjustment{} = adj <- Repo.get(Adjustment, adjustment_id) || {:error, :not_found},
         :ok <- check_pending(adj),
         :ok <- check_maker_checker(adj, approved_by),
         {:ok, txn} <- fetch_adjustable(adj.transaction_id) do
      post_adjustment(adj, txn, approved_by)
    end
  end

  @doc "Reject a PENDING_APPROVAL adjustment."
  @spec reject(Ecto.UUID.t(), String.t()) :: {:ok, Adjustment.t()} | {:error, term()}
  def reject(adjustment_id, rejected_by) do
    with %Adjustment{} = adj <- Repo.get(Adjustment, adjustment_id) || {:error, :not_found},
         :ok <- check_pending(adj) do
      adj
      |> Adjustment.changeset(%{status: "REJECTED", approved_by: rejected_by})
      |> Repo.update()
    end
  end

  @doc "Pending adjustments for the ops approval queue."
  @spec pending(non_neg_integer()) :: [Adjustment.t()]
  def pending(limit \\ 50) do
    Repo.all(
      from a in Adjustment,
        where: a.status == "PENDING_APPROVAL",
        order_by: [asc: a.inserted_at],
        limit: ^limit
    )
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp fetch_adjustable(transaction_id) do
    case Repo.get(Transaction, transaction_id) do
      nil ->
        {:error, :transaction_not_found}

      %Transaction{state: state} = txn when state in @adjustable_states ->
        {:ok, txn}

      %Transaction{state: state} ->
        {:error, {:not_adjustable, state}}
    end
  end

  defp compute_delta(txn, new_amount) do
    old = txn.settled_amount || txn.amount
    delta = Decimal.sub(new_amount, old)

    if Decimal.compare(delta, 0) == :eq do
      {:error, :zero_delta}
    else
      {:ok, old, delta}
    end
  end

  defp requires_approval?(delta) do
    threshold =
      Application.get_env(:vmu_core, :trams_adjustment_approval_threshold, "1000.00")
      |> Decimal.new()

    Decimal.compare(Decimal.abs(delta), threshold) == :gt
  end

  defp check_pending(%Adjustment{status: "PENDING_APPROVAL"}), do: :ok
  defp check_pending(%Adjustment{status: status}), do: {:error, {:not_pending, status}}

  defp check_maker_checker(%Adjustment{requested_by: maker}, checker)
       when maker == checker,
       do: {:error, :maker_cannot_approve}

  defp check_maker_checker(_, _), do: :ok

  # ---------------------------------------------------------------------------
  # Posting
  # ---------------------------------------------------------------------------

  defp park_for_approval(attrs) do
    case Repo.insert(Adjustment.changeset(%Adjustment{}, attrs)) do
      {:ok, adj} ->
        Logger.info("[TRAMS.Adjustment] #{adj.adjustment_id} parked for approval " <>
                    "(delta=#{adj.delta} by=#{adj.requested_by})")
        {:ok, :pending_approval, adj}

      {:error, cs} ->
        {:error, cs}
    end
  end

  defp insert_and_post(attrs, txn) do
    case Repo.insert(Adjustment.changeset(%Adjustment{}, Map.put(attrs, :status, "APPROVED"))) do
      {:ok, adj} ->
        case post_adjustment(adj, txn, attrs.requested_by) do
          {:ok, posted} -> {:ok, :posted, posted}
          error -> error
        end

      {:error, cs} ->
        {:error, cs}
    end
  end

  defp post_adjustment(adj, txn, approved_by) do
    key = "adjustment:#{adj.adjustment_id}"
    abs_delta = Decimal.abs(adj.delta)

    {dr, cr} =
      case adj.direction do
        "DEBIT"  -> CardAccountCodes.journal_pair("PURCHASE")
        "CREDIT" -> CardAccountCodes.journal_pair("REVERSAL")
      end

    Repo.transaction(fn ->
      case InternalGlPoster.post(%{
             account_id:       txn.account_id,
             idempotency_key:  key,
             transaction_code: "ADJUSTMENT",
             dr_amount:        abs_delta,
             cr_amount:        abs_delta,
             gl_account_dr:    dr,
             gl_account_cr:    cr,
             posting_date:     Date.utc_today(),
             value_date:       Date.utc_today(),
             narrative:        "Adjustment #{adj.direction} #{adj.reason_code} " <>
                               "txn=#{adj.transaction_id}"
           }) do
        {:ok, _entry} -> :ok
        # :duplicate = idempotent re-post (retry after crash) — proceed
        {:error, :duplicate} -> :ok
        {:error, reason} -> Repo.rollback({:gl_post_failed, reason})
      end

      updated_adj =
        adj
        |> Adjustment.changeset(%{
          status: "POSTED",
          approved_by: approved_by,
          gl_idempotency_key: key,
          posted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update!()

      txn
      |> Ecto.Changeset.change(settled_amount: adj.new_amount)
      |> Repo.update!()

      updated_adj
    end)
    |> case do
      {:ok, updated_adj} ->
        # Audit event — outside the posting transaction; adjustment_applied is
        # stateless so it cannot be rejected by the state machine
        EventStore.append(adj.transaction_id, "adjustment_applied", %{
          adjustment_id: adj.adjustment_id,
          old_amount:    adj.old_amount,
          new_amount:    adj.new_amount,
          delta:         adj.delta,
          direction:     adj.direction,
          reason_code:   adj.reason_code
        }, actor: approved_by)

        {:ok, updated_adj}

      {:error, reason} ->
        Logger.error("[TRAMS.Adjustment] Posting failed for #{adj.adjustment_id}: " <>
                     "#{inspect(reason)}")
        {:error, reason}
    end
  end
end
