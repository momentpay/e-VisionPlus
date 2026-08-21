defmodule VmuCore.WPS.FileParser do
  @moduledoc """
  Parses a salary file into canonical lines, driven entirely by per-employer
  configuration (W2).

  ## No format is hardcoded

  There is no single WPS file layout. UAE, Saudi and Bahrain each run their own
  scheme, and an employer's payroll system adds its own variation on top. So
  this module knows how to read *delimited* and *fixed-width* text and nothing
  about any particular scheme — column names, positions, date format and amount
  encoding all come from `wps.employer_config`.

  The consequence worth stating: **onboarding a new market is a configuration
  entry, not a code change**, and a missing scheme specification does not block
  building or testing the pipeline. It is the same conclusion `COL.AgencyDesk`
  reached for collections-agency files, reused deliberately rather than
  inventing a second pattern.

  ## Errors accumulate; they do not abort

  A salary file with a bad line on row 3 must still tell the operator about rows
  4 through 400. Every line is attempted, failures are collected with their line
  number and the raw text, and the caller decides what to do with a file that
  parsed 383 of 400. Failing fast would turn one typo into a blind
  re-submission cycle.

  ## Canonical fields

  `employee_id`, `employee_name`, `payment_reference`, `gross_amount`,
  `deduction_amount`, `net_amount`, `currency`, `pay_period_start`,
  `pay_period_end`, `payment_date`.

  `employee_id`, `payment_reference` and `net_amount` are required — respectively
  who to pay, the idempotency key, and how much. The rest inform reporting and
  validation.
  """

  alias VmuCore.WPS.AmountFormat

  @required_fields ~w[employee_id payment_reference net_amount]
  @canonical_fields ~w[employee_id employee_name payment_reference gross_amount
                       deduction_amount net_amount currency pay_period_start
                       pay_period_end payment_date]

  @type line :: map()
  @type parse_error :: %{
          line_number: pos_integer(),
          field: String.t(),
          error: String.t(),
          raw: String.t()
        }

  @doc "The canonical field names an `import_mapping` may target."
  @spec canonical_fields() :: [String.t()]
  def canonical_fields, do: @canonical_fields

  @doc """
  Parses `content` using `config`.

  Returns `{:ok, lines, errors}` — always both, because a partially-parsed file
  is the normal case and the caller needs the good lines *and* the bad ones.
  `{:error, reason}` only when the file cannot be read at all.
  """
  @spec parse(binary(), map()) :: {:ok, [line()], [parse_error()]} | {:error, term()}
  def parse(content, config) when is_binary(content) and is_map(config) do
    case Map.get(config, "file_format", "CSV") do
      "CSV" -> parse_delimited(content, config)
      "FIXED_WIDTH" -> parse_fixed_width(content, config)
      other -> {:error, {:unsupported_file_format, other}}
    end
  end

  # ---------------------------------------------------------------------------
  # Delimited
  # ---------------------------------------------------------------------------

  defp parse_delimited(content, config) do
    delimiter = Map.get(config, "delimiter", ",")
    has_header = Map.get(config, "has_header", true)
    mapping = Map.get(config, "import_mapping", %{})

    rows = data_rows(content, config)

    case {rows, has_header} do
      {[], _} ->
        {:ok, [], []}

      {[{header_text, _} | body], true} ->
        headers =
          header_text
          |> split_row(delimiter)
          # An unmapped header keeps its own name, so an employer already using
          # our field names needs no mapping at all.
          |> Enum.map(fn h -> Map.get(mapping, h, h) end)

        build(body, config, fn text ->
          headers |> Enum.zip(split_row(text, delimiter)) |> Map.new()
        end)

      {body, false} ->
        # No header row: the mapping must be positional, written as
        # "1" => "employee_id". Without it there is nothing to key on.
        build(body, config, fn text ->
          text
          |> split_row(delimiter)
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {value, idx} ->
            case Map.get(mapping, to_string(idx)) do
              nil -> []
              field -> [{field, value}]
            end
          end)
          |> Map.new()
        end)
    end
  end

  # Quote-aware, because a naive split on the delimiter corrupts exactly the
  # field it can least afford to: a payroll export writes a thousands separator
  # inside quotes as "12,500.75", and splitting on the comma first turns one
  # amount into two fields — silently, and with a plausible-looking number in
  # each. Found by test 2026-08-06.
  #
  # Doubled quotes inside a quoted field are the CSV escape for a literal quote.
  defp split_row(text, delimiter) do
    text
    |> scan_fields(delimiter, false, "", [])
    |> Enum.map(&String.trim/1)
  end

  defp scan_fields("", _delimiter, _in_quotes, current, acc) do
    Enum.reverse([current | acc])
  end

  defp scan_fields(<<?", ?", rest::binary>>, delimiter, true, current, acc) do
    scan_fields(rest, delimiter, true, current <> ~s("), acc)
  end

  defp scan_fields(<<?", rest::binary>>, delimiter, in_quotes, current, acc) do
    scan_fields(rest, delimiter, not in_quotes, current, acc)
  end

  defp scan_fields(text, delimiter, false, current, acc) do
    if String.starts_with?(text, delimiter) do
      rest = binary_part(text, byte_size(delimiter), byte_size(text) - byte_size(delimiter))
      scan_fields(rest, delimiter, false, "", [current | acc])
    else
      {char, rest} = String.split_at(text, 1)
      scan_fields(rest, delimiter, false, current <> char, acc)
    end
  end

  defp scan_fields(text, delimiter, true, current, acc) do
    {char, rest} = String.split_at(text, 1)
    scan_fields(rest, delimiter, true, current <> char, acc)
  end

  # ---------------------------------------------------------------------------
  # Fixed width
  # ---------------------------------------------------------------------------

  defp parse_fixed_width(content, config) do
    case Map.get(config, "fixed_width_fields") do
      nil ->
        {:error, :fixed_width_fields_not_configured}

      fields when map_size(fields) == 0 ->
        {:error, :fixed_width_fields_not_configured}

      fields ->
        build(data_rows(content, config), config, fn text -> slice_fields(text, fields) end)
    end
  end

  # Positions are 1-based `[start, length]`, which is how published record
  # layouts state them — converted here rather than asking whoever writes the
  # config to do off-by-one arithmetic against a specification document.
  defp slice_fields(text, fields) do
    Map.new(fields, fn {field, position} ->
      {start, len} = normalise_position(position)
      {field, text |> String.slice(start - 1, len) |> to_string() |> String.trim()}
    end)
  end

  defp normalise_position([start, len]), do: {start, len}
  defp normalise_position(%{"start" => start, "length" => len}), do: {start, len}
  defp normalise_position({start, len}), do: {start, len}

  # ---------------------------------------------------------------------------
  # Shared
  # ---------------------------------------------------------------------------

  defp data_rows(content, config) do
    skip = Map.get(config, "skip_lines", 0)

    content
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.drop(skip)
    |> Enum.reject(fn {text, _n} -> String.trim(text) == "" end)
  end

  defp build(rows, config, extract) do
    {lines, errors} =
      Enum.reduce(rows, {[], []}, fn {text, line_number}, {ok, bad} ->
        case build_line(extract.(text), config, line_number, text) do
          {:ok, line} -> {[line | ok], bad}
          {:error, errs} -> {ok, Enum.reverse(errs) ++ bad}
        end
      end)

    {:ok, Enum.reverse(lines), Enum.reverse(errors)}
  end

  defp build_line(raw, config, line_number, text) do
    default_currency = Map.get(config, "currency", "AED")

    with {:ok, required} <- fetch_required(raw, line_number, text),
         {:ok, amounts} <- parse_amounts(raw, config, line_number, text),
         {:ok, dates} <- parse_dates(raw, config, line_number, text),
         :ok <- validate_consistency(amounts, config, line_number, text) do
      {:ok,
       %{
         line_number: line_number,
         employee_id: required["employee_id"],
         employee_name: blank_to_nil(raw["employee_name"]),
         payment_reference: required["payment_reference"],
         currency: blank_to_nil(raw["currency"]) || default_currency
       }
       |> Map.merge(amounts)
       |> Map.merge(dates)}
    end
  end

  defp fetch_required(raw, line_number, text) do
    # `net_amount` is checked by `parse_amounts/4`, which can report *why* it
    # failed rather than only that it was absent.
    fields = @required_fields -- ["net_amount"]
    missing = Enum.filter(fields, &(blank_to_nil(raw[&1]) == nil))

    if missing == [] do
      {:ok, Map.new(fields, &{&1, String.trim(to_string(raw[&1]))})}
    else
      {:error,
       Enum.map(missing, fn field ->
         %{
           line_number: line_number,
           field: field,
           error: "required field is missing or blank",
           raw: text
         }
       end)}
    end
  end

  defp parse_amounts(raw, config, line_number, text) do
    format = Map.get(config, "amount_format", "decimal")

    # String/atom pairs rather than `String.to_existing_atom/1`: the atom must
    # be a compile-time literal, or parsing depends on whether some unrelated
    # module happened to be loaded first.
    parsed =
      Enum.map(
        [{"gross_amount", :gross_amount}, {"deduction_amount", :deduction_amount},
         {"net_amount", :net_amount}],
        fn {field, key} -> {field, key, AmountFormat.parse(raw[field], format)} end
      )

    errors =
      Enum.flat_map(parsed, fn
        {field, _key, {:error, reason}} ->
          [%{line_number: line_number, field: field, error: to_string(reason), raw: text}]

        {"net_amount", _key, {:ok, nil}} ->
          [
            %{
              line_number: line_number,
              field: "net_amount",
              error: "required field is missing or blank",
              raw: text
            }
          ]

        _ ->
          []
      end)

    if errors == [] do
      {:ok, Map.new(parsed, fn {_field, key, {:ok, value}} -> {key, value} end)}
    else
      {:error, errors}
    end
  end

  defp parse_dates(raw, config, line_number, text) do
    format = Map.get(config, "date_format")

    parsed =
      Enum.map(
        [{"pay_period_start", :pay_period_start}, {"pay_period_end", :pay_period_end},
         {"payment_date", :payment_date}],
        fn {field, key} -> {field, key, parse_date(raw[field], format)} end
      )

    errors =
      Enum.flat_map(parsed, fn
        {field, _key, {:error, reason}} ->
          [%{line_number: line_number, field: field, error: to_string(reason), raw: text}]

        _ ->
          []
      end)

    if errors == [] do
      {:ok, Map.new(parsed, fn {_field, key, {:ok, value}} -> {key, value} end)}
    else
      {:error, errors}
    end
  end

  defp parse_date(value, format) do
    case blank_to_nil(value) do
      nil -> {:ok, nil}
      v -> do_parse_date(v, format)
    end
  end

  defp do_parse_date(v, nil) do
    case Date.from_iso8601(v) do
      {:ok, d} -> {:ok, d}
      _ -> {:error, "not an ISO-8601 date: #{v}"}
    end
  end

  # strptime-style, supporting the directives salary files actually use. A full
  # strftime implementation would be more than this needs and more to get wrong.
  defp do_parse_date(v, format) do
    pattern =
      format
      |> Regex.escape()
      |> String.replace("%Y", "(?<year>\\d{4})")
      |> String.replace("%m", "(?<month>\\d{2})")
      |> String.replace("%d", "(?<day>\\d{2})")

    case Regex.named_captures(~r/^#{pattern}$/, v) do
      %{"year" => y, "month" => m, "day" => d} ->
        case Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
          {:ok, date} -> {:ok, date}
          {:error, reason} -> {:error, "invalid date #{v}: #{reason}"}
        end

      _ ->
        {:error, "does not match date_format #{format}: #{v}"}
    end
  end

  # net = gross - deductions, when all three are present.
  #
  # A file failing this is usually a column-mapping error rather than a payroll
  # error, which makes it the cheapest available check that the layout config is
  # right — and catching it here is far better than discovering it after the
  # money moved.
  defp validate_consistency(amounts, config, line_number, text) do
    if Map.get(config, "require_net_equals_gross_minus_deductions", true) do
      gross = amounts[:gross_amount]
      deduction = amounts[:deduction_amount] || Decimal.new(0)
      net = amounts[:net_amount]

      cond do
        is_nil(gross) or is_nil(net) ->
          :ok

        Decimal.equal?(Decimal.sub(gross, deduction), net) ->
          :ok

        true ->
          {:error,
           [
             %{
               line_number: line_number,
               field: "net_amount",
               error:
                 "net #{net} does not equal gross #{gross} minus deductions " <>
                   "#{deduction} — usually a column-mapping error",
               raw: text
             }
           ]}
      end
    else
      :ok
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(v) do
    case String.trim(to_string(v)) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
