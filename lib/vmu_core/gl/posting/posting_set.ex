defmodule VmuCore.Posting.PostingSet do
  @moduledoc """
  One financial execution — the Posting aggregate root (Koṣa DOC-109 §22,
  WAY4's macrotransaction).

  A set holds one or more `PostingEntry` rows, each of which holds its own
  balanced legs. The set is the unit of idempotency and the unit that carries
  the four dates.

  ## The four dates

  | Field | Meaning |
  |---|---|
  | `transaction_date` | When the transaction actually happened. Nullable — interest accrual and other internally-generated executions have no external transaction |
  | `posting_date` | When the financial consequence takes effect. Drives FX rule selection, fee calculation, interest cycle start. **A reversal carries the original set's posting_date** |
  | `gl_date` | When it lands on GL accounts. Normally the banking date. **A reversal carries the *current* banking date, not the original** |
  | `banking_date` | The banking day the set was posted in |

  `cms_ledger_entries` has only `posting_date` and `value_date` and therefore
  cannot express that reversal case at all — which is the main reason this
  table exists.

  ## `account_ref`

  Deliberately a plain string with no foreign key. It addresses
  `cms_accounts`, `cms_debit_accounts`, `cms_prepaid_accounts` and
  `cms_wallet_accounts`, which do not share a key type — the same constraint
  `cms_arrangements.account_ref` already lives with.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VmuCore.Posting.{PostingEntry, Rule}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @statuses ~w[DRAFT POSTED REVERSED FAILED]

  schema "posting_sets" do
    # Which institution's books this execution belongs to. Both the period
    # gate and GL consolidation key on it, and `banking_date` below is only
    # meaningful alongside it.
    field :sys_id,  :string
    field :bank_id, :string

    field :event_type,      :string
    field :product,         :string
    field :account_ref,     :string
    field :idempotency_key, :string
    field :status,          :string, default: "DRAFT"
    field :currency,        :string, default: "AED"
    field :total_amount,    :decimal

    field :transaction_date, :date
    field :posting_date,     :date
    field :gl_date,          :date
    field :banking_date,     :date

    field :narrative,      :string
    field :source_module,  :string
    field :correlation_id, :string

    belongs_to :posting_rule, Rule, type: :id
    belongs_to :reverses, __MODULE__, type: :binary_id

    has_many :entries, PostingEntry, foreign_key: :posting_set_id

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[event_type product account_ref idempotency_key total_amount
               posting_date gl_date banking_date source_module]a
  @optional ~w[status currency transaction_date narrative correlation_id
               posting_rule_id reverses_id sys_id bank_id]a

  def changeset(set, attrs) do
    set
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:event_type, Rule.event_types())
    |> validate_inclusion(:product, Rule.products())
    |> validate_number(:total_amount, greater_than: Decimal.new(0))
    |> validate_length(:currency, is: 3)
    |> unique_constraint(:idempotency_key)
    |> foreign_key_constraint(:posting_rule_id)
    |> check_constraint(:status, name: :posting_sets_status_check)
    |> check_constraint(:total_amount, name: :posting_sets_amount_positive_check)
  end

  @doc """
  Builds the reversal of `set`.

  The date handling is the whole point: `posting_date` is inherited so the
  reversal lands in the same financial period as the original, while
  `gl_date` and `banking_date` are today's — the books record the correction
  when it was made, not when the original was.
  """
  @spec reversal_attrs(t(), Date.t(), String.t()) :: map()
  def reversal_attrs(%__MODULE__{} = set, current_banking_date, idempotency_key) do
    %{
      event_type:       "REVERSAL",
      product:          set.product,
      account_ref:      set.account_ref,
      idempotency_key:  idempotency_key,
      currency:         set.currency,
      total_amount:     set.total_amount,
      transaction_date: set.transaction_date,
      posting_date:     set.posting_date,
      gl_date:          current_banking_date,
      banking_date:     current_banking_date,
      narrative:        "Reversal of #{set.idempotency_key}",
      source_module:    set.source_module,
      correlation_id:   set.correlation_id,
      sys_id:           set.sys_id,
      bank_id:          set.bank_id,
      reverses_id:      set.id
    }
  end

  def statuses, do: @statuses
end
