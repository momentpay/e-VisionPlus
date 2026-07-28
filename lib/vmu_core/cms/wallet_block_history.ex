defmodule VmuCore.CMS.WalletBlockHistory do
  @moduledoc """
  Append-only audit log for block code changes on `CMS.WalletAccount` —
  Digital Wallet Phase W1 (2026-07-28), mirrors `CMS.DebitBlockHistory`
  exactly (own table, own FK).
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias VmuCore.{Repo, CMS.WalletAccount}

  @primary_key {:id, :binary_id, autogenerate: true}

  @actions        ~w[BLOCKED UNBLOCKED]
  @operator_roles ~w[AGENT SUPERVISOR SYSTEM]
  @valid_reason_codes ~w[
    REPORTED_LOST REPORTED_STOLEN FRAUD_ALERT COLLECTIONS_HOLD
    CUSTOMER_REQUEST EOD_AUTOMATED INVESTIGATION_CLOSED PAYMENT_RECEIVED
    SUPERVISOR_OVERRIDE
  ]

  schema "cms_wallet_block_history" do
    field :wallet_account_id, :binary_id
    field :block_code,        :string
    field :action,            :string
    field :reason_code,       :string
    field :reason_text,       :string
    field :operator_id,       :binary_id
    field :operator_role,     :string, default: "AGENT"
    field :applied_at,        :naive_datetime
  end

  @type t :: %__MODULE__{}

  @required [:wallet_account_id, :action, :reason_code, :operator_id]
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
  def record_block(wallet_account_id, block_code, reason_code, reason_text, operator_id, operator_role \\ "AGENT") do
    Repo.transaction(fn ->
      Repo.update_all(
        from(a in WalletAccount, where: a.wallet_account_id == ^wallet_account_id),
        set: [
          block_code:   block_code,
          block_reason: reason_text,
          blocked_at:   NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
          updated_at:   DateTime.utc_now()
        ]
      )

      %__MODULE__{}
      |> changeset(%{
        wallet_account_id: wallet_account_id,
        block_code:         block_code,
        action:             "BLOCKED",
        reason_code:        reason_code,
        reason_text:        reason_text,
        operator_id:        operator_id,
        operator_role:      operator_role
      })
      |> Repo.insert!()
    end)
  end

  @spec record_unblock(Ecto.UUID.t(), String.t(), String.t(), String.t() | nil, Ecto.UUID.t(), String.t()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def record_unblock(wallet_account_id, block_code, reason_code, reason_text, operator_id, operator_role \\ "AGENT") do
    Repo.transaction(fn ->
      Repo.update_all(
        from(a in WalletAccount, where: a.wallet_account_id == ^wallet_account_id),
        set: [
          block_code:   nil,
          block_reason: nil,
          blocked_at:   nil,
          updated_at:   DateTime.utc_now()
        ]
      )

      %__MODULE__{}
      |> changeset(%{
        wallet_account_id: wallet_account_id,
        block_code:         block_code,
        action:             "UNBLOCKED",
        reason_code:        reason_code,
        reason_text:        reason_text,
        operator_id:        operator_id,
        operator_role:      operator_role
      })
      |> Repo.insert!()
    end)
  end

  @spec history_for(Ecto.UUID.t()) :: [t()]
  def history_for(wallet_account_id) do
    Repo.all(
      from h in __MODULE__,
        where: h.wallet_account_id == ^wallet_account_id,
        order_by: [desc: h.applied_at]
    )
  end

  defp put_applied_at(%Ecto.Changeset{} = cs) do
    if get_field(cs, :applied_at),
      do: cs,
      else: put_change(cs, :applied_at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))
  end
end
