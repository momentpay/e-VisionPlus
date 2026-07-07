defmodule VmuCore.CMS.BlockCodeHistory do
  @moduledoc """
  Append-only audit log for block code changes on CMS accounts.

  Every time an operator applies or removes a block code, a row is inserted here.
  Rows are **never updated or deleted** — this table is a tamper-evident audit
  trail for compliance, fraud investigation, and regulatory review.

  ## Usage

      # Apply a fraud block
      BlockCodeHistory.record_block(account_id, "F", "FRAUD_ALERT",
        "Card used in suspicious location", operator_id, "SUPERVISOR")

      # Remove a block
      BlockCodeHistory.record_unblock(account_id, "F", "INVESTIGATION_CLOSED",
        "Customer confirmed genuine transaction", operator_id, "SUPERVISOR")

  ## Actions

  - `BLOCKED`   — a block code was applied
  - `UNBLOCKED` — a block code was removed

  ## Reason Codes (structured)

  | Code                | Meaning                                      |
  |---------------------|----------------------------------------------|
  | REPORTED_LOST       | Cardholder reported card lost                |
  | REPORTED_STOLEN     | Cardholder reported card stolen              |
  | FRAUD_ALERT         | Fraud team flagged suspicious activity       |
  | COLLECTIONS_HOLD    | Account moved to collections queue           |
  | OVERLIMIT           | Balance exceeded credit limit                |
  | CUSTOMER_REQUEST    | Cardholder requested temporary block         |
  | EOD_AUTOMATED       | Applied by automated EOD batch process       |
  | INVESTIGATION_CLOSED| Block lifted after investigation completed   |
  | PAYMENT_RECEIVED    | Overlimit block lifted after payment         |
  | SUPERVISOR_OVERRIDE | Manual override by supervisor                |
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias VmuCore.Repo

  @primary_key {:id, :binary_id, autogenerate: true}

  @actions       ~w[BLOCKED UNBLOCKED]
  @operator_roles ~w[AGENT SUPERVISOR SYSTEM]
  @valid_reason_codes ~w[
    REPORTED_LOST REPORTED_STOLEN FRAUD_ALERT COLLECTIONS_HOLD OVERLIMIT
    CUSTOMER_REQUEST EOD_AUTOMATED INVESTIGATION_CLOSED PAYMENT_RECEIVED
    SUPERVISOR_OVERRIDE
  ]

  schema "block_code_history" do
    field :account_id,    :binary_id
    field :block_code,    :string         # nil for UNBLOCKED actions
    field :action,        :string
    field :reason_code,   :string
    field :reason_text,   :string
    field :operator_id,   :binary_id
    field :operator_role, :string, default: "AGENT"
    field :applied_at,    :naive_datetime
  end

  @type t :: %__MODULE__{}

  @required [:account_id, :action, :reason_code, :operator_id]
  @optional [:block_code, :reason_text, :operator_role, :applied_at]

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:operator_role, @operator_roles)
    |> validate_inclusion(:reason_code, @valid_reason_codes)
    |> validate_length(:reason_text, max: 200)
    |> put_applied_at()
  end

  # ── Convenience Functions ───────────────────────────────────────────────────

  @doc """
  Record a block being applied to an account.
  Also updates the block_code, block_reason, and blocked_at on the account row.

  Returns `{:ok, history_entry}` or `{:error, changeset}`.
  """
  @spec record_block(Ecto.UUID.t(), String.t(), String.t(), String.t() | nil, Ecto.UUID.t(), String.t()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def record_block(account_id, block_code, reason_code, reason_text, operator_id, operator_role \\ "AGENT") do
    Repo.transaction(fn ->
      # Update account block_code, block_reason, blocked_at
      Repo.update_all(
        from(a in VmuCore.CMS.Account, where: a.account_id == ^account_id),
        set: [
          block_code:   block_code,
          block_reason: reason_text,
          blocked_at:   NaiveDateTime.utc_now(),
          updated_at:   NaiveDateTime.utc_now()
        ]
      )

      # Append history entry
      %__MODULE__{}
      |> changeset(%{
        account_id:    account_id,
        block_code:    block_code,
        action:        "BLOCKED",
        reason_code:   reason_code,
        reason_text:   reason_text,
        operator_id:   operator_id,
        operator_role: operator_role
      })
      |> Repo.insert!()
    end)
  end

  @doc """
  Record a block being removed from an account.
  Clears block_code, block_reason, and blocked_at on the account row.

  Returns `{:ok, history_entry}` or `{:error, changeset}`.
  """
  @spec record_unblock(Ecto.UUID.t(), String.t(), String.t(), String.t() | nil, Ecto.UUID.t(), String.t()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def record_unblock(account_id, block_code, reason_code, reason_text, operator_id, operator_role \\ "AGENT") do
    Repo.transaction(fn ->
      Repo.update_all(
        from(a in VmuCore.CMS.Account, where: a.account_id == ^account_id),
        set: [
          block_code:   nil,
          block_reason: nil,
          blocked_at:   nil,
          updated_at:   NaiveDateTime.utc_now()
        ]
      )

      %__MODULE__{}
      |> changeset(%{
        account_id:    account_id,
        block_code:    block_code,  # record which code was removed
        action:        "UNBLOCKED",
        reason_code:   reason_code,
        reason_text:   reason_text,
        operator_id:   operator_id,
        operator_role: operator_role
      })
      |> Repo.insert!()
    end)
  end

  @doc "Returns the full block history for an account, most recent first."
  @spec history_for(Ecto.UUID.t()) :: [t()]
  def history_for(account_id) do
    Repo.all(
      from h in __MODULE__,
        where: h.account_id == ^account_id,
        order_by: [desc: h.applied_at]
    )
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp put_applied_at(%Ecto.Changeset{} = cs) do
    if get_field(cs, :applied_at),
      do:   cs,
      else: put_change(cs, :applied_at, NaiveDateTime.utc_now())
  end
end
