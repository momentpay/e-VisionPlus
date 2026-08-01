defmodule VmuCore.NTS.PushProvisioningSession do
  @moduledoc """
  Tracks one MDES Token Connect browser-redirect provisioning attempt —
  NTS Phase F2 (2026-08-02). See `PushProvisioningSessions`' moduledoc
  for the full lifecycle.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:session_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @directions ~w[push pull]
  @statuses ~w[PENDING COMPLETED FAILED AUTH_REQUIRED]

  schema "nts_push_sessions" do
    field :card_id,                 :binary_id
    field :customer_id,             :binary_id
    field :token_id,                :binary_id
    field :token_requestor_id,      :string
    field :direction,               :string, default: "push"
    field :push_account_receipt,    :string
    field :wallet_session_id,       :string
    field :wallet_callback_url,     :string
    field :status,                  :string, default: "PENDING"
    field :requires_authentication, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @required ~w[card_id customer_id token_id token_requestor_id]a
  @optional ~w[direction push_account_receipt wallet_session_id wallet_callback_url status requires_authentication]a

  def changeset(session, attrs) do
    session
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:direction, @directions)
    |> validate_inclusion(:status, @statuses)
  end
end
