defmodule VmuCore.FAS.CompletionHandler do
  @moduledoc """
  Handles MTI 0200 (completion / advice) messages (FAS-P6 6D).

  ## When is 0200 sent?

  Hotel and car-rental merchants send a 0200 at checkout to finalize the
  transaction amount. The actual amount may differ from the original preauth:

  - Amount < original: customer checked out early, or incidentals not incurred.
    Trim the hold to the final amount; credit OTB for the difference.
    The hold is NOT cleared — it remains until settlement_core confirms it
    via `SettlementPostingAdapter.confirm_one/1`.

  - Amount > original: rare (acquirer should have sent an incremental).
    Log a warning but accept — the hold stays at the original amount. OTB is
    NOT further debited (hold already covers the original amount and the
    over-run is an acquirer-side issue to resolve at clearing).

  - Amount == original: no change to hold or OTB.

  ## Response

  RC "00" always (advice messages are not declined by issuers — the transaction
  is already captured at the POS). A new approval_code is generated and returned
  in DE38.

  ## Matching

  Primary: DE38 (original approval_code) + pan_token.
  If no match: accept anyway (advice cannot be declined) — log warning and
  write an "unmatched_completion" fas_authorization record for ops visibility.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.FAS.{AuthorizationRecord, PendingHold}
  alias VmuCore.FAS.ResponseCodes, as: RC
  alias VmuCore.CMS.AccountStateCoordinator

  @doc """
  Handle a 0200 completion / advice message.
  Always returns `{:ok, "00", approval_code}` — advice messages are not declined.
  """
  @spec handle(map()) :: {:ok, String.t(), String.t()}
  def handle(fields) do
    final_amount  = fields |> Map.get(4, "0") |> parse_amount()
    approval_code = Map.get(fields, 38)
    pan           = Map.get(fields, 2, "")
    pan_tok       = pan_token(pan)

    original_auth = find_original_auth(approval_code, pan_tok)
    new_approval  = generate_approval_code()

    if is_nil(original_auth) do
      Logger.warning("[FAS Completion] No original auth found ac=#{approval_code} — " <>
                     "writing unmatched completion record")
      persist_completion_record(nil, final_amount, new_approval, fields, "unmatched_completion")
    else
      process_completion(original_auth, final_amount, new_approval, fields)

      # TRAM feed (TRAM-P2 2E) — matched completions move the TRAM
      # transaction to CLEARED; unmatched ones have no aggregate to advance
      Task.start(fn ->
        VmuCore.TRAMS.AuthConsumer.record_completion(original_auth, final_amount, fields)
      end)
    end

    {:ok, RC.approved(), new_approval}
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

  defp process_completion(auth, final_amount, new_approval, fields) do
    hold = find_active_hold(auth.id)

    original_amount = (hold && hold.hold_amount) || auth.amount

    cmp = Decimal.compare(final_amount, original_amount)

    cond do
      cmp == :lt ->
        # Trim hold, restore OTB for the difference
        trim_and_persist(auth, hold, original_amount, final_amount, new_approval, fields)

      cmp == :gt ->
        # Over-run — log warning, don't adjust OTB
        Logger.warning("[FAS Completion] Final #{final_amount} > original #{original_amount} " <>
                       "for auth #{auth.id} — hold unchanged, OTB not debited further")
        persist_completion_record(auth, final_amount, new_approval, fields, "completion_overrun")

      true ->
        # Exact match — no adjustment needed
        persist_completion_record(auth, final_amount, new_approval, fields, "completion_exact")
    end
  end

  defp trim_and_persist(auth, hold, original_amount, final_amount, new_approval, fields) do
    delta = Decimal.sub(original_amount, final_amount)

    Repo.transaction(fn ->
      if hold do
        hold
        |> PendingHold.set_hold_amount_changeset(final_amount)
        |> Repo.update!()
      end

      persist_completion_record(auth, final_amount, new_approval, fields, "completion_trim")
    end)

    # Restore OTB for the trimmed delta (outside transaction — ASC is in-memory)
    if auth.account_id && Decimal.compare(delta, Decimal.new(0)) == :gt do
      AccountStateCoordinator.credit_open_to_buy(auth.account_id, delta)
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

  defp persist_completion_record(auth, amount, approval_code, fields, path) do
    attrs = %{
      pan_token:     (auth && auth.pan_token) || pan_token(Map.get(fields, 2, "")),
      account_id:    auth && auth.account_id,
      logo_id:       auth && auth.logo_id,
      sys_id:        auth && auth.sys_id,
      amount:        amount,
      currency:      (auth && auth.currency) || Map.get(fields, 49, "AED"),
      mcc:           auth && auth.mcc,
      channel:       (auth && auth.channel) || "pos",
      mti:           "0200",
      rc:            RC.approved(),
      approval_code: approval_code,
      stan:          Map.get(fields, 11),
      rrn:           Map.get(fields, 37),
      terminal_id:   Map.get(fields, 41),
      merchant_id:   Map.get(fields, 42),
      decision_path: %{path: path, original_auth_id: auth && auth.id}
    }

    case Repo.insert(AuthorizationRecord.changeset(%AuthorizationRecord{}, attrs)) do
      {:ok, _}     -> :ok
      {:error, cs} ->
        Logger.error("[FAS Completion] Failed to persist record: #{inspect(cs.errors)}")
    end
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
