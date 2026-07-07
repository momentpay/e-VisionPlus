defmodule VmuCore.Shared.CurrencyCodes do
  @moduledoc """
  ISO 4217 alpha ↔ numeric currency code reference (bug fix, 2026-07-07).

  ## The bug this fixes

  `FAS.CardValidator.check_intl/3` compared DE49 (the transaction currency —
  always ISO 4217 **numeric** on the wire, e.g. `"784"`) directly against
  `base_currency` (a BANK/SYS parameter stored **alpha**, e.g. `"AED"`).
  Since `"784" != "AED"` is always true regardless of whether the currencies
  actually match, every transaction using a numeric DE49 was misclassified
  as international and declined whenever the product's `intl_enabled` flag
  was false — a false decline on **every domestic transaction**, not an edge
  case. A second, smaller instance of the same alpha/numeric mismatch
  pattern existed as a private 4-entry stub in `TRAMS.MastercardIpm`
  (`iso4217_numeric_to_alpha/1`, falling back to `"AED"` for anything
  unmapped) — consolidated here rather than left duplicated.

  ## Usage

      CurrencyCodes.same_currency?("784", "AED")  #=> true
      CurrencyCodes.to_numeric("AED")              #=> "784"
      CurrencyCodes.to_alpha("784")                #=> "AED"

  `same_currency?/2` is the fail-safe entry point: if either code isn't in
  the table, it falls back to raw string comparison (today's pre-fix
  behavior) rather than guessing — so currencies outside this list see no
  behavior change, only the documented AED/784-style mismatch is corrected.

  Coverage is GCC + major global trading currencies — practically complete
  for card-present/CNP authorization traffic, not the full ~180-currency
  ISO 4217 set. Extend `@alpha_to_numeric` as new markets are onboarded.
  """

  @alpha_to_numeric %{
    "AED" => "784", "USD" => "840", "EUR" => "978", "GBP" => "826",
    "SAR" => "682", "KWD" => "414", "BHD" => "048", "OMR" => "512",
    "QAR" => "634", "EGP" => "818", "JOD" => "400", "LBP" => "422",
    "IQD" => "368", "YER" => "886", "SYP" => "760",
    "INR" => "356", "PKR" => "586", "BDT" => "050", "LKR" => "144",
    "AFN" => "971", "IRR" => "364", "ILS" => "376",
    "CNY" => "156", "JPY" => "392", "HKD" => "344", "SGD" => "702",
    "KRW" => "410", "TWD" => "901", "PHP" => "608", "IDR" => "360",
    "MYR" => "458", "THB" => "764", "VND" => "704",
    "CHF" => "756", "SEK" => "752", "NOK" => "578", "DKK" => "208",
    "PLN" => "985", "CZK" => "203", "HUF" => "348", "RON" => "946",
    "RUB" => "643", "TRY" => "949",
    "AUD" => "036", "NZD" => "554", "CAD" => "124",
    "ZAR" => "710", "NGN" => "566", "KES" => "404", "GHS" => "936",
    "MAD" => "504", "TND" => "788", "DZD" => "012",
    "BRL" => "986", "MXN" => "484", "ARS" => "032", "CLP" => "152",
    "COP" => "170", "PEN" => "604"
  }

  @numeric_to_alpha Map.new(@alpha_to_numeric, fn {alpha, numeric} -> {numeric, alpha} end)

  @doc "ISO 4217 alpha → numeric. `nil` if `code` isn't a known alpha code."
  @spec to_numeric(String.t() | nil) :: String.t() | nil
  def to_numeric(nil), do: nil
  def to_numeric(code), do: Map.get(@alpha_to_numeric, String.upcase(code))

  @doc "ISO 4217 numeric → alpha. `nil` if `code` isn't a known numeric code."
  @spec to_alpha(String.t() | nil) :: String.t() | nil
  def to_alpha(nil), do: nil
  def to_alpha(code), do: Map.get(@numeric_to_alpha, code)

  @doc """
  True when `a` and `b` denote the same currency, regardless of which one is
  alpha and which is numeric. Falls back to raw equality when a code isn't
  recognized (fail-safe — see moduledoc).
  """
  @spec same_currency?(String.t() | nil, String.t() | nil) :: boolean()
  def same_currency?(a, b), do: normalize(a) == normalize(b)

  # Canonical form is numeric: a known alpha code maps to its numeric
  # equivalent; a code already numeric (or anything unrecognized) passes
  # through unchanged, which is what makes `same_currency?/2` fail-safe.
  defp normalize(nil), do: nil
  defp normalize(code) do
    upcased = String.upcase(code)
    Map.get(@alpha_to_numeric, upcased, upcased)
  end
end
