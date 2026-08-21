defmodule VmuCore.CAM.OtpChallenge do
  @moduledoc """
  A one-time login code issued to a cardholder — Cardholder Access
  Management (CAM) Phase F1 (2026-08-02). Only `code_hash` (SHA-256 of the
  raw 6-digit code) is ever persisted, mirroring `ASM.ServiceAccount.
  token_hash`'s discipline — the raw code exists only in memory long
  enough to be dispatched via `CMS.NotificationDispatcher`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:otp_challenge_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @purposes ~w[LOGIN]
  @max_attempts 5

  schema "cam_otp_challenges" do
    field :customer_id, :binary_id
    field :purpose,     :string, default: "LOGIN"
    field :code_hash,   :string
    field :attempts,    :integer, default: 0
    field :expires_at,  :utc_datetime
    field :consumed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required ~w[customer_id purpose code_hash expires_at]a
  @optional ~w[attempts consumed_at]a

  def changeset(challenge, attrs) do
    challenge
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:purpose, @purposes)
  end

  def max_attempts, do: @max_attempts
end
