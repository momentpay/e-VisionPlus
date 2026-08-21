defmodule VmuCore.Repo.Migrations.RemapHistoricalLedgerAccounts do
  @moduledoc """
  Phase 4A.4 — migrate existing `cms_ledger_entries` rows onto the reconciled
  chart of accounts.

  ## Approach

  Rows are matched on the **stored account pair plus transaction_code**, not on
  what a posting function would emit today. Some rows were written directly as
  seed data rather than through `InternalGlPoster`, so their pairs do not
  always correspond to any function — matching on the code would miss them.

  The full pre-image is copied to `cms_ledger_entries_premap_4a` before
  anything is updated. That table is the rollback path and the audit trail;
  `down/0` restores from it.

  ## Deliberately not migrated

  Two pairs are genuinely ambiguous and are **left untouched and reported**
  rather than guessed at:

    * `ADJUSTMENT 5001/1001` — 5001 was the debit-deposit liability under the
      old poster, but a debit purchase posted 5001/1006, not 5001/1001. What
      this row meant is not recoverable from the data.
    * `PAYMENT 2001/1001` — `post_payment` emits 3001/1001; 2001/1001 is
      `CardAccountCodes`' REVERSAL / DISPUTE_CREDIT pair. Which one was
      intended is not determinable.

  Both remain valid account codes after the remap, so nothing dangles. They
  are listed by `mix run priv/repo/report_ledger_remap.exs` for a human to
  resolve.
  """
  use Ecto.Migration

  # {transaction_code, old_dr, old_cr} => {new_dr, new_cr}
  @remaps [
    # DPS provisional credit: Disputed Receivable moved 3001 -> 3003, since
    # 3001 is Payment/Adjustment Clearing in the reconciled chart.
    {"DISPUTE_CREDIT", "3001", "1001", "3003", "1001"},
    {"DISPUTE_REVERSAL", "1001", "3001", "1001", "3003"},
    {"DISPUTE_RECOVERY", "3002", "3001", "3004", "3003"},

    # Stored value: cash clearing 1006 -> 3005, liabilities out of the 5xxx
    # expense range into 2xxx.
    {"DEPOSIT",  "1006", "5001", "3005", "2004"},
    {"PURCHASE", "5001", "1006", "2004", "3005"},
    {"DEPOSIT",  "1006", "5002", "3005", "2005"},
    {"PURCHASE", "5002", "1006", "2005", "3005"},
    {"DEPOSIT",  "1006", "5003", "3005", "2006"},
    {"PURCHASE", "5003", "1006", "2006", "3005"},
    {"ADJUSTMENT", "1006", "5001", "3005", "2004"},
    {"ADJUSTMENT", "5001", "1006", "2004", "3005"},
    {"ADJUSTMENT", "1006", "5002", "3005", "2005"},
    {"ADJUSTMENT", "5002", "1006", "2005", "3005"},

    # Interest income out of the liability account.
    {"INTEREST", "1003", "2001", "1003", "4002"},
    # Fee income out of the HCS payable account.
    {"FEE", "1004", "2002", "1004", "4001"}
  ]

  def up do
    execute """
    CREATE TABLE cms_ledger_entries_premap_4a AS
    SELECT entry_id, transaction_code, gl_account_dr, gl_account_cr,
           posting_date, dr_amount, cr_amount, now() AS captured_at
    FROM cms_ledger_entries
    """

    execute "CREATE INDEX ON cms_ledger_entries_premap_4a (entry_id)"

    Enum.each(@remaps, fn {code, old_dr, old_cr, new_dr, new_cr} ->
      execute """
      UPDATE cms_ledger_entries
         SET gl_account_dr = '#{new_dr}', gl_account_cr = '#{new_cr}'
       WHERE transaction_code = '#{code}'
         AND gl_account_dr = '#{old_dr}'
         AND gl_account_cr = '#{old_cr}'
      """
    end)
  end

  def down do
    execute """
    UPDATE cms_ledger_entries e
       SET gl_account_dr = p.gl_account_dr,
           gl_account_cr = p.gl_account_cr
      FROM cms_ledger_entries_premap_4a p
     WHERE p.entry_id = e.entry_id
    """

    execute "DROP TABLE cms_ledger_entries_premap_4a"
  end
end
