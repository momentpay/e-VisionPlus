defmodule VmuCore.Repo.Migrations.WidenLedgerTransactionCode do
  use Ecto.Migration

  # Latent bug found during TRAM-P5 smoke testing: cms_ledger_entries
  # .transaction_code was varchar(10), but LedgerEntry's own valid-codes list
  # includes "DISPUTE_CREDIT" (14 chars) — every DPS provisional-credit post
  # (DPS.Dispute.file/1) failed with string_data_right_truncation at runtime.
  # "ADJUSTMENT" (10) fit exactly, which is why TRAM-P4 postings worked.
  def change do
    alter table(:cms_ledger_entries) do
      modify :transaction_code, :string, size: 20, null: false,
        from: {:string, size: 10, null: false}
    end
  end
end
