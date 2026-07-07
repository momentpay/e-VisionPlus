defmodule VmuCore.FAS.ExceptionQueue do
  @moduledoc """
  Persistent exception log for unmatched 0400 reversals (FAS-P6 6B).

  When a reversal arrives with no matching fas_authorization, the raw request
  is stored here with status "pending" so ops can investigate and manually
  release or escalate the exception. RC "25" is returned to the network.

  Statuses: pending → escalated → resolved
  """

  use Ecto.Schema
  import Ecto.Changeset
  require Logger

  alias VmuCore.Repo

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "fas_reversal_exceptions" do
    field :pan_token,    :string
    field :mti,          :string
    field :stan,         :string
    field :rrn,          :string
    field :terminal_id,  :string
    field :approval_code, :string
    field :raw_fields,   :map
    field :status,       :string, default: "pending"

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @valid_statuses ~w[pending escalated resolved]

  @required ~w[pan_token mti status]a
  @optional ~w[stan rrn terminal_id approval_code raw_fields]a

  def changeset(exc, attrs) do
    exc
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @valid_statuses)
  end

  @doc """
  Log an unmatched reversal. Fire-and-forget — caller should not need to
  handle the return value; errors are logged internally.
  """
  @spec insert_reversal_exception(map(), String.t()) :: :ok | :error
  def insert_reversal_exception(fields, pan_token) do
    attrs = %{
      pan_token:    pan_token,
      mti:          "0400",
      stan:         Map.get(fields, 11),
      rrn:          Map.get(fields, 37),
      terminal_id:  Map.get(fields, 41),
      approval_code: Map.get(fields, 38),
      # Stringify keys for JSONB storage — integer keys cause Jason issues
      raw_fields:   Map.new(fields, fn {k, v} -> {to_string(k), to_string(v)} end),
      status:       "pending"
    }

    case Repo.insert(changeset(%__MODULE__{}, attrs)) do
      {:ok, _}     -> :ok
      {:error, cs} ->
        Logger.error("[ExceptionQueue] Insert failed: #{inspect(cs.errors)}")
        :error
    end
  end
end
