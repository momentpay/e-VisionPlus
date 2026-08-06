defmodule VmuCore.Posting.Rule do
  @moduledoc """
  One posting rule: `{event_type, product}` → a debit/credit account pair
  (GL Phase A2).

  Each rule carries two pairs — the reconciled target (`dr_account`/
  `cr_account`) and, where the live code still disagrees, what it actually
  posts today (`legacy_dr_account`/`legacy_cr_account`). See the migration
  moduledoc for why.

  `legacy?/1` is therefore the operational question "does this rule still
  need a Phase C cutover".
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @event_types ~w[
    PURCHASE CASH_ADV DEPOSIT WITHDRAWAL PAYMENT
    INTEREST FEE SETTLEMENT REVERSAL RECOVERY
    ADJUSTMENT_CREDIT ADJUSTMENT_DEBIT DISPUTE_CREDIT
  ]

  # `PostingSet` and `JournalEntry` both validate against `products/0`, so this
  # list is the one place a product becomes legal across the whole engine.
  #
  # HCS_FLEET and HCS_CORPORATE are overlays on `cms_accounts` rather than
  # separate account tables — see `GL.InstitutionResolver` — but they are real
  # products here, with their own receivables, because corporate fleet exposure
  # and consumer card exposure are different credit risks and finance reports
  # them separately.
  @products ~w[CREDIT CREDIT_CARD HCS_FLEET HCS_CORPORATE DEBIT PREPAID WPS_PREPAID WALLET]

  schema "posting_rules" do
    field :event_type,             :string
    field :product,                :string
    field :dr_account,             :string
    field :cr_account,             :string
    field :legacy_dr_account,      :string
    field :legacy_cr_account,      :string
    field :legacy_transaction_code, :string
    field :narrative_template,     :string
    field :source_module,          :string
    field :active,                 :boolean, default: true
    field :notes,                  :string

    timestamps(type: :utc_datetime)
  end

  @required ~w[event_type product dr_account cr_account legacy_transaction_code
               narrative_template source_module]a
  @optional ~w[legacy_dr_account legacy_cr_account active notes]a

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:event_type, @event_types)
    |> validate_inclusion(:product, @products)
    |> validate_distinct_accounts()
    |> validate_legacy_pair()
    |> unique_constraint([:event_type, :product])
    |> foreign_key_constraint(:dr_account)
    |> foreign_key_constraint(:cr_account)
    |> foreign_key_constraint(:legacy_dr_account)
    |> foreign_key_constraint(:legacy_cr_account)
    |> check_constraint(:dr_account, name: :posting_rules_distinct_accounts_check)
  end

  @doc """
  The account pair this rule posts with today. Falls back to the reconciled
  pair when there is no divergence — so callers never branch on nil.
  """
  @spec legacy_pair(t()) :: {String.t(), String.t()}
  def legacy_pair(%__MODULE__{legacy_dr_account: nil, dr_account: dr, cr_account: cr}), do: {dr, cr}
  def legacy_pair(%__MODULE__{legacy_dr_account: dr, legacy_cr_account: cr}), do: {dr, cr}

  @doc "The reconciled account pair — the Phase C target."
  @spec pair(t()) :: {String.t(), String.t()}
  def pair(%__MODULE__{dr_account: dr, cr_account: cr}), do: {dr, cr}

  @doc "True when the live posting path still disagrees with the reconciled chart."
  @spec legacy?(t()) :: boolean()
  def legacy?(%__MODULE__{legacy_dr_account: nil}), do: false
  def legacy?(%__MODULE__{}), do: true

  @doc """
  Renders `narrative_template` against a binding map.

  Placeholders are `{name}`. An unfilled placeholder is left verbatim rather
  than raising — a posting must never fail because a narrative was missing a
  cosmetic value.
  """
  @spec render_narrative(t(), map()) :: String.t()
  def render_narrative(%__MODULE__{narrative_template: template}, bindings \\ %{}) do
    Regex.replace(~r/\{(\w+)\}/, template, fn whole, key ->
      case Map.fetch(bindings, key) do
        {:ok, value} -> to_string(value)
        :error       -> whole
      end
    end)
  end

  def event_types, do: @event_types
  def products,    do: @products

  defp validate_distinct_accounts(changeset) do
    dr = get_field(changeset, :dr_account)
    cr = get_field(changeset, :cr_account)

    if not is_nil(dr) and dr == cr do
      add_error(changeset, :cr_account, "must differ from dr_account")
    else
      changeset
    end
  end

  defp validate_legacy_pair(changeset) do
    case {get_field(changeset, :legacy_dr_account), get_field(changeset, :legacy_cr_account)} do
      {nil, nil} -> changeset
      {_, nil}   -> add_error(changeset, :legacy_cr_account, "required when legacy_dr_account is set")
      {nil, _}   -> add_error(changeset, :legacy_dr_account, "required when legacy_cr_account is set")
      _          -> changeset
    end
  end
end
