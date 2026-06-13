defmodule VmuCore.Repo.Migrations.CreateParameterTables do
  use Ecto.Migration

  def change do
    create table(:sys_parameters, primary_key: false) do
      add :sys_id, :string, size: 4, primary_key: true
      add :description, :string, null: false
      add :base_currency, :string, size: 3, null: false, default: "AED"

      timestamps()
    end

    create table(:bank_parameters, primary_key: false) do
      add :bank_id, :string, size: 4, primary_key: true
      add :sys_id, references(:sys_parameters, column: :sys_id, type: :string, on_delete: :delete_all), primary_key: true
      add :description, :string, null: false
      add :country_code, :string, size: 3, null: false, default: "ARE"

      timestamps()
    end

    create table(:logo_parameters, primary_key: false) do
      add :logo_id, :string, size: 4, primary_key: true
      add :sys_id, :string, size: 4, primary_key: true
      add :bank_id, :string, size: 4, primary_key: true
      add :bin_prefix, :string, size: 6, null: false
      add :description, :string, null: false

      timestamps()
    end

    # Composite foreign key constraint for logo referencing bank
    execute """
    ALTER TABLE logo_parameters
    ADD CONSTRAINT fk_logo_to_bank
    FOREIGN KEY (sys_id, bank_id)
    REFERENCES bank_parameters(sys_id, bank_id)
    ON DELETE CASCADE;
    """

    create table(:block_parameters, primary_key: false) do
      add :block_id, :string, size: 4, primary_key: true
      add :sys_id, :string, size: 4, primary_key: true
      add :bank_id, :string, size: 4, primary_key: true
      add :logo_id, :string, size: 4, primary_key: true
      add :apr_percentage, :decimal, precision: 5, scale: 2, null: false, default: 24.0
      add :cash_advance_fee_percent, :decimal, precision: 5, scale: 2, null: false, default: 3.0
      add :credit_limit_default, :decimal, precision: 15, scale: 4, null: false, default: 5000.0

      timestamps()
    end

    # Composite foreign key constraint for block referencing logo
    execute """
    ALTER TABLE block_parameters
    ADD CONSTRAINT fk_block_to_logo
    FOREIGN KEY (sys_id, bank_id, logo_id)
    REFERENCES logo_parameters(sys_id, bank_id, logo_id)
    ON DELETE CASCADE;
    """
  end
end
