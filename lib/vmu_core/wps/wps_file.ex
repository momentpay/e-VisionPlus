defmodule VmuCore.WPS.WpsFile do
  @moduledoc """
  An ingested salary file (W2).

  ## Status

  | | |
  |---|---|
  | `PARSED` | read and validated, nothing posted |
  | `POSTING` | batch disbursement in progress |
  | `COMPLETED` | every line reached a terminal state |
  | `REJECTED` | refused whole — e.g. a duplicate content hash |

  A file's status is separate from its lines' because they fail independently:
  a file can parse completely and still contain lines that cannot be paid.
  "17 of 400 failed, the rest paid" is the normal outcome for a WPS batch, not
  an exception, and `COMPLETED` means *resolved*, not *all successful*.

  ## `layout_snapshot`

  The parsing configuration as it was at ingestion, copied in rather than
  referenced. Per-employer layout config changes, and an operator investigating
  a file months later needs to know how it *was* parsed, not how it would be
  parsed today. Without the snapshot a re-parse is not reproducible.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VmuCore.WPS.{Employer, SalaryCredit}

  @primary_key {:wps_file_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @statuses ~w[PARSED POSTING COMPLETED REJECTED]

  schema "wps_files" do
    field :filename, :string
    field :content_hash, :string
    field :byte_size, :integer

    field :file_format, :string
    field :layout_snapshot, :map, default: %{}

    field :status, :string, default: "PARSED"

    field :line_count, :integer, default: 0
    field :parsed_count, :integer, default: 0
    field :error_count, :integer, default: 0
    field :total_net_amount, :decimal, default: Decimal.new(0)
    field :currency, :string

    field :parse_errors, :map, default: %{}

    field :uploaded_by, :string
    field :ingested_at, :utc_datetime_usec
    field :rejected_reason, :string

    belongs_to :employer, Employer, foreign_key: :employer_id, references: :employer_id
    has_many :salary_credits, SalaryCredit, foreign_key: :wps_file_id

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[employer_id filename content_hash]a
  @optional ~w[byte_size file_format layout_snapshot status line_count parsed_count
               error_count total_net_amount currency parse_errors uploaded_by
               ingested_at rejected_reason]a

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(file, attrs) do
    file
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> check_constraint(:status, name: :wps_files_status_check)
  end

  @doc "Statuses a file may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  SHA-256 of the raw bytes — the duplicate guard.

  Hashing content rather than trusting a filename or sequence number: a file
  re-sent after a failed transmission is byte-identical, while a corrected
  resubmission is not, so the hash tells the two apart without the employer
  having to get anything right.
  """
  @spec hash(binary()) :: String.t()
  def hash(raw_bytes) when is_binary(raw_bytes) do
    :crypto.hash(:sha256, raw_bytes) |> Base.encode16(case: :lower)
  end

  @doc "True when the file is in a state where its lines may be disbursed."
  @spec postable?(t()) :: boolean()
  def postable?(%__MODULE__{status: s}), do: s in ["PARSED", "POSTING", "COMPLETED"]
end
