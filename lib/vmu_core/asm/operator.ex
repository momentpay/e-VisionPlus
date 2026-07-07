defmodule VmuCore.ASM.Operator do
  @moduledoc """
  Back-office operator identity (ASM-P1, FR-ASM-001/004).

  Credentials are PBKDF2-SHA256 (100k iterations — same primitive as
  `cms_card_pins`). `role` gates permissions (matrix lands in ASM-P2);
  `bank_scope` restricts data visibility to one BANK (nil = all).

  Never expose `pw_hash`/`pw_salt` outside `VmuCore.ASM.Auth`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:operator_id, :binary_id, autogenerate: true}

  @roles    ~w[TELLER CS_AGENT OPS SUPERVISOR RISK COMPLIANCE ADMIN]
  @statuses ~w[ACTIVE LOCKED DISABLED]

  schema "asm_operators" do
    field :username,            :string
    field :display_name,        :string
    field :pw_hash,             :string, redact: true
    field :pw_salt,             :string, redact: true
    field :role,                :string, default: "CS_AGENT"
    field :status,              :string, default: "ACTIVE"
    field :bank_scope,          :string
    field :failed_attempts,     :integer, default: 0
    field :locked_at,           :utc_datetime
    field :last_login_at,       :utc_datetime
    field :password_changed_at, :utc_datetime

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[username display_name pw_hash pw_salt role status]a
  @optional ~w[bank_scope failed_attempts locked_at last_login_at password_changed_at]a

  def changeset(operator, attrs) do
    operator
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:username, min: 3, max: 40)
    |> validate_format(:username, ~r/^[a-z0-9._-]+$/,
         message: "lowercase letters, digits, dot, underscore, hyphen only")
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:bank_scope, is: 4)
    |> unique_constraint(:username)
  end

  def roles, do: @roles
end
