defmodule VmuCore.FAS.Authorization do
  @moduledoc """
  Issuer authorization pipeline.

  Entry points:
    authorize/1 — `DaSwitchCore.FAS.Authorizer` callback. Called by da_issuer's
                  Ranch listener (MIP 7585 / VAP 8600) with a parsed ISOMsg.
                  Returns {:ok, response_iso_msg} | {:error, {:fas_declined, rc}}.
    process/1   — lower-level: takes a parsed %{mti:, fields:} map,
                  returns {:ok, rc, approval_code} | {:error, rc}.

  Hot-path call order:
    1. ISO 8583 parse (in-process, no I/O — done by da_issuer's packager before authorize/1 is called)
    2. BIN → logo params  (ETS, zero DB)
    3. PAN → account_id   (DB, single query — candidate for ETS caching)
    4. STAN duplicate check (DB, indexed)
    5. AccountStateCoordinator.authorize (Horde GenServer, in-memory OTB)
    6. STIP fallback if ASC unreachable (ETS)
    7. Async: persist fas_authorization + fas_pending_hold (Task)

  All unexpected errors return RC "96" (system malfunction) — fail-safe,
  never crash the caller.
  """

  @behaviour DaSwitchCore.FAS.Authorizer

  require Logger

  alias VmuCore.Shared.ParameterEngine
  alias VmuCore.CMS.{Account, AccountStateCoordinator, SupplementaryCard}
  alias VmuCore.FAS.{STIP, AuthorizationRecord, PendingHold, RiskAdapter, CardValidator, HotCardCache,
                     ReversalHandler, IncrementalHandler, CompletionHandler, HSM, EmvHandler}
  alias VmuCore.FAS.Telemetry, as: FasTelemetry
  alias VmuCore.FAS.ResponseCodes, as: RC
  alias VmuCore.Repo
  alias DaSwitchCore.Packagers.ISOMsg
  alias DaSwitchCore.MTIConverter
  import Ecto.Query

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  `DaSwitchCore.FAS.Authorizer` callback — called by da_issuer's Ranch listener
  with the already-unpacked request ISOMsg. Builds the full 0110/0210/0410
  response ISOMsg on approval; on decline, returns `{:fas_declined, rc}` so the
  caller (`DaIssuer.MessageProcessor`) can build the decline response itself —
  same convention already used by da_acquirer's on-us `RoutingProcessor`.
  """
  @impl DaSwitchCore.FAS.Authorizer
  def authorize(%ISOMsg{mti: mti} = iso_message) do
    fields = Map.new(ISOMsg.get_all_fields(iso_message))

    t0 = System.monotonic_time()
    raw_result = route(mti, fields)

    # EMV: verify ARQC and inject ARPC + issuer scripts into response (7G/7H)
    {iso_message, result} = handle_emv(iso_message, fields, raw_result)
    duration = System.monotonic_time() - t0

    case result do
      {:ok, rc, approval_code} ->
        FasTelemetry.execute_auth(rc, :approved, duration, %{mti: mti})
        response_mti = MTIConverter.to_response(mti)

        response_message =
          iso_message
          |> ISOMsg.set_mti(response_mti)
          |> ISOMsg.set(39, rc)
          |> then(fn msg ->
            if approval_code, do: ISOMsg.set(msg, 38, approval_code), else: msg
          end)

        {:ok, response_message}

      {:error, rc} ->
        FasTelemetry.execute_auth(rc, :declined, duration, %{mti: mti})
        {:error, {:fas_declined, rc}}
    end
  end

  # ---------------------------------------------------------------------------
  # MTI dispatch
  # ---------------------------------------------------------------------------

  # 0400 — reversal; always routed to ReversalHandler
  defp route("0400", fields), do: ReversalHandler.handle(fields)

  # 0200 — completion/advice; always routed to CompletionHandler
  defp route("0200", fields), do: CompletionHandler.handle(fields)

  # 0100/0210 — incremental when DE90 (Original Data Elements) is present
  defp route(mti, %{90 => _} = fields) do
    case IncrementalHandler.handle(fields, mti) do
      :not_found -> process(%{mti: mti, fields: fields})
      result     -> result
    end
  end

  # Standard authorization
  defp route(mti, fields), do: process(%{mti: mti, fields: fields})

  @doc """
  Process a parsed authorization request.

  `parsed` is the map returned by `Extractor.parse/1`:
    %{mti: "0100", fields: %{2 => pan, 3 => proc_code, 4 => amount, ...}}

  Also accepts the legacy admin-panel format for the visionplus_live.ex console:
    %{pan: pan, amount: decimal, channel: atom, mcc: string}

  Returns:
    {:ok, response_code, approval_code}   — approved
    {:error, response_code}               — declined
  """
  # Legacy format used by visionplus_live.ex admin console
  def process(%{pan: pan, amount: amount, channel: channel, mcc: mcc}) do
    amount_minor =
      amount
      |> Decimal.mult(100)
      |> Decimal.round(0)
      |> Decimal.to_integer()
      |> Integer.to_string()
      |> String.pad_leading(12, "0")

    synthetic_fields = %{
      2  => pan,
      4  => amount_minor,
      18 => mcc,
      22 => channel_to_pos_entry(channel),
      49 => "784"
    }

    process(%{mti: "0100", fields: synthetic_fields})
  end

  def process(%{fields: fields, mti: mti}) do
    ctx = build_context(fields, mti)

    with :ok                                           <- CardValidator.validate_expiry(ctx.expiry),
         :clean                                        <- HotCardCache.check(pan_token(ctx.pan)),
         {:ok, {sys_id, bank_id, logo_id}}            <- ParameterEngine.resolve_bin(ctx.pan),
         :ok                                           <- CardValidator.validate_channel_flags(sys_id, bank_id, logo_id, ctx),
         :ok                                           <- CardValidator.validate_cvv(sys_id, bank_id, logo_id, ctx),
         {:ok, {account_id, supp_id, sub_limit}}       <- resolve_account(ctx.pan),
         :ok                                           <- check_duplicate(ctx),
         :ok                                           <- maybe_verify_pin(ctx) do
      ctx
      |> Map.merge(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
                     account_id: account_id, supp_account_id: supp_id, sub_limit: sub_limit})
      |> run_authorization()
    else
      {:error, :expired_card}         -> decline(ctx, RC.expired_card(), %{path: "expired_card"})
      {:blocked, :lost_stolen}        -> decline(ctx, RC.pickup_card(), %{path: "hot_card_lost_stolen"})
      {:blocked, :fraud}              -> decline(ctx, RC.restricted_card(), %{path: "hot_card_fraud"})
      {:error, :no_bin_match}         -> decline(ctx, RC.no_bin_match(), %{path: "no_bin"})
      {:error, :channel_not_permitted} -> decline(ctx, RC.not_permitted(), %{path: "channel_not_permitted"})
      {:error, :invalid_cvv}          -> decline(ctx, RC.invalid_cvv(), %{path: "invalid_cvv"})
      {:error, :account_not_found}    -> decline(ctx, RC.invalid_card(), %{path: "no_account"})
      {:error, :duplicate_stan}       -> decline(ctx, RC.duplicate_stan(), %{path: "duplicate_stan"})
      {:error, :wrong_pin}            -> decline(ctx, RC.wrong_pin(), %{path: "wrong_pin"})
      {:error, :pin_blocked}          -> decline(ctx, RC.pin_tries_exceeded(), %{path: "pin_blocked"})

      {:error, reason} ->
        Logger.error("[FAS] Lookup error: #{inspect(reason)}")
        decline(ctx, RC.system_malfunction(), %{path: "lookup_error", reason: inspect(reason)})
    end
  end

  # ---------------------------------------------------------------------------
  # Authorization pipeline
  # ---------------------------------------------------------------------------

  defp run_authorization(%{account_id: account_id, amount: amount,
                            channel: channel, mcc: mcc,
                            supp_account_id: supp_id, sub_limit: sub_limit} = ctx) do
    auth_result = AccountStateCoordinator.authorize(account_id, amount,
                    channel: channel, mcc: mcc,
                    supplementary_account_id: supp_id,
                    sub_limit: sub_limit)
    handle_asc_result(auth_result, ctx)
  end

  defp handle_asc_result({:approved, _rc, _otb}, ctx) do
    {:ok, risk} = RiskAdapter.evaluate(ctx)

    risk_path = %{
      path: "asc_approved",
      risk_score: risk.score,
      risk_fired_rules: risk.fired_rules,
      risk_model_version: risk.model_version
    }

    case risk.decision do
      :decline ->
        decline(ctx, RC.do_not_honour(), Map.put(risk_path, :path, "risk_declined"))

      :review ->
        Logger.info("[FAS] mw_risk flagged :review account=#{ctx.account_id} " <>
                      "score=#{risk.score} rules=#{inspect(risk.fired_rules)}")
        approve(ctx, Map.put(risk_path, :path, "risk_reviewed_approved"))

      :approve ->
        approve(ctx, risk_path)
    end
  end

  defp handle_asc_result({:declined, rc, reason}, ctx) do
    Logger.info("[FAS] ASC declined account=#{ctx.account_id} rc=#{rc} reason=#{reason}")
    decline(ctx, rc, %{path: "asc_declined", reason: inspect(reason)})
  end

  # ASC unreachable — attempt STIP stand-in
  defp handle_asc_result({:error, reason}, %{sys_id: sys_id, logo_id: logo_id} = ctx)
       when reason in [:timeout, :noproc] do
    Logger.warning("[FAS] ASC unreachable (#{reason}) — attempting STIP for #{logo_id}")

    case STIP.authorize(sys_id, logo_id, ctx.amount) do
      {:stip_approved, rc} ->
        FasTelemetry.execute_stip(rc)
        approve(ctx, %{path: "stip_approved", stip: true})

      {:stip_declined, rc} ->
        FasTelemetry.execute_stip(rc)
        decline(ctx, rc, %{path: "stip_declined", stip: true})
    end
  end

  defp handle_asc_result({:error, reason}, ctx) do
    Logger.error("[FAS] ASC unexpected error: #{inspect(reason)}")
    decline(ctx, RC.system_malfunction(), %{path: "asc_error", reason: inspect(reason)})
  end

  # ---------------------------------------------------------------------------
  # Approve / decline helpers
  # ---------------------------------------------------------------------------

  defp approve(ctx, decision_path) do
    approval_code = generate_approval_code()
    stip_used     = Map.get(decision_path, :stip, false)

    persist_async(ctx, RC.approved(), approval_code, stip_used, decision_path,
                  create_hold: true)

    {:ok, RC.approved(), approval_code}
  end

  defp decline(ctx, rc, decision_path) do
    persist_async(ctx, rc, nil, false, decision_path, create_hold: false)
    {:error, rc}
  end

  # ---------------------------------------------------------------------------
  # Async persistence — never blocks the response path
  # ---------------------------------------------------------------------------

  defp persist_async(ctx, rc, approval_code, stip_used, decision_path, opts) do
    Task.start(fn ->
      attrs = %{
        pan_token:     pan_token(ctx.pan),
        account_id:    Map.get(ctx, :account_id),
        logo_id:       Map.get(ctx, :logo_id),
        sys_id:        Map.get(ctx, :sys_id),
        amount:        ctx.amount,
        currency:      ctx.currency,
        mcc:           ctx.mcc,
        channel:       to_string(ctx.channel),
        mti:           ctx.mti,
        rc:            rc,
        approval_code: approval_code,
        stan:          ctx.stan,
        rrn:           ctx.rrn,
        terminal_id:   ctx.terminal_id,
        merchant_id:   ctx.merchant_id,
        stip_used:     stip_used,
        risk_score:    Map.get(decision_path, :risk_score),
        decision_path: decision_path
      }

      case Repo.insert(AuthorizationRecord.changeset(%AuthorizationRecord{}, attrs)) do
        {:ok, record} ->
          if Keyword.get(opts, :create_hold) && ctx[:account_id] do
            create_pending_hold(record, ctx)
          end

          # TRAM feed (TRAM-P2 2B) — fail-safe, already off the hot path
          VmuCore.TRAMS.AuthConsumer.record_authorization(record, ctx, decision_path)

        {:error, cs} ->
          Logger.error("[FAS] Failed to persist auth record: #{inspect(cs.errors)}")
      end
    end)
  end

  defp create_pending_hold(auth_record, ctx) do
    attrs = %{
      fas_authorization_id: auth_record.id,
      account_id:           ctx.account_id,
      hold_amount:          ctx.amount,
      hold_type:            "standard",
      expires_at:           DateTime.add(DateTime.utc_now(), 7, :day)
    }

    case Repo.insert(PendingHold.changeset(%PendingHold{}, attrs)) do
      {:ok, _}   -> :ok
      {:error, cs} ->
        Logger.error("[FAS] Failed to create pending hold: #{inspect(cs.errors)}")
    end
  end

  # ---------------------------------------------------------------------------
  # Context builder
  # ---------------------------------------------------------------------------

  defp build_context(fields, mti) do
    %{
      pan:         Map.get(fields, 2, ""),
      # DE14 = card expiry, format YYMM — optional, many EMV/card-present txns omit it
      expiry:      Map.get(fields, 14),
      amount:      fields |> Map.get(4, "0") |> parse_amount(),
      # DE18 = MCC in acquirer flow; DE26 = POS capture code (fallback)
      mcc:         Map.get(fields, 18) || Map.get(fields, 26),
      channel:     fields |> Map.get(22, "000") |> detect_channel(),
      currency:    Map.get(fields, 49, "000"),
      stan:        Map.get(fields, 11),
      rrn:         Map.get(fields, 37),
      terminal_id: Map.get(fields, 41),
      merchant_id: Map.get(fields, 42),
      mti:         mti,
      fields:      fields
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp resolve_account(pan) do
    token = pan_token(pan)

    case Repo.one(from a in Account, where: a.pan_token == ^token, select: a.account_id) do
      nil ->
        {:error, :account_not_found}

      account_id ->
        case SupplementaryCard.lookup_by_account(account_id) do
          {primary_id, sub_limit} ->
            # Supplementary card — auth runs against the primary account; sub_limit enforced in ASC
            {:ok, {primary_id, account_id, sub_limit}}

          nil ->
            # Primary (standalone) card
            {:ok, {account_id, nil, nil}}
        end
    end
  end

  defp check_duplicate(%{stan: nil}), do: :ok
  defp check_duplicate(%{stan: stan, terminal_id: tid, pan: pan, amount: amount}) do
    token  = pan_token(pan)
    window = DateTime.add(DateTime.utc_now(), -60, :second)

    dupe? =
      Repo.exists?(
        from r in AuthorizationRecord,
          where: r.stan == ^stan
             and r.terminal_id == ^tid
             and r.pan_token == ^token
             and r.amount == ^amount
             and r.inserted_at >= ^window
             and r.rc == ^RC.approved()
      )

    if dupe?, do: {:error, :duplicate_stan}, else: :ok
  end

  defp pan_token(pan) do
    :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)
  end

  defp generate_approval_code do
    :rand.uniform(999_999) |> Integer.to_string() |> String.pad_leading(6, "0")
  end

  # Amount in DE4 is in minor units (e.g. "000000001500" = AED 15.00)
  defp parse_amount(str) do
    case Integer.parse(str) do
      {int, ""} -> Decimal.div(Decimal.new(int), Decimal.new(100))
      _         -> Decimal.new(0)
    end
  end

  # POS entry mode first 2 digits:
  # 00 = unknown, 01 = manual/keyed, 02 = magstripe, 05 = chip, 07 = contactless
  # 90 = magstripe fallback, 91 = contactless magstripe
  defp detect_channel(<<"07", _::binary>>), do: :contactless
  defp detect_channel(<<"91", _::binary>>), do: :contactless
  defp detect_channel(<<"05", _::binary>>), do: :pos
  defp detect_channel(<<"02", _::binary>>), do: :pos
  defp detect_channel(<<"90", _::binary>>), do: :pos
  defp detect_channel(<<"01", _::binary>>), do: :ecom
  defp detect_channel(_),                   do: :pos

  # Reverse map: channel atom → ISO 8583 POS entry mode code (for legacy shim)
  defp channel_to_pos_entry(:contactless), do: "071"
  defp channel_to_pos_entry(:atm),         do: "011"
  defp channel_to_pos_entry(:ecom),        do: "010"
  defp channel_to_pos_entry(_),            do: "051"

  # ---------------------------------------------------------------------------
  # PIN verification helper (7E)
  # ---------------------------------------------------------------------------

  # Only verify PIN when DE52 is present in the request
  defp maybe_verify_pin(%{fields: %{52 => pin_block}, pan: pan} = ctx) do
    case HSM.verify_pin(pin_block, pan, pan_token(pan)) do
      :ok                    -> :ok
      {:error, :pin_not_set} -> :ok  # card not yet personalised — fail-open
      {:error, reason}       -> {:error, reason}
    end
  end

  defp maybe_verify_pin(_ctx), do: :ok

  # ---------------------------------------------------------------------------
  # ARQC check + ARPC/issuer-script injection (7G + 7H)
  # ---------------------------------------------------------------------------

  # Called from authorize/1 after the MTI route produces a result.
  # Verifies ARQC (decline on fail) and builds DE55 response (ARPC + scripts).
  defp handle_emv(iso_message, fields, {:ok, rc, approval_code}) do
    pan_token = pan_token(Map.get(fields, 2, ""))
    ctx_for_emv = %{fields: fields, pan_token: pan_token}

    # ARQC verification — decline on mismatch (configurable via arqc_decline_on_fail)
    result =
      case EmvHandler.verify_arqc(ctx_for_emv) do
        {:error, :arqc_mismatch} ->
          if Application.get_env(:vmu_core, :arqc_decline_on_fail, true) do
            Logger.info("[FAS EMV] ARQC mismatch — declining")
            {:error, RC.do_not_honour()}
          else
            {:ok, rc, approval_code}
          end

        _ ->
          {:ok, rc, approval_code}
      end

    # Build DE55 response and inject into ISOMsg
    case result do
      {:ok, final_rc, final_ac} ->
        script_cmds = EmvHandler.script_commands(%{}, final_rc)

        iso_message =
          case EmvHandler.build_response_de55(ctx_for_emv, final_rc, script_cmds) do
            {:ok, de55_bin} -> EmvHandler.inject_de55(iso_message, de55_bin)
            {:error, _}     -> iso_message
          end

        {iso_message, {:ok, final_rc, final_ac}}

      {:error, _} = err ->
        {iso_message, err}
    end
  end

  defp handle_emv(iso_message, _fields, {:error, _} = err), do: {iso_message, err}
end
