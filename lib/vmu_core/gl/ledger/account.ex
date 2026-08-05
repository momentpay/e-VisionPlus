defmodule VmuCore.GL.Account do
  @moduledoc """
  One account in the enterprise Chart of Accounts (GL Phase A1).

  Replaces the two conflicting hardcoded code sets described in
  `docs/gl/GL_Module_Design_and_Plan.md` §9 — `FAS.GL.CardAccountCodes`
  (5 codes) and `CMS.InternalGlPoster` (12 codes), which disagree about
  what 2001, 4001, 5001 and 1006 mean while both writing to
  `cms_ledger_entries`.

  ## Normal balance

  `normal_balance` is derived from `account_class` and is enforced by a DB
  check constraint, not just here — asset/expense are debit-normal,
  liability/equity/revenue are credit-normal. A wrong value silently
  inverts every balance computed from the account, which is the kind of
  defect that surfaces months later in a trial balance nobody can explain.

  ## `owner_module`

  Each account names the module responsible for it. This is the
  chart-of-accounts half of the ownership discipline in
  `docs/architecture/Kosa_Domain_Ownership_Map.md` — it makes "who is
  allowed to post here" answerable from data.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:code, :string, autogenerate: false}
  @derive {Phoenix.Param, key: :code}

  @classes ~w[asset liability equity revenue expense]
  @debit_normal_classes ~w[asset expense]

  @type t :: %__MODULE__{}

  schema "gl_accounts" do
    field :name,            :string
    field :account_class,   :string
    field :normal_balance,  :string
    field :owner_module,    :string
    field :currency,        :string
    field :active,          :boolean, default: true
    field :description,     :string
    field :legacy_conflict, :string

    timestamps(type: :utc_datetime)
  end

  @required ~w[code name account_class owner_module]a
  @optional ~w[normal_balance currency active description legacy_conflict]a

  def changeset(account, attrs) do
    account
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:account_class, @classes)
    |> validate_format(:code, ~r/^\d{4}$/, message: "must be a 4-digit account code")
    |> put_normal_balance()
    |> validate_inclusion(:normal_balance, ~w[debit credit])
  end

  @doc """
  Normal balance is a function of the class, never an independent input —
  callers cannot set them inconsistently.
  """
  def normal_balance_for(class) when class in @debit_normal_classes, do: "debit"
  def normal_balance_for(class) when class in @classes, do: "credit"

  def classes, do: @classes

  defp put_normal_balance(changeset) do
    case get_field(changeset, :account_class) do
      nil   -> changeset
      class -> put_change(changeset, :normal_balance, normal_balance_for(class))
    end
  end
end
