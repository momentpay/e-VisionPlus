defmodule VmuCore.FAS.ReversalHandler do
  @moduledoc """
  Handles MTI 0400 (reversal) messages (FAS-P6 6A + 6B).

  ## Match strategy

  1. STAN + terminal_id + pan_token — within a 60-minute lookback window.
     Covers the common case where the terminal retransmits a reversal shortly
     after the original authorization (network timeout, POS restart).

  2. Fallback: DE38 approval_code — allows same-day or next-day reversals
     where the STAN window has expired but the acquirer echoes the original
     approval code in DE38.

  ## On match (6A)

  - Sets `fas_pending_holds.reversal_at` (hold leaves the active-aging view)
  - Calls `AccountStateCoordinator.reverse/3` to restore OTB in memory
  - Persists a new `fas_authorization` record with mti "0400" + rc "00"
  - Returns `{:ok, "00", nil}` — DE38 echoed from request by `authorize/1`

  ## On no match (6B)

  - Logs an exception row to `fas_reversal_exceptions` (status: pending)
  - Returns `{:error, "25"}` — RC "25" = unable to locate record
  """

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.FAS.{AuthorizationRecord, PendingHold, ExceptionQueue}
  alias VmuCore.FAS.ResponseCodes, as: RC
  alias VmuCore.CMS.AccountStateCoordinator

  @doc """
  Process a 0400 reversal. `fields` is the DE map from `ISOMsg.get_all_fields/1`.
  Returns `{:ok, rc, nil}` on success or `{:error, rc}` on failure.
  """
  @spec handle(map()) :: {:ok, String.t(), nil} | {:error, String.t()}
  def handle(fields) do
    pan           = Map.get(fields, 2, "")
    stan          = Map.get(fields, 11)
    approval_code = Map.get(fields, 38)
    tid           = Map.get(fields, 41)
    pan_tok       = pan_token(pan)

    case find_original_auth(stan, tid, pan_tok, approval_code) do
      nil ->
        Logger.warning("[FAS Reversal] No match: stan=#{stan} ac=#{approval_code} tid=#{tid}")
        ExceptionQueue.insert_reversal_exception(fields, pan_tok)
        {:error, RC.no_match()}

      auth ->
        do_reverse(auth, fields)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp find_original_auth(stan, tid, pan_tok, approval_code) do
    # Try STAN + terminal_id within 60-minute window first
    stan_match =
      if stan && tid do
        window = DateTime.add(DateTime.utc_now(), -3600, :second)

        Repo.one(
          from r in AuthorizationRecord,
            where: r.stan == ^stan
               and r.terminal_id == ^tid
               and r.pan_token == ^pan_tok
               and r.rc == "00"
               and r.inserted_at >= ^window,
            order_by: [desc: r.inserted_at],
            limit: 1
        )
      end

    # Fallback: match on approval_code (no time limit — allows T+1 reversals)
    stan_match ||
      if approval_code && pan_tok != "" do
        Repo.one(
          from r in AuthorizationRecord,
            where: r.approval_code == ^approval_code
               and r.pan_token == ^pan_tok
               and r.rc == "00",
            order_by: [desc: r.inserted_at],
            limit: 1
        )
      end
  end

  defp do_reverse(auth, fields) do
    result =
      Repo.transaction(fn ->
        release_hold(auth)
        persist_reversal_record(auth, fields)
      end)

    case result do
      {:ok, _} ->
        restore_otb(auth)
        # TRAM feed (TRAM-P2 2C) — off the response path, fail-safe
        Task.start(fn -> VmuCore.TRAMS.AuthConsumer.record_reversal(auth, fields) end)
        {:ok, RC.approved(), nil}

      {:error, reason} ->
        Logger.error("[FAS Reversal] Transaction failed for auth #{auth.id}: #{inspect(reason)}")
        {:error, RC.system_malfunction()}
    end
  end

  defp release_hold(auth) do
    hold =
      Repo.one(
        from h in PendingHold,
          where: h.fas_authorization_id == ^auth.id
             and is_nil(h.reversal_at)
             and is_nil(h.cleared_at),
          lock: "FOR UPDATE"
      )

    if hold do
      hold
      |> PendingHold.reverse_changeset(DateTime.utc_now())
      |> Repo.update!()
    end
  end

  defp persist_reversal_record(auth, fields) do
    attrs = %{
      pan_token:     auth.pan_token,
      account_id:    auth.account_id,
      logo_id:       auth.logo_id,
      sys_id:        auth.sys_id,
      amount:        auth.amount,
      currency:      auth.currency || "AED",
      mcc:           auth.mcc,
      channel:       auth.channel || "pos",
      mti:           "0400",
      rc:            RC.approved(),
      approval_code: nil,
      stan:          Map.get(fields, 11),
      rrn:           Map.get(fields, 37),
      terminal_id:   Map.get(fields, 41),
      merchant_id:   Map.get(fields, 42),
      decision_path: %{path: "reversal_matched", original_auth_id: auth.id}
    }

    %AuthorizationRecord{}
    |> AuthorizationRecord.changeset(attrs)
    |> Repo.insert!()
  end

  # OTB restore is outside the DB transaction — ASC GenServer does not
  # participate in Ecto transactions.
  defp restore_otb(%{account_id: nil}), do: :ok

  defp restore_otb(auth) do
    case AccountStateCoordinator.reverse(auth.account_id, auth.stan, auth.amount) do
      {:ok, _new_otb} -> :ok
      {:error, reason} ->
        Logger.warning("[FAS Reversal] ASC.reverse failed account=#{auth.account_id}: " <>
                       "#{inspect(reason)} — OTB not restored in memory (DB hold is released)")
    end
  end

  defp pan_token(pan),
    do: :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)
end
