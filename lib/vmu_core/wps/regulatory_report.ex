defmodule VmuCore.WPS.RegulatoryReport do
  @moduledoc """
  The compliance report a Wage Protection scheme requires back (W4).

  ```
  generate(employer_id, from, to)      -> canonical rows + summary
  render(report, employer)             -> the file to send
  ```

  ## What the regulator is actually asking

  Not "how much did you pay" but **"which workers were paid, and for the ones
  who were not, why"**. That is the whole point of a Wage Protection scheme: it
  exists to make non-payment visible. So an unpaid line is a first-class row in
  this report with its reason attached, not an omission — a report that silently
  listed only successful payments would defeat the scheme it is filed under.

  ## Output is configured, not hardcoded

  `export_mapping` and `file_format` come from `wps.employer_config`, the same
  way the import layout does. Every jurisdiction wants a different shape, and a
  report format baked into code is the same mistake as an import format baked
  into code.

  ## Not transmitted

  This generates the file. Sending it depends on whether the institution files
  directly with the regulator or through an exchange house holding the
  relationship — a business arrangement, not a technical one, and the
  requirements record it as an open question. Generating without transmitting is
  the honest half to build.
  """

  import Ecto.Query, warn: false

  alias VmuCore.Repo
  alias VmuCore.WPS.{Employer, SalaryCredit, SalaryCreditException}

  # The order a row is written in, regardless of what the columns are called.
  @fields ~w[employee_id employee_name payment_reference net_amount currency
             payment_date status paid_at failure_reason]a

  @doc """
  Builds the report for an employer over a payment-date window.

  Rows cover every salary credit in the period, paid or not.
  """
  @spec generate(Ecto.UUID.t(), Date.t(), Date.t()) :: {:ok, map()} | {:error, term()}
  def generate(employer_id, %Date{} = from, %Date{} = to) do
    case Repo.get(Employer, employer_id) do
      nil ->
        {:error, :employer_not_found}

      employer ->
        credits = credits_in_period(employer_id, from, to)
        reasons = failure_reasons(credits)

        rows = Enum.map(credits, &row(&1, reasons))

        {:ok,
         %{
           employer: employer,
           period: %{from: from, to: to},
           generated_at: DateTime.utc_now(),
           rows: rows,
           summary: summarise(rows)
         }}
    end
  end

  defp credits_in_period(employer_id, from, to) do
    SalaryCredit
    |> where([c], c.employer_id == ^employer_id)
    # `payment_date` is the employer's own stated pay date, which is what a
    # regulator's period means. Falling back to when the row was written would
    # report against our processing calendar rather than the wage cycle.
    |> where([c], c.payment_date >= ^from and c.payment_date <= ^to)
    |> order_by([c], asc: c.employee_id)
    |> Repo.all()
  end

  # The exception carries the operator-facing explanation, which is more useful
  # to a regulator than the credit's own truncated summary.
  defp failure_reasons(credits) do
    ids = Enum.map(credits, & &1.salary_credit_id)

    SalaryCreditException
    |> where([e], e.salary_credit_id in ^ids)
    |> order_by([e], desc: e.inserted_at)
    |> Repo.all()
    |> Map.new(&{&1.salary_credit_id, {&1.exception_type, &1.reason}})
  end

  defp row(credit, reasons) do
    {status, reason} = disposition(credit, reasons)

    %{
      employee_id: credit.employee_id,
      employee_name: credit.employee_name,
      payment_reference: credit.payment_reference,
      net_amount: credit.net_amount,
      currency: credit.currency,
      payment_date: credit.payment_date,
      status: status,
      paid_at: credit.posted_at && DateTime.to_date(credit.posted_at),
      failure_reason: reason
    }
  end

  # The regulator's vocabulary, not ours. "PARSED" means nothing to a labour
  # authority; "NOT_PAID" does.
  defp disposition(%SalaryCredit{status: "POSTED"}, _reasons), do: {"PAID", nil}

  defp disposition(%SalaryCredit{salary_credit_id: id} = credit, reasons) do
    case Map.get(reasons, id) do
      {type, reason} -> {"NOT_PAID", "#{type}: #{reason}"}
      nil -> {"NOT_PAID", credit.failure_reason || "not yet disbursed"}
    end
  end

  defp summarise(rows) do
    {paid, unpaid} = Enum.split_with(rows, &(&1.status == "PAID"))

    %{
      total_count: length(rows),
      paid_count: length(paid),
      unpaid_count: length(unpaid),
      paid_total: sum(paid),
      unpaid_total: sum(unpaid)
    }
  end

  defp sum(rows) do
    Enum.reduce(rows, Decimal.new(0), fn r, acc -> Decimal.add(acc, r.net_amount) end)
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  @doc """
  Renders a report in the employer's configured output format.

  Returns `{:ok, content, format}`. Falls back to CSV with this repository's own
  field names when nothing is configured, which is a usable default rather than
  a guess at any particular scheme.
  """
  @spec render(map(), map()) :: {:ok, String.t(), String.t()}
  def render(report, config \\ %{}) do
    format = Map.get(config, "file_format", "CSV")
    mapping = Map.get(config, "export_mapping", %{})
    date_format = Map.get(config, "date_format")

    content =
      case format do
        "JSON" -> render_json(report, mapping, date_format)
        _ -> render_csv(report, mapping, date_format)
      end

    {:ok, content, format}
  end

  defp render_csv(report, mapping, date_format) do
    header = @fields |> Enum.map(&label(&1, mapping)) |> Enum.join(",")

    lines =
      Enum.map(report.rows, fn row ->
        @fields
        |> Enum.map(&csv_value(row, &1, date_format))
        |> Enum.join(",")
      end)

    Enum.join([header | lines], "\n") <> "\n"
  end

  defp render_json(report, mapping, date_format) do
    report.rows
    |> Enum.map(fn row ->
      Map.new(@fields, fn field -> {label(field, mapping), value(row, field, date_format)} end)
    end)
    |> Jason.encode!(pretty: true)
  end

  # Column order stays canonical regardless of mapping — only the label changes.
  # Reordering on a regulator's say-so would make two employers' reports
  # structurally different for no reason.
  defp label(field, mapping), do: Map.get(mapping, Atom.to_string(field), Atom.to_string(field))

  defp csv_value(row, field, date_format) do
    raw = value(row, field, date_format) |> to_string()

    # Quote anything that would otherwise break the row — failure reasons
    # contain commas routinely.
    if String.contains?(raw, [",", "\"", "\n"]) do
      ~s(") <> String.replace(raw, ~s("), ~s("")) <> ~s(")
    else
      raw
    end
  end

  defp value(row, field, date_format) do
    case Map.get(row, field) do
      nil -> ""
      %Date{} = date -> format_date(date, date_format)
      %Decimal{} = amount -> Decimal.to_string(amount)
      other -> other
    end
  end

  defp format_date(date, nil), do: Date.to_iso8601(date)

  defp format_date(date, format) do
    format
    |> String.replace("%Y", pad(date.year, 4))
    |> String.replace("%m", pad(date.month, 2))
    |> String.replace("%d", pad(date.day, 2))
  end

  defp pad(value, width), do: value |> Integer.to_string() |> String.pad_leading(width, "0")
end
