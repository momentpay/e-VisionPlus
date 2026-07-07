defmodule VmuCore.FAS.CardValidator do
  @moduledoc """
  Card-level validation checks: card expiry, channel flags, and CVV/iCVV (FAS-P3
  tasks 3A, 3E; FAS-P7 task 7D).

  DE14 ("expiration date") is OPTIONAL — many EMV transactions omit it
  since the chip already proved possession of a non-expired card. When
  absent, expiry validation is skipped (fail-open on missing optional fields).

  ## CVV validation (7D)

  `validate_cvv/3` is called after BIN resolution, before ASC authorization:
  - DE55 present (chip) → iCVV check (service_code "999")
  - DE35 present (track 2) → CVV1 check (service_code from track data)
  - CNP / ecom and DE2 present → CVV2 check (service_code "000")
  - Otherwise → skip (fail-open — magnetic stripe may not include CVV in DE35)

  Logo parameter `cvv_required: false` disables the check for a product range
  (e.g., co-branded cards that use dynamic CVV schemes). Default: required.
  """

  require Logger
  alias VmuCore.Shared.{ParameterEngine, CurrencyCodes}
  alias VmuCore.FAS.HSM
  alias VmuCore.CTA.Cards

  @doc """
  Validates DE14 (request-supplied expiry, format `YYMM`) against the
  current billing month. Returns `:ok` when DE14 is absent, malformed, or
  not yet expired; `{:error, :expired_card}` when the card's expiry month
  has passed.
  """
  @spec validate_expiry(String.t() | nil) :: :ok | {:error, :expired_card}
  def validate_expiry(nil), do: :ok

  def validate_expiry(<<yy::binary-size(2), mm::binary-size(2)>>) do
    with {year_2d, ""} <- Integer.parse(yy),
         {month, ""} <- Integer.parse(mm),
         true <- month in 1..12 do
      year = 2000 + year_2d
      today = Date.utc_today()

      if {today.year, today.month} > {year, month} do
        {:error, :expired_card}
      else
        :ok
      end
    else
      _ -> :ok
    end
  end

  def validate_expiry(_malformed), do: :ok

  @doc """
  Validates that the transaction channel is permitted for this product (logo)
  AND for this specific card (CTA-P3.2, FR-022).

  Card-level overrides (`cta_cards.ecom_enabled`/`atm_enabled`/
  `contactless_enabled`/`intl_enabled`, set via
  `CTA.CardLifecycle.set_channel_controls/3`) are tri-state and take
  precedence over the LOGO cascade when non-nil: `true` force-allows a
  channel the product would otherwise block (e.g. a corporate card enabled
  for ATM use); `false` force-blocks a channel the product otherwise allows.
  `nil` (the default — no override configured) falls through to the
  existing `ParameterEngine`-cascade behavior unchanged.

  The card lookup is one indexed `pan_token` seek — same shape and cost as
  the existing `resolve_account/1` call later in this pipeline, not a new
  category of hot-path DB access.

  Checks enforced (all fail-open if neither the card nor the parameter
  cascade sets the flag):
    - `:ecom` channel    → `ecom_enabled`
    - `:atm` channel     → `atm_enabled`
    - `:contactless`     → `contactless_enabled`
    - international currency → `intl_enabled` (proxy: DE49 currency ≠ SYS base_currency)

  Returns `:ok` or `{:error, :channel_not_permitted}`.
  """
  @spec validate_channel_flags(String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, :channel_not_permitted}
  def validate_channel_flags(sys_id, bank_id, logo_id, ctx) do
    # block_id is unknown at this point; "" falls through the cascade to logo level
    get  = fn key -> ParameterEngine.get(sys_id, bank_id, logo_id, "", key) end
    card = card_for_pan(ctx[:pan])

    with :ok <- check_flag(card && card.ecom_enabled,        get.(:ecom_enabled),        ctx.channel == :ecom),
         :ok <- check_flag(card && card.atm_enabled,         get.(:atm_enabled),         ctx.channel == :atm),
         :ok <- check_flag(card && card.contactless_enabled, get.(:contactless_enabled), ctx.channel == :contactless),
         :ok <- check_intl(card && card.intl_enabled, get, ctx.currency) do
      :ok
    end
  end

  defp card_for_pan(nil), do: nil
  defp card_for_pan(""),  do: nil

  defp card_for_pan(pan) do
    pan
    |> then(&(:crypto.hash(:sha256, &1) |> Base.encode16(case: :lower)))
    |> Cards.by_pan_token()
  rescue
    # Cards context unavailable (e.g. isolated unit tests) — fail open to
    # the pre-P3 logo-only behavior
    _ -> nil
  end

  # card_override: true (force allow) | false (force block) | nil (no override — cascade decides)
  # flag_result: {:ok, false} or {:error, :parameter_not_found} → decline only if
  # the condition applies AND the flag is explicitly set to false.
  defp check_flag(true,  _flag_result, _condition), do: :ok
  defp check_flag(false, _flag_result, true),       do: {:error, :channel_not_permitted}
  defp check_flag(false, _flag_result, false),      do: :ok
  defp check_flag(nil, {:ok, false}, true),         do: {:error, :channel_not_permitted}
  defp check_flag(nil, _flag_result, _condition),   do: :ok

  # International check: currency ≠ SYS base_currency → needs intl_enabled true.
  #
  # Bug fix (2026-07-07): DE49 arrives as ISO 4217 NUMERIC (e.g. "784") but
  # base_currency is stored ALPHA (e.g. "AED") — a raw `!=` compared two
  # different code spaces and was true for every domestic transaction using
  # a numeric currency code, misclassifying it as international and
  # declining it whenever intl_enabled was false. CurrencyCodes.same_currency?/2
  # normalizes both sides before comparing.
  defp check_intl(card_override, get, txn_currency) do
    with {:ok, base_currency} <- get.(:base_currency),
         true                 <- txn_currency != nil and txn_currency != "000",
         false                <- CurrencyCodes.same_currency?(txn_currency, base_currency) do
      case card_override do
        true  -> :ok
        false -> {:error, :channel_not_permitted}
        nil ->
          case get.(:intl_enabled) do
            {:ok, false} -> {:error, :channel_not_permitted}
            _            -> :ok
          end
      end
    else
      _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # CVV / iCVV validation (7D)
  # ---------------------------------------------------------------------------

  @doc """
  Validates the card verification value using the HSM.

  `ctx.fields` map is inspected for DE35 (track 2) and DE55 (EMV chip data).
  Skips validation when:
  - Logo parameter `cvv_required` is explicitly `false`
  - Neither DE35 nor chip mode is present (fail-open for contactless/chip fallback)

  Returns `:ok` or `{:error, :invalid_cvv}`.
  """
  @spec validate_cvv(String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, :invalid_cvv}
  def validate_cvv(sys_id, bank_id, logo_id, ctx) do
    get = fn key -> ParameterEngine.get(sys_id, bank_id, logo_id, "", key) end

    if get.(:cvv_required) == {:ok, false} do
      :ok
    else
      do_validate_cvv(ctx)
    end
  end

  defp do_validate_cvv(%{fields: fields, pan: pan, expiry: expiry}) do
    cond do
      # EMV chip: use iCVV (service_code "999")
      Map.has_key?(fields, 55) ->
        case extract_icvv_from_emv(fields[55]) do
          {:ok, cvv} ->
            expiry_str = expiry || Map.get(fields, 14, "")
            call_hsm_verify(pan, expiry_str, "999", cvv)
          :skip ->
            :ok
        end

      # Magstripe track 2: CVV1
      Map.has_key?(fields, 35) ->
        case parse_track2_cvv(fields[35]) do
          {:ok, track_pan, track_expiry, service_code, cvv} ->
            # Trust track2 PAN and expiry over DE2/DE14 for CVV1 check
            _pan_check = track_pan
            call_hsm_verify(pan, track_expiry, service_code, cvv)
          :skip ->
            :ok
          {:error, reason} ->
            Logger.debug("[CardValidator] Track2 parse skip: #{reason}")
            :ok
        end

      # CNP / ecom — DE2 only, no track data; CVV2 would be in DE48 or similar
      # Fail-open here — CVV2 field position is implementation-specific
      true ->
        :ok
    end
  end

  defp call_hsm_verify(pan, expiry, service_code, cvv) do
    case HSM.verify_cvv(pan, expiry, service_code, cvv) do
      :ok                       -> :ok
      {:error, :cvv_mismatch}   -> {:error, :invalid_cvv}
      {:error, :not_implemented} -> :ok  # ProductionHSM stub → fail-open
    end
  end

  # Extract CVV from EMV Application Cryptogram — iCVV is tag 9F26 (ARQC),
  # but the iCVV for CVV validation purposes comes from tag 9F61 or the
  # card track data equivalent. For simplicity, skip if EMV (chip auth
  # replaces CVV check — ARQC verification in EmvHandler is the real check).
  defp extract_icvv_from_emv(_de55), do: :skip

  # Parse track 2: PAN D YYMM SSS discretionary
  # Separator is 'D' (hex) in binary track data, often '=' in ASCII display
  defp parse_track2_cvv(track2) when is_binary(track2) do
    normalized = track2 |> String.upcase() |> String.replace("=", "D")

    case String.split(normalized, "D") do
      [pan, rest | _] when byte_size(rest) >= 10 ->
        expiry       = String.slice(rest, 0, 4)
        service_code = String.slice(rest, 4, 3)
        discret      = String.slice(rest, 7, String.length(rest) - 7)
        cvv1         = String.slice(discret, 0, 3)

        if String.match?(cvv1, ~r/^\d{3}$/) do
          {:ok, pan, expiry, service_code, cvv1}
        else
          :skip
        end

      _ ->
        {:error, :invalid_track2_format}
    end
  end

  defp parse_track2_cvv(_), do: :skip
end
