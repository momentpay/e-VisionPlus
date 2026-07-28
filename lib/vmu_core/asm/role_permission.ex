defmodule VmuCore.ASM.RolePermission do
  @moduledoc """
  One (role, module, action) grant (ASM-P2, ADR-A3).

  `default_matrix/0` is the shipped baseline — seeded by
  `priv/repo/seed_role_permissions.exs` and editable at runtime (the matrix
  is data; role changes are inserts/deletes, not deployments). ADMIN has no
  rows: it is a code short-circuit in `VmuCore.ASM.Authz`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @actions ~w[view create edit approve]
  @modules ~w[system organization logo block customer account
              exceptions auth_history tram_inquiry operators approvals audit_log dps cms_eod cms_resegmentation col collections_mi hcs debit prepaid]

  schema "asm_role_permissions" do
    field :role,   :string
    field :module, :string
    field :action, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(perm, attrs) do
    perm
    |> cast(attrs, [:role, :module, :action])
    |> validate_required([:role, :module, :action])
    |> validate_inclusion(:role, VmuCore.ASM.Operator.roles())
    |> validate_inclusion(:module, @modules)
    |> validate_inclusion(:action, @actions)
    |> unique_constraint([:role, :module, :action])
  end

  def modules, do: @modules
  def actions, do: @actions

  @doc """
  Shipped default matrix as `{role, module, actions}` — expanded to rows by
  the seed script. Business review expected in ASM-P2 sign-off.
  """
  def default_matrix do
    [
      # SUPERVISOR — sees everything, edits operational data, approves 4-eyes
      {"SUPERVISOR", "system",       ~w[view]},
      {"SUPERVISOR", "organization", ~w[view]},
      {"SUPERVISOR", "logo",         ~w[view edit]},
      {"SUPERVISOR", "block",        ~w[view edit]},
      {"SUPERVISOR", "customer",     ~w[view create edit]},
      {"SUPERVISOR", "account",      ~w[view create edit approve]},
      {"SUPERVISOR", "exceptions",   ~w[view edit approve]},
      {"SUPERVISOR", "auth_history", ~w[view]},
      {"SUPERVISOR", "tram_inquiry", ~w[view approve]},
      {"SUPERVISOR", "approvals",    ~w[view approve]},
      {"SUPERVISOR", "dps",          ~w[view create edit approve]},
      {"SUPERVISOR", "cms_eod",      ~w[view edit]},
      {"SUPERVISOR", "cms_resegmentation", ~w[view edit]},
      {"SUPERVISOR", "col",          ~w[view edit]},
      {"SUPERVISOR", "collections_mi", ~w[view]},
      {"SUPERVISOR", "hcs",          ~w[view edit]},
      # "approve" added 2026-07-28 (Card Products UX Parity Phase 1c) — the
      # SUPERVISOR checker role for Debit's new 4-eyes Adjustments action,
      # same convention as "account"'s own approve permission.
      {"SUPERVISOR", "debit",        ~w[view edit approve]},
      # "approve" added 2026-07-28 (Card Products UX Parity Phase 2c) —
      # same as Debit's 4-eyes Adjustments checker permission.
      {"SUPERVISOR", "prepaid",      ~w[view edit approve]},

      # OPS — operational day-to-day, no approvals
      {"OPS", "logo",         ~w[view]},
      {"OPS", "block",        ~w[view]},
      {"OPS", "customer",     ~w[view edit]},
      {"OPS", "account",      ~w[view edit]},
      {"OPS", "exceptions",   ~w[view edit]},
      {"OPS", "auth_history", ~w[view]},
      {"OPS", "tram_inquiry", ~w[view]},
      {"OPS", "dps",          ~w[view create edit]},
      {"OPS", "cms_eod",      ~w[view edit]},
      {"OPS", "cms_resegmentation", ~w[view edit]},
      {"OPS", "col",          ~w[view edit]},
      {"OPS", "collections_mi", ~w[view]},
      {"OPS", "hcs",          ~w[view edit]},
      {"OPS", "debit",        ~w[view edit]},
      {"OPS", "prepaid",      ~w[view edit]},

      # CS_AGENT — customer service: lookups + contact-data edits
      {"CS_AGENT", "customer",     ~w[view edit]},
      {"CS_AGENT", "account",      ~w[view]},
      {"CS_AGENT", "auth_history", ~w[view]},
      {"CS_AGENT", "tram_inquiry", ~w[view]},
      {"CS_AGENT", "dps",          ~w[view create]},
      {"CS_AGENT", "col",          ~w[view]},

      # TELLER — lookups only
      {"TELLER", "customer", ~w[view]},
      {"TELLER", "account",  ~w[view]},

      # RISK — investigation surfaces + exception approvals
      {"RISK", "account",      ~w[view]},
      {"RISK", "exceptions",   ~w[view edit approve]},
      {"RISK", "auth_history", ~w[view]},
      {"RISK", "tram_inquiry", ~w[view]},
      {"RISK", "approvals",    ~w[view approve]},
      {"RISK", "dps",          ~w[view create edit approve]},
      {"RISK", "col",          ~w[view edit]},
      {"RISK", "collections_mi", ~w[view]},
      {"RISK", "hcs",          ~w[view edit]},
      {"RISK", "debit",        ~w[view edit]},
      {"RISK", "prepaid",      ~w[view edit]},

      # COMPLIANCE — read everything, change nothing
      {"COMPLIANCE", "system",       ~w[view]},
      {"COMPLIANCE", "organization", ~w[view]},
      {"COMPLIANCE", "logo",         ~w[view]},
      {"COMPLIANCE", "block",        ~w[view]},
      {"COMPLIANCE", "customer",     ~w[view]},
      {"COMPLIANCE", "account",      ~w[view]},
      {"COMPLIANCE", "exceptions",   ~w[view]},
      {"COMPLIANCE", "auth_history", ~w[view]},
      {"COMPLIANCE", "tram_inquiry", ~w[view]},
      {"COMPLIANCE", "audit_log",    ~w[view]},
      {"COMPLIANCE", "dps",          ~w[view]},
      {"COMPLIANCE", "cms_eod",      ~w[view]},
      {"COMPLIANCE", "cms_resegmentation", ~w[view]},
      {"COMPLIANCE", "col",          ~w[view]},
      {"COMPLIANCE", "collections_mi", ~w[view]},
      {"COMPLIANCE", "hcs",          ~w[view]},
      {"COMPLIANCE", "debit",        ~w[view]},
      {"COMPLIANCE", "prepaid",      ~w[view]},

      # SUPERVISOR also reviews the audit trail
      {"SUPERVISOR", "audit_log",    ~w[view]}

      # ADMIN — code short-circuit in Authz; "operators" module is ADMIN-only
      # precisely because no role rows grant it.
    ]
  end
end
