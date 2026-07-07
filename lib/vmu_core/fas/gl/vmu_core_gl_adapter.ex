defmodule VmuCore.FAS.GL.VmuCoreGlAdapter do
  @moduledoc """
  `WalletGl.GlAdapter` implementation that writes card GL entries to
  vmu_core's own `cms_ledger_entries` table (FAS-P5 5C).

  This adapter is the integration point between the WalletGl behaviour contract
  and vmu_core's internal double-entry ledger. It is called directly by
  `VmuCore.FAS.SettlementPostingAdapter` — bypassing `WalletGl.GlPostingStore`
  (which requires the wallet_database infrastructure) in favour of vmu_core's
  own `VmuCore.Repo`.

  ## ADR-003: GL Integration Mechanism

  Decision: direct call to VmuCoreGlAdapter (not via WalletGl.create_posting/5).
  Rationale: `WalletGl.GlPostingStore` is ETS-backed and also writes through to
  `wallet_database`, which is not started in vmu_core's supervision tree.
  Wiring through the full WalletGl pipeline is deferred until vmu_core and
  wallet-app are co-deployed in the same OTP release (VisionPlus milestone 2).

  ## `account_id` convention

  `GlPostingRecord` has no `account_id` field. Callers must pass the
  account_id as `correlation_id` in `GlPostingRecord.new/4`'s opts:

      {:ok, record} = GlPostingRecord.new(key, date, entries, "vmu_core_gl",
                        correlation_id: account_id)
      VmuCoreGlAdapter.post_entry(record, nil)

  ## Entry format

  Each `GlPostingRecord.entries` list must contain exactly two entries:
  one with `debit_amount` set (DR leg) and one with `credit_amount` set (CR leg).
  Amounts are `%WalletSharedKernel.Money{amount: integer_minor_units, currency: ...}`.
  The adapter converts minor-unit integers to two-decimal `Decimal` values.
  """

  use WalletGl.GlAdapter
  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.CMS.LedgerEntry
  alias VmuCore.FAS.GL.CardAccountCodes
  alias WalletGl.GlPostingRecord

  # ---------------------------------------------------------------------------
  # WalletGl.GlAdapter callbacks
  # ---------------------------------------------------------------------------

  @impl WalletGl.GlAdapter
  def create_batch(batch_reference, _posting_date, _description) do
    # vmu_core doesn't use external GL batches — return a synthetic batch ID
    {:ok, "vmu_batch_#{batch_reference}"}
  end

  @impl WalletGl.GlAdapter
  def post_entry(%GlPostingRecord{} = record, _batch_id) do
    key = record.journal_reference
    currency = infer_currency(record.entries)

    with {:ok, dr_entry} <- find_leg(record.entries, :dr),
         {:ok, cr_entry} <- find_leg(record.entries, :cr),
         amount           = money_to_decimal(dr_entry.debit_amount),
         account_id       = record.correlation_id do
      attrs = %{
        account_id:       account_id,
        idempotency_key:  key,
        transaction_code: infer_transaction_code(dr_entry.account_code, cr_entry.account_code),
        dr_amount:        amount,
        cr_amount:        amount,
        gl_account_dr:    dr_entry.account_code,
        gl_account_cr:    cr_entry.account_code,
        currency:         currency,
        posting_date:     record.posting_date,
        value_date:       record.posting_date,
        narrative:        dr_entry.description,
        source_ref:       to_string(record.correlation_id)
      }

      case Repo.insert(LedgerEntry.changeset(%LedgerEntry{}, attrs),
                       on_conflict: :nothing,
                       conflict_target: :idempotency_key) do
        {:ok, _entry}    -> {:ok, key}
        {:error, cs}     ->
          Logger.error("[VmuCoreGlAdapter] post_entry failed #{key}: #{inspect(cs.errors)}")
          {:error, :posting_failed, inspect(cs.errors)}
      end
    else
      {:error, reason} ->
        {:error, :invalid_entries, to_string(reason)}
    end
  end

  @impl WalletGl.GlAdapter
  def commit_batch(batch_id) do
    # Noop — entries are committed immediately on post_entry
    {:ok, batch_id}
  end

  @impl WalletGl.GlAdapter
  def get_posting_status(transaction_id) do
    exists = Repo.exists?(
      from e in LedgerEntry, where: e.idempotency_key == ^transaction_id
    )
    {:ok, if(exists, do: :posted, else: :pending)}
  end

  @impl WalletGl.GlAdapter
  def cancel_posting(_transaction_id) do
    # vmu_core ledger entries are permanent — use REVERSAL transaction_code instead
    {:error, :cancellation_not_supported}
  end

  @impl WalletGl.GlAdapter
  def validate_account_codes(codes) when is_list(codes) do
    invalid = Enum.reject(codes, &CardAccountCodes.valid?/1)

    if invalid == [],
      do: {:ok, codes},
      else: {:error, invalid}
  end

  @impl WalletGl.GlAdapter
  def get_reconciliation_data(from_date, to_date, account_codes) do
    base =
      from e in LedgerEntry,
        where: e.posting_date >= ^from_date and e.posting_date <= ^to_date

    query =
      if account_codes do
        where(base, [e], e.gl_account_dr in ^account_codes or e.gl_account_cr in ^account_codes)
      else
        base
      end

    entries = Repo.all(query)

    # Aggregate debit and credit totals per account code
    summary =
      Enum.reduce(entries, %{}, fn e, acc ->
        acc
        |> Map.update(e.gl_account_dr, %{dr: e.dr_amount, cr: Decimal.new(0)},
             fn m -> %{m | dr: Decimal.add(m.dr, e.dr_amount)} end)
        |> Map.update(e.gl_account_cr, %{dr: Decimal.new(0), cr: e.cr_amount},
             fn m -> %{m | cr: Decimal.add(m.cr, e.cr_amount)} end)
      end)

    {:ok, %{from_date: from_date, to_date: to_date, account_totals: summary,
             entry_count: length(entries)}}
  end

  @impl WalletGl.GlAdapter
  def health_check do
    Repo.query("SELECT 1")
    :ok
  rescue
    _ -> {:error, :database_unavailable}
  end

  # Optional callback overrides

  @impl WalletGl.GlAdapter
  def map_account_code(code), do: code

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp find_leg(entries, :dr) do
    case Enum.find(entries, &(&1[:debit_amount] != nil)) do
      nil   -> {:error, :missing_dr_entry}
      entry -> {:ok, entry}
    end
  end

  defp find_leg(entries, :cr) do
    case Enum.find(entries, &(&1[:credit_amount] != nil)) do
      nil   -> {:error, :missing_cr_entry}
      entry -> {:ok, entry}
    end
  end

  defp money_to_decimal(%{amount: minor_units}) when is_integer(minor_units) do
    Decimal.div(Decimal.new(minor_units), Decimal.new(100))
  end

  defp infer_currency(entries) do
    entries
    |> Enum.flat_map(fn e -> [e[:debit_amount], e[:credit_amount]] end)
    |> Enum.reject(&is_nil/1)
    |> List.first()
    |> case do
      nil   -> "AED"
      money -> money.currency
    end
  end

  # Reverse-lookup transaction_code from the DR/CR account pair.
  # Falls back to "PURCHASE" for unrecognised pairs.
  defp infer_transaction_code(dr_code, cr_code) do
    ~w[PURCHASE CASH_ADV FEE INTEREST REVERSAL DISPUTE_CREDIT]
    |> Enum.find("PURCHASE", fn code ->
      CardAccountCodes.journal_pair(code) == {dr_code, cr_code}
    end)
  end
end
