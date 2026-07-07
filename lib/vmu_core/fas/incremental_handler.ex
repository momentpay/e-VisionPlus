defmodule VmuCore.FAS.IncrementalHandler do
  @moduledoc """
  Handles incremental authorization (FAS-P6 6C).

  ## What is an incremental authorization?

  Hotel and car-rental merchants preauthorize an estimated amount at check-in,
  then send incremental authorizations to increase the hold as additional
  charges accumulate (room service, minibar, extra nights).

  ## Detection

  An 0100 message is treated as incremental when DE90 (Original Data Elements)
  is present. DE90 carries the MTI + STAN + date + time of the original
  authorization. The presence of DE90 unambiguously links this to a prior auth.

  ## Amount convention

  DE4 in an incremental = the NEW TOTAL authorized amount, not the delta.
  (Visa and Mastercard both use this convention.) The delta is derived:
    delta = new_total - original_hold_amount

  If delta <= 0 (acquirer is trimming the hold), processing falls through to
  `CompletionHandler` semantics — hold is reduced, OTB is credited for the
  difference.

  ## On success

  - Updates `fas_pending_holds.hold_amount` to new_total
  - Decrements OTB by delta via `AccountStateCoordinator.authorize/3`
  - Persists a new `fas_authorization` record with a fresh approval_code,
    mti "0100", decision_path `{path: "incremental", original_auth_id: ...}`
  - Returns `{:ok, "00", new_approval_code}`

  ## On no-match

  Falls back to standard authorization pipeline.  The caller (`authorization.ex`)
  handles this by detecting the `:not_found` return and routing to `process/1`.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.FAS.{AuthorizationRecord, PendingHold}
  alias VmuCore.FAS.ResponseCodes, as: RC
  alias VmuCore.CMS.AccountStateCoordinator

  @doc """
  Handle an incremental authorization.

  Returns:
    `{:ok, rc, approval_code}` — incremental granted
    `{:error, rc}`             — declined (ASC or no OTB)
    `:not_found`               — no original auth found; caller should fall back to standard auth
  """
  @spec handle(map(), String.t()) ::
    {:ok, String.t(), String.t()} | {:error, String.t()} | :not_found
  def handle(fields, mti) do
    new_total     = fields |> Map.get(4, "0") |> parse_amount()
    approval_code = Map.get(fields, 38)  # DE38 = original approval code echoed by acquirer
    pan           = Map.get(fields, 2, "")
    pan_tok       = pan_token(pan)
    currency      = Map.get(fields, 49, "AED")

    original_auth = find_original_auth(approval_code, pan_tok)

    if is_nil(original_auth) do
      Logger.debug("[FAS Incremental] No original auth found for ac=#{approval_code} — " <>
                   "falling back to standard auth")
      :not_found
    else
      do_increment(original_auth, new_total, currency, fields, mti)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp find_original_auth(approval_code, pan_tok) when is_binary(approval_code) and
       byte_size(approval_code) > 0 do
    Repo.one(
      from r in AuthorizationRecord,
        where: r.approval_code == ^approval_code
           and r.pan_token == ^pan_tok
           and r.rc == "00",
        order_by: [desc: r.inserted_at],
        limit: 1
    )
  end

  defp find_original_auth(_, _), do: nil

  defp do_increment(auth, new_total, currency, fields, mti) do
    original_hold = find_active_hold(auth.id)

    original_amount = (original_hold && original_hold.hold_amount) || auth.amount
    delta           = Decimal.sub(new_total, original_amount)

    cond do
      Decimal.compare(delta, Decimal.new(0)) == :lt ->
        # Trim — reduce hold, credit OTB for difference
        trim_hold(auth, original_hold, new_total, fields, mti)

      Decimal.compare(delta, Decimal.new(0)) == :eq ->
        # No change — idempotent re-authorization
        {:ok, RC.approved(), generate_approval_code()}

      true ->
        # Increase — deduct delta from OTB
        extend_hold(auth, original_hold, new_total, delta, currency, fields, mti)
    end
  end

  defp find_active_hold(auth_id) do
    Repo.one(
      from h in PendingHold,
        where: h.fas_authorization_id == ^auth_id
           and is_nil(h.cleared_at)
           and is_nil(h.reversal_at),
        limit: 1
    )
  end

  defp extend_hold(auth, original_hold, new_total, delta, currency, fields, mti) do
    account_id = auth.account_id

    # Attempt to debit OTB for the delta via ASC
    asc_result =
      if account_id do
        AccountStateCoordinator.authorize(account_id, delta,
          channel: (auth.channel || "pos") |> String.to_existing_atom(),
          mcc: auth.mcc,
          currency: currency)
      else
        {:approved, RC.approved(), nil, nil}
      end

    case asc_result do
      {:approved, _rc, _otb, _cotb} ->
        new_approval = generate_approval_code()

        Repo.transaction(fn ->
          update_hold(original_hold, new_total)
          persist_incremental_record(auth, new_total, new_approval, fields, mti)
        end)

        # TRAM feed (TRAM-P2 2D) — off the response path, fail-safe
        Task.start(fn ->
          VmuCore.TRAMS.AuthConsumer.record_incremental(auth, new_total, new_approval, :extend)
        end)

        {:ok, RC.approved(), new_approval}

      {:declined, rc, reason} ->
        Logger.info("[FAS Incremental] ASC declined increment: account=#{account_id} " <>
                    "delta=#{delta} rc=#{rc} reason=#{reason}")
        {:error, rc}

      {:error, _reason} ->
        {:error, RC.system_malfunction()}
    end
  end

  # Trim: new_total < existing hold — reduce hold and restore OTB difference
  defp trim_hold(auth, original_hold, new_total, fields, mti) do
    if original_hold do
      delta = Decimal.sub(original_hold.hold_amount, new_total)

      Repo.transaction(fn ->
        original_hold
        |> PendingHold.set_hold_amount_changeset(new_total)
        |> Repo.update!()

        new_approval = generate_approval_code()
        persist_incremental_record(auth, new_total, new_approval, fields, mti)
        new_approval
      end)
      |> case do
        {:ok, new_approval} ->
          # Restore OTB for the difference
          if auth.account_id do
            AccountStateCoordinator.credit_open_to_buy(auth.account_id, delta)
          end

          # TRAM feed (TRAM-P2 2D) — partial reversal, fail-safe
          Task.start(fn ->
            VmuCore.TRAMS.AuthConsumer.record_incremental(auth, new_total, new_approval, :trim)
          end)

          {:ok, RC.approved(), new_approval}

        {:error, reason} ->
          Logger.error("[FAS Incremental] Trim failed: #{inspect(reason)}")
          {:error, RC.system_malfunction()}
      end
    else
      {:ok, RC.approved(), generate_approval_code()}
    end
  end

  defp update_hold(nil, _new_total), do: :ok

  defp update_hold(hold, new_total) do
    hold
    |> PendingHold.set_hold_amount_changeset(new_total)
    |> Repo.update!()
  end

  defp persist_incremental_record(auth, new_total, approval_code, fields, mti) do
    attrs = %{
      pan_token:     auth.pan_token,
      account_id:    auth.account_id,
      logo_id:       auth.logo_id,
      sys_id:        auth.sys_id,
      amount:        new_total,
      currency:      auth.currency || "AED",
      mcc:           auth.mcc,
      channel:       auth.channel || "pos",
      mti:           mti,
      rc:            RC.approved(),
      approval_code: approval_code,
      stan:          Map.get(fields, 11),
      rrn:           Map.get(fields, 37),
      terminal_id:   Map.get(fields, 41),
      merchant_id:   Map.get(fields, 42),
      decision_path: %{path: "incremental", original_auth_id: auth.id}
    }

    %AuthorizationRecord{}
    |> AuthorizationRecord.changeset(attrs)
    |> Repo.insert!()
  end

  defp parse_amount(str) do
    case Integer.parse(str) do
      {int, ""} -> Decimal.div(Decimal.new(int), Decimal.new(100))
      _         -> Decimal.new(0)
    end
  end

  defp pan_token(pan),
    do: :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)

  defp generate_approval_code,
    do: :rand.uniform(999_999) |> Integer.to_string() |> String.pad_leading(6, "0")
end
