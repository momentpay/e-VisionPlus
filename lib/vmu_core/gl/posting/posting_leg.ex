defmodule VmuCore.Posting.PostingLeg do
  @moduledoc """
  One directional movement against one GL account (Koṣa DOC-109 §25).

  Amounts are always **positive**; direction carries the sign. Signed amounts
  make every aggregation depend on getting the sign convention right at each
  call site, which is a reliable source of defects in ledger code.

  `gl_account` has a real foreign key to `gl_accounts`, so a leg cannot
  reference an account the chart does not contain. That constraint already
  earned its place during Phase A2 — it caught `5003`, a code live wallet
  postings use that no chart of accounts had ever registered.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VmuCore.Posting.PostingEntry

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @directions ~w[debit credit]

  schema "posting_legs" do
    field :direction,  :string
    field :gl_account, :string
    field :amount,     :decimal
    field :currency,   :string

    belongs_to :posting_entry, PostingEntry

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[posting_entry_id direction gl_account amount currency]a

  def changeset(leg, attrs) do
    leg
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> validate_inclusion(:direction, @directions)
    |> validate_number(:amount, greater_than: Decimal.new(0))
    |> validate_length(:currency, is: 3)
    |> foreign_key_constraint(:posting_entry_id)
    |> foreign_key_constraint(:gl_account)
    |> check_constraint(:direction, name: :posting_legs_direction_check)
    |> check_constraint(:amount, name: :posting_legs_amount_positive_check)
  end

  @doc """
  Signed value for aggregation: debits positive, credits negative.

  Use only when summing; never persist the result.
  """
  @spec signed_amount(t()) :: Decimal.t()
  def signed_amount(%__MODULE__{direction: "debit", amount: amount}), do: amount
  def signed_amount(%__MODULE__{direction: "credit", amount: amount}), do: Decimal.negate(amount)

  def directions, do: @directions
end
