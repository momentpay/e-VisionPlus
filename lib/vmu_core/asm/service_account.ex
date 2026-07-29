defmodule VmuCore.ASM.ServiceAccount do
  @moduledoc """
  Machine-caller identity for external API access (KYC-P5,
  `docs/kyc/KYC_Implementation_Tracker.md` §7) — distinct from `ASM.Operator`
  (human, PBKDF2-password, session-cookie login): service accounts are
  bearer-token, no session, no password policy, for callers like wallet-app
  or Kosa App.

  The `asm_service_accounts` table itself predates this module (migration
  `20260712000002`, 2026-07-12) — this schema, its context (`ASM.
  ServiceAccounts`), and the auth plug were never actually built despite a
  since-corrected stale doc claiming they were
  (`docs/shared/NEW_PRODUCTS_PROGRAM_TRACKER.md`); this is the real first
  implementation, verified against the real migrated table, not assumed
  from that doc.

  `token_hash` is a SHA-256 hex digest of the raw bearer token — a random
  256-bit secret, not a human password, so PBKDF2's slow-hashing purpose
  (defeating offline dictionary attacks) doesn't apply; a fast hash is
  correct here, same reasoning most API-token systems use. The raw token
  is generated once at creation and never stored — see `ASM.
  ServiceAccounts.create/1`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:service_account_id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  @statuses ~w[ACTIVE REVOKED]
  @scopes ~w[kyc:read kyc:write wallet:read wallet:write]

  schema "asm_service_accounts" do
    field :name, :string
    field :token_hash, :string, redact: true
    field :scopes, {:array, :string}, default: []
    field :status, :string, default: "ACTIVE"
    field :last_used_at, :utc_datetime
    field :created_by, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[name token_hash]a
  @optional ~w[scopes status last_used_at created_by]a

  @doc false
  def changeset(service_account, attrs) do
    service_account
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_subset(:scopes, @scopes)
    |> unique_constraint(:token_hash)
    |> unique_constraint(:name)
  end

  @doc "The fixed list of grantable API scopes."
  def scopes, do: @scopes

  @doc "Statuses a service account can be in."
  def statuses, do: @statuses

  @doc "Whether this account has `scope` and is active."
  @spec authorized?(t(), String.t()) :: boolean()
  def authorized?(%__MODULE__{status: "ACTIVE", scopes: scopes}, scope), do: scope in scopes
  def authorized?(%__MODULE__{}, _scope), do: false
end
