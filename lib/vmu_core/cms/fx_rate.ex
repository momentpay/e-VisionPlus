defmodule VmuCore.CMS.FxRate do
  @moduledoc """
  FX rate point-in-time record.

  `rate` is the multiplier: amount_in_from_currency * rate = amount_in_to_currency.

  Example: from_currency="USD", to_currency="AED", rate=3.6725
    100 USD * 3.6725 = 367.25 AED
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:rate_id, :binary_id, autogenerate: true}

  schema "fx_rates" do
    field :from_currency,  :string
    field :to_currency,    :string
    field :rate,           :decimal
    field :effective_date, :date
    field :source,         :string
    field :bank_id,        :string

    timestamps()
  end

  @required [:from_currency, :to_currency, :rate, :effective_date]
  @optional [:source, :bank_id]

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:from_currency, is: 3)
    |> validate_length(:to_currency, is: 3)
    |> validate_number(:rate, greater_than: Decimal.new(0))
  end
end
