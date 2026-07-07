defmodule VmuCore.CMS.StipEngine do
  @moduledoc """
  Stand-In Processing (STIP) engine for VisionPlus.

  STIP is invoked when the primary real-time authorization system is
  unavailable (network outage, planned maintenance, host timeout). The engine
  applies pre-configured rules from the LOGO parameter level to decide
  whether to approve or decline a transaction without contacting the core system.

  ## Authorization Decision Flow

      FAS.Authorization
          │
          ├─ host available? ──► normal auth (bypasses STIP entirely)
          │
          └─ host unavailable
               │
               └─ StipEngine.evaluate/3
                    ├─ stip_enabled == false  → :decline (safe default)
                    ├─ amount <= floor_limit  → :approve (always safe)
                    ├─ amount >  max_amount   → :decline (above threshold)
                    ├─ open_to_buy < amount   → :decline (insufficient funds)
                    └─ otherwise             → :approve

  ## STIP Parameters (from LogoParameter via ParameterEngine)

    - `stip_enabled`     — master on/off switch (default: false — conservative)
    - `stip_floor_limit` — amounts at or below this are always approved (AED)
    - `stip_max_amount`  — amounts above this are always declined (AED)

  ## Usage

      iex> StipEngine.evaluate("ACCT-001", Decimal.new("200"), %{
      ...>   sys_id: "V001", bank_id: "BANK", logo_id: "VISA", block_id: "STD",
      ...>   open_to_buy: Decimal.new("5000")
      ...> })
      {:ok, :approve, "STIP: amount 200 ≤ floor limit 500"}

  ## Return Values

      {:ok, :approve, reason_string}
      {:ok, :decline, reason_string}
      {:error, reason_string}
  """

  require Logger
  alias VmuCore.Shared.ParameterEngine

  @type decision :: :approve | :decline
  @type evaluate_result :: {:ok, decision(), String.t()} | {:error, String.t()}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Evaluate a STIP authorization request.

  `account_id` is used only for logging. `amount` must be a `Decimal`.
  `account_context` must include `:sys_id`, `:bank_id`, `:logo_id`, `:block_id`,
  plus `:open_to_buy` for the available-funds check.

  Returns `{:ok, decision, reason}` or `{:error, message}`.
  """
  @spec evaluate(String.t(), Decimal.t(), map()) :: evaluate_result()
  def evaluate(account_id, amount, account_context) do
    sys_id   = Map.get(account_context, :sys_id)   || Map.get(account_context, "sys_id")
    bank_id  = Map.get(account_context, :bank_id)  || Map.get(account_context, "bank_id")
    logo_id  = Map.get(account_context, :logo_id)  || Map.get(account_context, "logo_id")
    block_id = Map.get(account_context, :block_id) || Map.get(account_context, "block_id")
    otb      = Map.get(account_context, :open_to_buy) || Map.get(account_context, "open_to_buy")

    with {:ok, params} <- load_stip_params(sys_id, bank_id, logo_id, block_id) do
      {decision, reason} = decide(amount, to_decimal_or_nil(otb), params)
      Logger.info("[STIP] account=#{account_id} amount=#{amount} → #{decision}: #{reason}")
      {:ok, decision, reason}
    end
  end

  @doc """
  Returns true if STIP is enabled for the given logo configuration.
  Used by the FAS authorization layer before falling back to STIP.
  """
  @spec enabled?(String.t(), String.t(), String.t(), String.t()) :: boolean()
  def enabled?(sys_id, bank_id, logo_id, block_id) do
    case ParameterEngine.get(sys_id, bank_id, logo_id, block_id, :stip_enabled) do
      {:ok, true} -> true
      _           -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Private — decision logic
  # ---------------------------------------------------------------------------

  defp decide(_amount, _otb, %{enabled: false}) do
    {:decline, "STIP disabled for this logo — safe-decline"}
  end

  defp decide(amount, otb, %{enabled: true, floor_limit: floor, max_amount: max}) do
    cond do
      Decimal.compare(amount, floor) != :gt ->
        {:approve, "STIP: amount #{amount} ≤ floor limit #{floor}"}

      Decimal.compare(amount, max) == :gt ->
        {:decline, "STIP: amount #{amount} exceeds max #{max}"}

      not is_nil(otb) and Decimal.compare(otb, amount) == :lt ->
        {:decline, "STIP: insufficient open-to-buy (#{otb} < #{amount})"}

      true ->
        {:approve, "STIP: approved within thresholds (floor=#{floor} max=#{max})"}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — parameter loading
  # ---------------------------------------------------------------------------

  defp load_stip_params(sys_id, bank_id, logo_id, block_id) do
    enabled     = get_param(sys_id, bank_id, logo_id, block_id, :stip_enabled,    false)
    floor_limit = get_param(sys_id, bank_id, logo_id, block_id, :stip_floor_limit, "50")
    max_amount  = get_param(sys_id, bank_id, logo_id, block_id, :stip_max_amount,  "500")

    {:ok, %{
      enabled:     enabled == true,
      floor_limit: to_decimal(floor_limit),
      max_amount:  to_decimal(max_amount)
    }}
  rescue
    e -> {:error, "STIP param load failed: #{Exception.message(e)}"}
  end

  defp get_param(sys_id, bank_id, logo_id, block_id, key, default) do
    case ParameterEngine.get(sys_id, bank_id, logo_id, block_id, key) do
      {:ok, nil}   -> default
      {:ok, value} -> value
      _            -> default
    end
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(v) when is_binary(v),  do: Decimal.new(v)
  defp to_decimal(v) when is_integer(v), do: Decimal.new(v)
  defp to_decimal(v) when is_float(v),   do: Decimal.from_float(v)

  defp to_decimal_or_nil(nil), do: nil
  defp to_decimal_or_nil(v),   do: to_decimal(v)
end
