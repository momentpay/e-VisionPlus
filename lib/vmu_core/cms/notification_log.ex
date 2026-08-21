defmodule VmuCore.CMS.NotificationLog do
  @moduledoc """
  Ecto schema for `cms_notification_log` (FR-070) — one row per outbound
  notification attempt (one event can fan out to several channels).

  Written by `VmuCore.CMS.Notification`, dispatched via
  `VmuCore.CMS.NotificationDispatcher`. Schema + simple query helpers only.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias VmuCore.Repo

  @primary_key {:notification_id, :binary_id, autogenerate: true}

  @valid_channels ~w[email sms whatsapp webhook]
  @valid_statuses ~w[SENT FAILED SKIPPED]

  schema "cms_notification_log" do
    field :account_id,     :binary_id
    field :event_type,     :string
    field :channel,        :string
    field :content,        :string
    field :content_format, :string
    field :priority,       :string, default: "normal"
    field :status,         :string
    field :response,       :map
    field :idempotency_key, :string

    timestamps()
  end

  @required [:account_id, :event_type, :channel, :content, :content_format,
             :status, :idempotency_key]
  @optional [:priority, :response]

  def changeset(log, attrs) do
    log
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:channel, @valid_channels)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:idempotency_key)
  end

  @doc "All notification attempts for an account, newest first."
  @spec list_for_account(Ecto.UUID.t()) :: [t()]
  def list_for_account(account_id) do
    Repo.all(
      from n in __MODULE__,
        where: n.account_id == ^account_id,
        order_by: [desc: n.inserted_at]
    )
  end

  @type t :: %__MODULE__{}
end
