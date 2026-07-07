defmodule VmuCore.CMS.Bureau.ReportingData do
  @moduledoc """
  Shared data collection + field resolution for bureau format generators
  (CMS-G5.2).

  Generators are **layout** concerns; this module owns *what* gets reported:
  one row per reportable account = `%{account, customer, bucket}`, plus the
  `resolve/3` mini-language that format specs use to reference data:

      {:literal, "TUDF"}         — constant
      {:customer, :first_name}   — field off the CIF customer
      {:account, :credit_limit}  — field off the account
      {:bucket, :statement_balance}
      {:computed, :outstanding}  — derived values (see below)

  Computed values: `:report_date` (the as-of date), `:outstanding`
  (bucket total), `:days_past_due` (delinquency bucket), `:account_open_date`,
  `:masked_account_ref` (pan_token last 12 — never a raw PAN).

  Formatting helpers normalize Elixir values into bureau text: dates to the
  spec's format, Decimals to whole-unit integer strings, nil to "".
  """

  import Ecto.Query

  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket}
  alias VmuCore.Shared.Customer
  alias Decimal, as: D

  @reportable_statuses ~w[ACTIVE BLOCKED SUSPENDED DELINQUENT WRITTEN_OFF]

  @doc "Reportable rows for a product: `%{account, customer, bucket}` each."
  @spec rows(String.t(), String.t(), String.t()) :: [map()]
  def rows(sys_id, bank_id, logo_id) do
    accounts =
      Repo.all(
        from a in Account,
          where: a.sys_id == ^sys_id and a.bank_id == ^bank_id
             and a.logo_id == ^logo_id
             and a.account_status in ^@reportable_statuses
             and not is_nil(a.customer_id)
      )

    customer_ids = accounts |> Enum.map(& &1.customer_id) |> Enum.uniq()

    customers =
      Repo.all(from c in Customer, where: c.customer_id in ^customer_ids)
      |> Map.new(&{&1.customer_id, &1})

    Enum.flat_map(accounts, fn account ->
      case Map.get(customers, account.customer_id) do
        nil -> []
        customer -> [%{account: account, customer: customer, bucket: latest_bucket(account.account_id)}]
      end
    end)
  end

  @doc "Resolve a spec source against a row + context."
  @spec resolve(term(), map(), map()) :: term()
  def resolve({:literal, value}, _row, _ctx), do: value
  def resolve({:customer, field}, %{customer: c}, _ctx), do: Map.get(c, field)
  def resolve({:account, field}, %{account: a}, _ctx), do: Map.get(a, field)
  def resolve({:bucket, field}, %{bucket: nil}, _ctx) when field != nil, do: nil
  def resolve({:bucket, field}, %{bucket: b}, _ctx), do: Map.get(b, field)

  def resolve({:computed, :report_date}, _row, ctx), do: ctx.as_of
  def resolve({:computed, :outstanding}, %{bucket: nil}, _ctx), do: D.new(0)
  def resolve({:computed, :outstanding}, %{bucket: b}, _ctx), do: BalanceBucket.total(b)
  def resolve({:computed, :days_past_due}, %{account: a}, _ctx), do: a.delinquency_bucket || 0
  def resolve({:computed, :account_open_date}, %{account: a}, _ctx), do: a.open_date

  def resolve({:computed, :masked_account_ref}, %{account: a}, _ctx) do
    case a.pan_token do
      token when is_binary(token) -> String.slice(token, -12, 12)
      _ -> to_string(a.account_id) |> String.slice(0, 12)
    end
  end

  def resolve(nil, _row, _ctx), do: nil

  @doc "Normalize a resolved value to bureau text per the spec's date format."
  @spec to_text(term(), atom()) :: String.t()
  def to_text(nil, _date_format), do: ""
  def to_text(%Date{} = d, :ddmmyyyy), do: Calendar.strftime(d, "%d%m%Y")
  def to_text(%Date{} = d, :yyyymmdd), do: Calendar.strftime(d, "%Y%m%d")
  def to_text(%Date{} = d, :iso), do: Date.to_iso8601(d)
  def to_text(%D{} = dec, _), do: dec |> D.round(0) |> D.to_integer() |> Integer.to_string()
  def to_text(v, _) when is_binary(v), do: v
  def to_text(v, _), do: to_string(v)

  @doc "Fixed-width field: truncate + pad (`:left` = value left-aligned, space-padded right)."
  @spec fixed(String.t(), non_neg_integer(), :left | :right, String.t()) :: String.t()
  def fixed(text, length, align \\ :left, pad_char \\ " ") do
    truncated = String.slice(text, 0, length)

    case align do
      :left  -> String.pad_trailing(truncated, length, pad_char)
      :right -> String.pad_leading(truncated, length, pad_char)
    end
  end

  defp latest_bucket(account_id) do
    Repo.one(
      from b in BalanceBucket,
        where: b.account_id == ^account_id,
        order_by: [desc: b.balance_date],
        limit: 1
    )
  end
end
