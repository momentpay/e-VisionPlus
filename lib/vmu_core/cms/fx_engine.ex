defmodule VmuCore.CMS.FxEngine do
  @moduledoc """
  Currency conversion engine for VisionPlus multi-currency support.

  ## Design
  - Rates are stored in `fx_rates` as multipliers (amount * rate = target).
  - The engine resolves the latest rate with effective_date <= requested_date.
  - If a direct pair is not found it tries to convert via AED as a bridge currency
    (from → AED → to), which covers most Middle-East card use-cases.
  - All arithmetic is Decimal — no floats.
  - Bank-scoped rates take precedence over global rates (bank_id IS NULL).

  ## Usage
      iex> FxEngine.convert(Decimal.new("100"), "USD", "AED")
      {:ok, %{converted: #Decimal<367.25>, rate: #Decimal<3.67250000>, from: "USD", to: "AED"}}

      iex> FxEngine.convert(Decimal.new("100"), "AED", "AED")
      {:ok, %{converted: #Decimal<100>, rate: #Decimal<1>, from: "AED", to: "AED"}}
  """

  import Ecto.Query
  alias VmuCore.{Repo, CMS.FxRate}

  @base_currency "AED"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Convert `amount` from `from_currency` to `to_currency` using the latest
  rate on or before `as_of_date` (defaults to today).

  Returns `{:ok, map}` or `{:error, reason}`.
  """
  @spec convert(Decimal.t(), String.t(), String.t(), Date.t() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def convert(amount, from_currency, to_currency, as_of_date \\ nil, bank_id \\ nil)

  def convert(amount, same, same, _date, _bank_id) do
    {:ok, %{converted: amount, rate: Decimal.new(1), from: same, to: same}}
  end

  def convert(amount, from_currency, to_currency, as_of_date, bank_id) do
    date = as_of_date || Date.utc_today()

    case resolve_rate(from_currency, to_currency, date, bank_id) do
      {:ok, rate} ->
        converted =
          amount
          |> Decimal.mult(rate)
          |> Decimal.round(2)

        {:ok, %{converted: converted, rate: rate, from: from_currency, to: to_currency, as_of: date}}

      {:error, :no_direct_rate} ->
        # Try bridge via base currency (AED)
        with {:ok, rate_to_base} <- resolve_rate(from_currency, @base_currency, date, bank_id),
             {:ok, rate_from_base} <- resolve_rate(@base_currency, to_currency, date, bank_id) do
          bridged_rate = Decimal.mult(rate_to_base, rate_from_base)
          converted = amount |> Decimal.mult(bridged_rate) |> Decimal.round(2)

          {:ok, %{
            converted: converted,
            rate: Decimal.round(bridged_rate, 8),
            from: from_currency,
            to: to_currency,
            as_of: date,
            via: @base_currency
          }}
        else
          _ -> {:error, "No FX rate found for #{from_currency} → #{to_currency} on #{date}"}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  @doc """
  Bulk-load rates from a list of maps (for batch import from ECB/SWIFT feeds).

  Each map must have keys: from_currency, to_currency, rate, effective_date.
  Optional: source, bank_id.
  """
  @spec bulk_upsert([map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def bulk_upsert(rates) when is_list(rates) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    records =
      Enum.map(rates, fn r ->
        %{
          rate_id:        Ecto.UUID.generate(),
          from_currency:  r[:from_currency] || r["from_currency"],
          to_currency:    r[:to_currency]   || r["to_currency"],
          rate:           r[:rate]          || r["rate"],
          effective_date: r[:effective_date] || r["effective_date"],
          source:         r[:source]        || r["source"],
          bank_id:        r[:bank_id]       || r["bank_id"],
          inserted_at:    now,
          updated_at:     now
        }
      end)

    {count, _} =
      Repo.insert_all(FxRate, records,
        on_conflict: {:replace, [:rate, :source, :updated_at]},
        conflict_target: [:from_currency, :to_currency, :effective_date]
      )

    {:ok, count}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Return the latest known rate for a currency pair as of today.
  Useful for display in operator screens.
  """
  @spec latest_rate(String.t(), String.t(), String.t() | nil) ::
          {:ok, Decimal.t()} | {:error, String.t()}
  def latest_rate(from_currency, to_currency, bank_id \\ nil) do
    case resolve_rate(from_currency, to_currency, Date.utc_today(), bank_id) do
      {:ok, rate} -> {:ok, rate}
      {:error, _} -> {:error, "No rate on file for #{from_currency}/#{to_currency}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp resolve_rate(from_currency, to_currency, date, bank_id) do
    # Bank-scoped rate first, fall back to global
    rate =
      Repo.one(
        from r in FxRate,
          where: r.from_currency == ^from_currency
             and r.to_currency   == ^to_currency
             and r.effective_date <= ^date
             and (^bank_id_condition(bank_id)),
          order_by: [desc: r.effective_date, desc: r.inserted_at],
          limit: 1,
          select: r.rate
      )

    if rate, do: {:ok, rate}, else: {:error, :no_direct_rate}
  end

  # Dynamic condition: prefer bank-scoped, fall back to global
  defp bank_id_condition(nil),     do: true
  defp bank_id_condition(bank_id), do: dynamic([r], r.bank_id == ^bank_id or is_nil(r.bank_id))
end
