defmodule VmuCore.Repo.Migrations.CreatePlanSegments do
  @moduledoc """
  P1-B: Create plan_segments table.

  A PLAN is a sub-product within a LOGO. Each LOGO can have multiple plans:
    - RETAIL   — standard purchase plan (grace period eligible)
    - CASH     — cash advance plan (no grace period, higher APR)
    - EMI      — equal monthly instalment plan (fixed APR, fixed tenor)
    - BALANCE_TRANSFER — balance transfer plan (promotional APR)

  Plans define their own APR, payment priority order, and statement display order.
  Account transactions will be assigned to a plan_id, enabling per-plan billing
  and per-plan payment allocation.
  """

  use Ecto.Migration

  def change do
    create table(:plan_segments, primary_key: false) do
      add :plan_id,          :string, primary_key: true, size: 8
      add :logo_id,          :string, null: false, size: 4
      add :sys_id,           :string, null: false, size: 4
      add :bank_id,          :string, null: false, size: 4

      # Plan type — drives billing rules
      # RETAIL | CASH | EMI | BALANCE_TRANSFER
      add :plan_type,        :string, null: false, size: 20

      # Interest rate for this plan (overrides logo-level APR)
      add :apr,              :decimal, precision: 7, scale: 4, null: false, default: 0

      # Promotional APR (0% for introductory offers); nil means use :apr
      add :promo_apr,        :decimal, precision: 7, scale: 4

      # Date when promo APR expires and reverts to :apr
      add :promo_expiry_date, :date

      # Grace period eligibility
      # Only RETAIL plans are eligible; CASH and EMI are always charged
      add :grace_eligible,   :boolean, null: false, default: false

      # Minimum payment percent for this plan (overrides logo-level)
      add :min_payment_pct,  :decimal, precision: 7, scale: 4

      # Payment allocation priority (lower = paid first per VisionPlus hierarchy)
      # Standard VisionPlus order: 1=fees, 2=interest, 3=cash, 4=retail, 5=EMI
      add :payment_priority, :integer, null: false, default: 4

      # Order in which plan appears on statement (display only)
      add :statement_order,  :integer, null: false, default: 1

      # EMI-specific: fixed instalment tenor in months (nil for non-EMI plans)
      add :emi_tenor_months, :integer

      # Whether this plan is currently active and can accept new transactions
      add :active,           :boolean, null: false, default: true

      add :description,      :string

      timestamps()
    end

    # Each logo has a unique plan_id
    create unique_index(:plan_segments, [:plan_id])

    # Efficiently list all plans for a logo
    create index(:plan_segments, [:sys_id, :bank_id, :logo_id, :plan_type],
             name: :plan_segments_logo_type_idx)

    # FK constraints — reference the logo_parameters composite PK
    # NOTE: FK to logo_parameters requires (logo_id, sys_id, bank_id) match
    create index(:plan_segments, [:logo_id, :sys_id, :bank_id],
             name: :plan_segments_logo_fk_idx)
  end
end
