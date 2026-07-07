defmodule VmuCore.TRAMS.MatchingEngine do
  @moduledoc """
  Clearing → authorization matching (TRAM-P3 3A, spec Section 6.4).

  Matches inbound clearing/settlement records (`trams_clearing_records`) back
  to their original authorization (`fas_authorizations`) and the TRAM
  transaction aggregate, applying the identifier hierarchy in priority order:

      1. RRN + pan_token           (strongest — survives multi-day gaps)
      2. auth_code + pan_token      (approval code echoed in clearing)
      3. pan_token + amount + date  (weakest — tolerance-bounded fallback)

  STAN is intentionally NOT used for clearing matching: `trams_clearing_records`
  does not carry it (Base II / IPM presentments reference RRN + auth code), and
  STAN rolls over at 999999 making it unsafe beyond the same-hour window that
  `FAS.ReversalHandler` uses.

  ## Outcomes

  - **Match** → clearing row gets `matched_auth_id` / `matched_transaction_id` /
    `match_status: "MATCHED"`; TRAM transaction gets a `settlement_matched`
    event (→ CLEARED), `settled_amount`, `clearing_id`, and a clearing-source
    identifier row.
  - **Auth found but no TRAM transaction** (auth pre-dates the TRAM feed) →
    clearing row still gets `matched_auth_id` + `"MATCHED"` so posting can
    proceed; the aggregate linkage is simply absent.
  - **No match** → `match_status: "EXCEPTION"` — the review queue for ops
    (spec 10 §2.2: never silently dropped, never force-matched).

  ## Amount tolerance

  Settled amount routinely differs from authorized (tips, FX, partial
  fulfillment), so identifier matches (tiers 1–2) ignore amount entirely.
  The tier-3 PAN fallback bounds it:

      config :vmu_core, :trams_match_amount_tolerance_pct, 20   # default
      config :vmu_core, :trams_match_date_window_days, 3        # default
  """

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.TRAMS.{ClearingRecord, Transaction, EventStore}
  alias VmuCore.FAS.AuthorizationRecord

  @doc """
  Match a single clearing record. Returns:
    - `{:matched, auth, transaction | nil}` — matched (transaction nil when the
      auth pre-dates the TRAM feed)
    - `:exception` — no auth found; record flagged for ops review
    - `:already_matched` — record was not in UNMATCHED status
  """
  @spec match_clearing_record(ClearingRecord.t()) ::
          {:matched, AuthorizationRecord.t(), Transaction.t() | nil}
          | :exception
          | :already_matched
  def match_clearing_record(%ClearingRecord{match_status: status} = rec)
      when status != "UNMATCHED" do
    Logger.debug("[TRAMS.MatchingEngine] #{rec.clearing_id} already #{status} — skipped")
    :already_matched
  end

  def match_clearing_record(%ClearingRecord{} = rec) do
    case find_authorization(rec) do
      nil ->
        mark_exception(rec)
        VmuCore.TRAMS.Telemetry.execute_match(:exception)
        :exception

      auth ->
        result = link_match(rec, auth)
        VmuCore.TRAMS.Telemetry.execute_match(:matched)
        result
    end
  end

  @doc """
  Sweep all UNMATCHED clearing records (batch entry point — called by the
  posting cycle job before posting, and available to ops for re-drives after
  a maintenance linkage correction).

  Returns `%{matched: n, exceptions: n}`.
  """
  @spec run_unmatched_sweep(non_neg_integer()) :: %{matched: non_neg_integer(), exceptions: non_neg_integer()}
  def run_unmatched_sweep(limit \\ 1000) do
    from(c in ClearingRecord,
      where: c.match_status == "UNMATCHED",
      order_by: [asc: c.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.reduce(%{matched: 0, exceptions: 0}, fn rec, acc ->
      case match_clearing_record(rec) do
        {:matched, _, _} -> Map.update!(acc, :matched, &(&1 + 1))
        :exception       -> Map.update!(acc, :exceptions, &(&1 + 1))
        _                -> acc
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Matching hierarchy
  # ---------------------------------------------------------------------------

  defp find_authorization(rec) do
    match_by_rrn(rec) || match_by_auth_code(rec) || match_by_pan_amount_date(rec)
  end

  # Tier 1: RRN + pan_token
  defp match_by_rrn(%{rrn: rrn, pan_token: pan_tok})
       when is_binary(rrn) and rrn != "" and is_binary(pan_tok) and pan_tok != "" do
    Repo.one(
      from a in AuthorizationRecord,
        where: a.rrn == ^rrn and a.pan_token == ^pan_tok and a.rc == "00",
        order_by: [desc: a.inserted_at],
        limit: 1
    )
  end

  defp match_by_rrn(_), do: nil

  # Tier 2: approval code + pan_token
  defp match_by_auth_code(%{auth_code: code, pan_token: pan_tok})
       when is_binary(code) and code != "" and is_binary(pan_tok) and pan_tok != "" do
    Repo.one(
      from a in AuthorizationRecord,
        where: a.approval_code == ^code and a.pan_token == ^pan_tok and a.rc == "00",
        order_by: [desc: a.inserted_at],
        limit: 1
    )
  end

  defp match_by_auth_code(_), do: nil

  # Tier 3: pan_token + amount (within tolerance) + transaction date window.
  # Weakest tier — only auths that still have no clearing linked are eligible,
  # so a redelivered file can't steal a different purchase's auth.
  defp match_by_pan_amount_date(%{pan_token: pan_tok, amount: amount} = rec)
       when is_binary(pan_tok) and pan_tok != "" and not is_nil(amount) do
    tolerance_pct = Application.get_env(:vmu_core, :trams_match_amount_tolerance_pct, 20)
    window_days   = Application.get_env(:vmu_core, :trams_match_date_window_days, 3)

    factor  = Decimal.div(Decimal.new(tolerance_pct), 100)
    min_amt = Decimal.sub(amount, Decimal.mult(amount, factor))
    max_amt = Decimal.add(amount, Decimal.mult(amount, factor))

    anchor_date = rec.transaction_date || rec.settlement_date || Date.utc_today()
    window_from = DateTime.new!(Date.add(anchor_date, -window_days), ~T[00:00:00], "Etc/UTC")
    window_to   = DateTime.new!(Date.add(anchor_date, window_days), ~T[23:59:59], "Etc/UTC")

    already_linked =
      from t in Transaction,
        where: not is_nil(t.clearing_id),
        select: t.fas_authorization_id

    Repo.one(
      from a in AuthorizationRecord,
        where: a.pan_token == ^pan_tok
           and a.rc == "00"
           and a.amount >= ^min_amt
           and a.amount <= ^max_amt
           and a.inserted_at >= ^window_from
           and a.inserted_at <= ^window_to
           and a.id not in subquery(already_linked),
        order_by: [desc: a.inserted_at],
        limit: 1
    )
  end

  defp match_by_pan_amount_date(_), do: nil

  # ---------------------------------------------------------------------------
  # Outcomes
  # ---------------------------------------------------------------------------

  defp link_match(rec, auth) do
    txn = EventStore.by_fas_authorization(auth.id)

    rec
    |> ClearingRecord.changeset(%{
      match_status:           "MATCHED",
      matched_auth_id:        auth.id,
      matched_transaction_id: txn && txn.transaction_id,
      account_id:             rec.account_id || auth.account_id
    })
    |> Repo.update!()

    if txn do
      advance_transaction(txn, rec)
    else
      Logger.debug("[TRAMS.MatchingEngine] Auth #{auth.id} matched but has no " <>
                   "TRAM transaction (pre-dates feed)")
    end

    {:matched, auth, txn}
  end

  defp advance_transaction(txn, rec) do
    case EventStore.append(txn.transaction_id, "settlement_matched", %{
           clearing_id:     rec.clearing_id,
           settled_amount:  rec.amount,
           settlement_date: rec.settlement_date,
           network:         rec.network,
           file_name:       rec.file_name
         }, actor: "network") do
      {:ok, %{transaction: updated}} ->
        updated
        |> Ecto.Changeset.change(
          settled_amount: rec.amount,
          clearing_id: rec.clearing_id
        )
        |> Repo.update!()

        EventStore.add_identifier(txn.transaction_id, %{
          rrn:       rec.rrn,
          auth_code: rec.auth_code,
          source:    "clearing"
        })

      {:error, reason} ->
        # e.g. transaction already POSTED via the settlement_core path and a
        # late clearing file arrives — linkage is recorded, state is left alone
        Logger.warning("[TRAMS.MatchingEngine] settlement_matched rejected for " <>
                       "#{txn.transaction_id}: #{inspect(reason)}")
    end
  end

  defp mark_exception(rec) do
    Logger.warning("[TRAMS.MatchingEngine] No auth match for clearing " <>
                   "#{rec.clearing_id} (rrn=#{rec.rrn} ac=#{rec.auth_code}) — EXCEPTION")

    rec
    |> ClearingRecord.changeset(%{match_status: "EXCEPTION"})
    |> Repo.update!()
  end
end
