defmodule VmuCore.WPS.AmountFormat do
  @moduledoc """
  Parses salary-file amounts under a configured encoding (W2).

  ## Why this is its own module

  Amount encoding is the single most dangerous field in a salary file to get
  wrong. Fixed-width schemes almost universally write minor units without a
  separator — `"123456"` meaning 1,234.56 — while delimited exports usually
  write `"1234.56"`. Reading one as the other pays every worker on the file a
  hundred times too much or too little, and nothing downstream would notice,
  because both are perfectly valid amounts.

  So the encoding is explicit configuration (`amount_format`), never inferred
  from the shape of the string. Inference is what makes this class of bug
  possible: `"1234"` is a legitimate value under both encodings.

  ## Formats

  | | |
  |---|---|
  | `"decimal"` | `"1234.56"` → 1234.56. The default |
  | `"implied_2dp"` | `"123456"` → 1234.56 |

  Both tolerate thousands separators and a leading sign, because payroll
  exports emit them and rejecting a line over a comma helps nobody.
  """

  @doc """
  Parses `value` under `format`.

  A blank value returns `{:ok, nil}` — absent is not invalid, and the caller
  decides whether a particular field was required.
  """
  @spec parse(term(), String.t()) :: {:ok, Decimal.t() | nil} | {:error, String.t()}
  def parse(value, format \\ "decimal")

  def parse(%Decimal{} = value, _format), do: {:ok, value}

  def parse(value, format) do
    case clean(value) do
      nil -> {:ok, nil}
      cleaned -> decode(cleaned, format)
    end
  end

  defp decode(cleaned, "implied_2dp") do
    # Must be an integer of minor units. A decimal point here means the file is
    # not in the configured encoding, and silently accepting it would mask a
    # misconfiguration on exactly the field where that is most costly.
    if Regex.match?(~r/^[+-]?\d+$/, cleaned) do
      {:ok, cleaned |> Decimal.new() |> Decimal.div(100)}
    else
      {:error,
       "amount_format is implied_2dp, which expects minor units as an integer, " <>
         "but got #{cleaned}"}
    end
  end

  defp decode(cleaned, _decimal) do
    case Decimal.parse(cleaned) do
      {decimal, ""} -> {:ok, decimal}
      {_decimal, rest} -> {:error, "trailing characters after amount: #{rest}"}
      :error -> {:error, "not a number: #{cleaned}"}
    end
  end

  defp clean(nil), do: nil

  defp clean(value) do
    cleaned =
      value
      |> to_string()
      |> String.trim()
      # Thousands separators and spaces, which payroll exports emit.
      |> String.replace(",", "")
      |> String.replace(" ", "")

    if cleaned == "", do: nil, else: cleaned
  end
end
