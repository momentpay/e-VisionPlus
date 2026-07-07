defmodule VmuCore.Repo.Migrations.CreateCmsTempLimits do
  @moduledoc """
  Sprint 4G: Temporary credit limit table.

  A temp limit overrides the account's `credit_limit` for a bounded period.
  On `expiry_date`, the EOD ReinstateLimitJob restores the `original_limit`.

  Only one active (status='ACTIVE') temp limit is allowed per account at a time.
  A new request supersedes the prior active record by setting its status to 'SUPERSEDED'.
  """

  use Ecto.Migration

  def change do
    create table(:cms_temp_limits, primary_key: false) do
      add :temp_limit_id,   :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :account_id,      :binary_id, null: false
      add :temp_limit,      :decimal, precision: 18, scale: 2, null: false
      add :original_limit,  :decimal, precision: 18, scale: 2, null: false
      add :expiry_date,     :date, null: false
      add :reason,          :string, size: 255
      add :status,          :string, size: 20, null: false, default: "ACTIVE"
      # ACTIVE | EXPIRED | REINSTATED | SUPERSEDED
      add :operator_id,     :string, size: 50, null: false
      add :supervisor_id,   :string, size: 50, null: false
      add :reinstated_at,   :naive_datetime   # set when EOD job restores original limit

      timestamps()
    end

    create index(:cms_temp_limits, [:account_id, :status],
      name: :cms_temp_limits_account_status_idx)

    create index(:cms_temp_limits, [:expiry_date, :status],
      name: :cms_temp_limits_expiry_idx,
      where: "status = 'ACTIVE'")
  end
end
