defmodule VmuCore.Shared.ModuleConfigEntry do
  @moduledoc """
  One (scope, module, config_key) → value row (Module Configuration Framework, 2026-07-08).

  Complementary to `VmuCore.Shared.ParameterEngine`: that engine owns the fixed-column
  SYS/BANK/LOGO/BLOCK cascade feeding the authorization hot path (APR, fees, limits).
  This schema backs a generic, JSON-valued, EAV-style store for every other
  module-level operational/integration/policy setting — see
  `docs/shared/Module_Configuration_Framework.md`.

  `bank_id`/`logo_id` use `""` (not `nil`) as the "not applicable at this scope"
  sentinel so the composite unique index behaves predictably under Postgres NULL
  semantics.

  `value` is stored as `%{"v" => <config value>}` — Ecto's `:map` type only casts
  actual maps, so scalars/lists are wrapped in a one-key envelope. Always write/read
  through `VmuCore.Shared.ModuleConfigWriter`/`ModuleConfigEngine`, which handle the
  wrap/unwrap; never read `value["v"]` directly outside those two modules.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @scope_types ~w[system bank logo]

  schema "shared_module_configs" do
    field :scope_type, :string
    field :sys_id,     :string
    field :bank_id,    :string, default: ""
    field :logo_id,    :string, default: ""
    field :module,     :string
    field :config_key, :string
    field :value,      :map
    field :updated_by, :string

    timestamps()
  end

  def scope_types, do: @scope_types

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:scope_type, :sys_id, :bank_id, :logo_id, :module, :config_key, :value, :updated_by])
    |> validate_required([:scope_type, :sys_id, :module, :config_key, :value])
    |> validate_inclusion(:scope_type, @scope_types)
    |> unique_constraint([:scope_type, :sys_id, :bank_id, :logo_id, :module, :config_key],
      name: :shared_module_configs_scope_key_idx)
  end
end
