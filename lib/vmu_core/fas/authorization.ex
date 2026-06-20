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
  alias VmuCore.CMS.{Account, AccountStateCoordinator}
  alias VmuCore.FAS.{STIP, AuthorizationRecord, PendingHold}
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

    case process(%{mti: mti, fields: fields}) do
      {:ok, rc, approval_code} ->
        response_mti = MTIConverter.to_response(mti)

        response_message =
          iso_message
          |> ISOMsg.set_mti(response_mti)
          |> ISOMsg.set(39, rc)
          |> ISOMsg.set(38, approval_code)

        {:ok, response_message}

      {:error, rc} ->
        {:error, {:fas_declined, rc}}
    end
  end

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

    with {:ok, {sys_id, _bank_id, logo_id}} <- ParameterEngine.resolve_bin(ctx.pan),
         {:ok, account_id}                   <- resolve_account(ctx.pan),
         :ok                                 <- check_duplicate(ctx) do
      ctx
      |> Map.merge(%{sys_id: sys_id, logo_id: logo_id, account_id: account_id})
      |> run_authorization()
    else
      {:error, :no_bin_match}   -> decline(ctx, RC.no_bin_match(), %{path: "no_bin"})
      {:error, :account_not_found} -> decline(ctx, RC.invalid_card(), %{path: "no_account"})
      {:error, :duplicate_stan} -> decline(ctx, RC.duplicate_stan(), %{path: "duplicate_stan"})

      {:error, reason} ->
        Logger.error("[FAS] Lookup error: #{inspect(reason)}")
        decline(ctx, RC.system_malfunction(), %{path: "lookup_error", reason: inspect(reason)})
    end
  end

  # ---------------------------------------------------------------------------
  # Authorization pipeline
  # ---------------------------------------------------------------------------

  defp run_authorization(%{account_id: account_id, amount: amount,
                            channel: channel, mcc: mcc} = ctx) do
    auth_result = AccountStateCoordinator.authorize(account_id, amount,
                    channel: channel, mcc: mcc)
    handle_asc_result(auth_result, ctx)
  end

  defp handle_asc_result({:approved, _rc, _otb}, ctx) do
    approve(ctx, %{path: "asc_approved"})
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
        approve(ctx, %{path: "stip_approved", stip: true})
        |> then(fn result ->
          # Tag the authorization record as STIP
          result
        end)

      {:stip_declined, rc} ->
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
        decision_path: decision_path
      }

      case Repo.insert(AuthorizationRecord.changeset(%AuthorizationRecord{}, attrs)) do
        {:ok, record} ->
          if Keyword.get(opts, :create_hold) && ctx[:account_id] do
            create_pending_hold(record, ctx)
          end

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
      nil        -> {:error, :account_not_found}
      account_id -> {:ok, account_id}
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
end
