defmodule VmuCore.Repo.Migrations.CreateCmsTransactionAllocations do
  use Ecto.Migration

  def change do
    # FR-067 — the missing link this migration exists to close: a real
    # purchase/cash-advance transaction reaching TRAM's POSTED state never
    # actually incremented cms_accounts' BalanceBucket anywhere in this
    # codebase (confirmed live, 2026-07-24 — neither FAS.AuthConsumer, nor
    # TRAMS.EventStore, nor InternalGlPoster/VmuCoreGlAdapter touch
    # BalanceBucket for a purchase). This table is the transaction-level
    # detail RepaymentDistributor's bucket-level allocation was always
    # missing; VmuCore.CMS.PurchasePosting is what now creates a row here
    # (and the corresponding bucket increment) at the same real posting
    # moment (FAS.SettlementPostingAdapter.do_confirm/3).
    create table(:cms_transaction_allocations, primary_key: false) do
      add :allocation_id,       :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :account_id,          :uuid, null: false, references: :cms_accounts, type: :uuid
      add :trams_transaction_id, :uuid
      # Which BalanceBucket field this transaction contributes to —
      # retail_balance | cash_balance | bt_balance (matches
      # RepaymentDistributor's existing bucket vocabulary; deliberately not
      # its own enum table, same "fixed domain concept, not regional
      # policy" reasoning RepaymentDistributor's own hierarchy uses).
      add :bucket_field,        :string, size: 20, null: false
      add :original_amount,     :decimal, precision: 18, scale: 2, null: false
      add :allocated_amount,    :decimal, precision: 18, scale: 2, null: false, default: 0
      add :remaining_amount,    :decimal, precision: 18, scale: 2, null: false
      add :status,              :string, size: 20, null: false, default: "OUTSTANDING"
      # OUTSTANDING | PARTIALLY_PAID | PAID
      add :transaction_date,    :date, null: false
      # Excluded from normal payment allocation while true (DPS provisional
      # credit already covers it — see exclude_disputed_from_allocation).
      add :disputed,            :boolean, null: false, default: false
      add :idempotency_key,     :string, size: 100, null: false

      timestamps()
    end

    create unique_index(:cms_transaction_allocations, [:idempotency_key])
    create index(:cms_transaction_allocations, [:account_id, :bucket_field, :status])
    create index(:cms_transaction_allocations, [:trams_transaction_id])
  end
end
