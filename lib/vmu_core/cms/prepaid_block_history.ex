defmodule VmuCore.CMS.PrepaidBlockHistory do
  @moduledoc """
  Append-only audit log for block code changes on `CMS.PrepaidAccount` —
  Card Products UX Parity Phase 2d (2026-07-28), mirrors `CMS.
  DebitBlockHistory` exactly (own table, own FK — see
  `cms_prepaid_block_history`'s migration moduledoc for why it isn't a
  shared/reused table).

  Account-level block, distinct from card-level block
  (`CTA.CardLifecycle.block/3`) — this freezes the whole Prepaid account
  relationship, independent of which specific card/plastic is blocked.

  ## Usage

      PrepaidBlockHistory.record_block(prepaid_account_id, "F", "FRAUD_ALERT",
        "Card used in suspicious location", operator_id, "SUPERVISOR")

      PrepaidBlockHistory.record_unblock(prepaid_account_id, "F", "INVESTIGATION_CLOSED",
        "Customer confirmed genuine transaction", operator_id, "SUPERVISOR")
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias VmuCore.{Repo, CMS.PrepaidAccount}

  @primary_key {:id, :binary_id, autogenerate: true}

  @actions        ~w[BLOCKED UNBLOCKED]
  @operator_roles ~w[AGENT SUPERVISOR SYSTEM]
  @valid_reason_codes ~w[
    REPORTED_LOST REPORTED_STOLEN FRAUD_ALERT COLLECTIONS_HOLD
    CUSTOMER_REQUEST EOD_AUTOMATED INVESTIGATION_CLOSED PAYMENT_RECEIVED
    SUPERVISOR_OVERRIDE
  ]

  schema "cms_prepaid_block_history" do
    field :prepaid_account_id, :binary_id
    field :block_code,         :string
    field :action,             :string
    field :reason_code,        :string
    field :reason_text,        :string
    field :operator_id,        :binary_id
    field :operator_role,      :string, default: "AGENT"
    field :applied_at,         :naive_datetime
  end

  @type t :: %__MODULE__{}

  @required [:prepaid_account_id, :action, :reason_code, :operator_id]
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

  @spec record_block(Ecto.UUID.t(), String.t(), String.t(), String.t() | nil, Ecto.UUID.t(), String.t()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def record_block(prepaid_account_id, block_code, reason_code, reason_text, operator_id, operator_role \\ "AGENT") do
    Repo.transaction(fn ->
      Repo.update_all(
        from(a in PrepaidAccount, where: a.prepaid_account_id == ^prepaid_account_id),
        set: [
          block_code:   block_code,
          block_reason: reason_text,
          blocked_at:   NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
          updated_at:   DateTime.utc_now()
        ]
      )

      %__MODULE__{}
      |> changeset(%{
        prepaid_account_id: prepaid_account_id,
        block_code:          block_code,
        action:              "BLOCKED",
        reason_code:         reason_code,
        reason_text:         reason_text,
        operator_id:         operator_id,
        operator_role:       operator_role
      })
      |> Repo.insert!()
    end)
  end

  @spec record_unblock(Ecto.UUID.t(), String.t(), String.t(), String.t() | nil, Ecto.UUID.t(), String.t()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def record_unblock(prepaid_account_id, block_code, reason_code, reason_text, operator_id, operator_role \\ "AGENT") do
    Repo.transaction(fn ->
      Repo.update_all(
        from(a in PrepaidAccount, where: a.prepaid_account_id == ^prepaid_account_id),
        set: [
          block_code:   nil,
          block_reason: nil,
          blocked_at:   nil,
          updated_at:   DateTime.utc_now()
        ]
      )

      %__MODULE__{}
      |> changeset(%{
        prepaid_account_id: prepaid_account_id,
        block_code:          block_code,
        action:              "UNBLOCKED",
        reason_code:         reason_code,
        reason_text:         reason_text,
        operator_id:         operator_id,
        operator_role:       operator_role
      })
      |> Repo.insert!()
    end)
  end

  @spec history_for(Ecto.UUID.t()) :: [t()]
  def history_for(prepaid_account_id) do
    Repo.all(
      from h in __MODULE__,
        where: h.prepaid_account_id == ^prepaid_account_id,
        order_by: [desc: h.applied_at]
    )
  end

  defp put_applied_at(%Ecto.Changeset{} = cs) do
    if get_field(cs, :applied_at),
      do: cs,
      else: put_change(cs, :applied_at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))
  end
end
