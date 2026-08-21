defmodule VmuCore.CMS.CoreBankingAdapter do
  @moduledoc """
  GL extract interface between the CMS ledger and the core banking system.

  ## Purpose (3J)

  After each EOD cycle, journal entries must be extracted and transmitted to the
  core banking system for settlement and general ledger reconciliation. This
  adapter:

  1. Queries all un-extracted entries for a given account and date.
  2. Groups entries into a standardised extract payload.
  3. Submits the payload to the configured core banking endpoint.
  4. Records the extraction against each entry.

  ## Source (GL Phase C3)

  Reads `journal_entries` through `GL.Extraction`, not `cms_ledger_entries`.
  This was the **last reader** on the legacy table, and the only one that needed
  something the new model lacked -- per-entry extraction state. `GL.Extraction`
  is that state, held beside the journal rather than stamped into it.

  ## This module had never run

  Every entry point raised `key :id not found`. `CMS.LedgerEntry`'s primary key
  is `entry_id` and the schema has no `id` field at all, yet `build_payload/3`
  and `mark_extracted/1` both referenced `e.id`. Found 2026-08-06 by calling
  `extract_all/1` during the C3 migration. Rewriting onto `journal_entries` --
  whose primary key *is* `id` -- resolves it, but the defect is worth recording:
  it is the third instance of the same slip here, after
  `HCS.ConsolidatedStatementGenerator` and `CMS.StatementGenerator`.

  ## Configuration

  The adapter mode is controlled by application config:

      config :vmu_core, :core_banking_adapter,
        mode: :stub   # :stub | :http | :file | :kafka

  - `:stub`  — Logs the extract, no external I/O (default; safe for dev/test)
  - `:http`  — POSTs a JSON payload to `:endpoint` URL
  - `:file`  — Appends to a CSV/ISO20022 flat file at `:output_path`
  - `:kafka` — Publishes to a Kafka topic via `:topic` config

  ## Idempotency

  Each entry carries a unique `idempotency_key` from its posting set, and
  `GL.Extraction` keys on `(journal_entry_id, destination)`. Re-running the
  extract for the same date marks nothing and re-sends nothing, so it is safe
  to replay after a failed transmission.

  ## GL account mapping

  Account codes go out through `GL.ExportMap`, so a bank's own chart can differ
  from the internal one without a second remap.

  The internal chart is `gl_accounts`, and it is authoritative. This moduledoc
  used to restate six codes inline, and after the Phase 4A remap four of them
  were wrong -- it had 2001 as "Interest Income" (it is Customer Credit
  Liability) and 2002 as "Fee Income" (it is the HCS parent payable). Restating
  a registry in prose is how those drift; read `GL.ChartOfAccounts` instead.
  """

  require Logger

  alias VmuCore.GL.{Extraction, ExportMap}
  alias VmuCore.Posting.Rules

  @type extract_result :: {:ok, %{count: integer(), total_amount: Decimal.t()}} | {:error, term()}

  @doc """
  Extract and submit all un-extracted GL entries for `account_id` on `eod_date`.

  Returns `{:ok, %{count: n, total_amount: d}}` on success.
  """
  @spec extract_for(binary(), Date.t()) :: extract_result()
  def extract_for(account_id, eod_date) do
    entries = Extraction.unextracted(eod_date, account_ref: account_id)

    if Enum.empty?(entries) do
      {:ok, %{count: 0, total_amount: Decimal.new(0)}}
    else
      payload = build_payload(account_id, eod_date, entries)

      case submit(payload) do
        :ok ->
          Extraction.mark!(entries, batch_ref: payload.batch_ref)
          total = Enum.reduce(entries, Decimal.new(0), fn e, acc ->
            Decimal.add(acc, e.amount || Decimal.new(0))
          end)
          Logger.info("[CoreBankingAdapter] Extracted #{length(entries)} entries account=#{account_id} date=#{eod_date} total=#{total}")
          {:ok, %{count: length(entries), total_amount: total}}

        {:error, reason} = err ->
          Logger.error("[CoreBankingAdapter] Submit failed account=#{account_id} date=#{eod_date}: #{inspect(reason)}")
          err
      end
    end
  end

  @doc """
  Extract all un-extracted GL entries across all accounts for `eod_date`.

  Designed to be called from `FlushGlJob` after the per-account EOD pipeline
  completes, or from a dedicated end-of-day reconciliation job.
  """
  @spec extract_all(Date.t()) :: {:ok, %{accounts: integer(), entries: integer()}} | {:error, term()}
  def extract_all(eod_date) do
    account_ids = Extraction.pending_account_refs(eod_date)

    {ok_count, entry_count} =
      Enum.reduce(account_ids, {0, 0}, fn acct_id, {accounts, entries} ->
        case extract_for(acct_id, eod_date) do
          {:ok, %{count: n}} -> {accounts + 1, entries + n}
          _                  -> {accounts, entries}
        end
      end)

    {:ok, %{accounts: ok_count, entries: entry_count}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_payload(account_id, eod_date, entries) do
    legacy_codes = legacy_code_lookup()

    %{
      source:      "CMS",
      extract_ts:  DateTime.utc_now() |> DateTime.to_iso8601(),
      account_id:  account_id,
      posting_date: Date.to_iso8601(eod_date),
      # Identifies this submission, so a failed transmission can be re-driven
      # as a unit rather than entry by entry.
      batch_ref:   "CBA-#{account_id}-#{Date.to_iso8601(eod_date)}",
      entries: Enum.map(entries, fn e ->
        # Account codes go out through VmuCore.GL.ExportMap (Phase 4A.1), so the
        # internal chart and a bank's own chart can diverge without a second
        # remap. Identity by default — with no mapping configured this payload
        # is byte-identical to what it was before the layer existed.
        %{
          ledger_entry_id:  e.id,
          # The legacy transaction code, not the engine's event type. The
          # external contract is stated in the old vocabulary, and
          # `posting_rules.legacy_transaction_code` maps back to it — so a
          # consumer still sees PURCHASE where the engine records WITHDRAWAL.
          transaction_code: Map.get(legacy_codes, {e.event_type, e.product}, e.event_type),
          event_type:       e.event_type,
          gl_account_dr:    ExportMap.translate(e.dr_gl_account),
          gl_account_cr:    ExportMap.translate(e.cr_gl_account),
          # Under double entry the two sides are equal by construction and the
          # posting tables keep the single value. Both fields are still emitted
          # so the payload shape is unchanged for whoever consumes it.
          dr_amount:        Decimal.to_string(e.amount || Decimal.new(0)),
          cr_amount:        Decimal.to_string(e.amount || Decimal.new(0)),
          posting_date:     Date.to_iso8601(e.posting_date),
          value_date:       Date.to_iso8601(e.transaction_date || eod_date),
          narrative:        e.narrative,
          idempotency_key:  e.idempotency_key
        }
      end)
    }
  end

  # Built once per payload rather than queried per entry.
  defp legacy_code_lookup do
    Rules.all(active: :all)
    |> Map.new(fn r -> {{r.event_type, r.product}, r.legacy_transaction_code} end)
  end

  defp submit(payload) do
    mode = Application.get_env(:vmu_core, :core_banking_adapter, [])
           |> Keyword.get(:mode, :stub)
    do_submit(mode, payload)
  end

  # ── Stub mode (default) — safe for dev/test/DR ──────────────────────────────
  defp do_submit(:stub, payload) do
    Logger.info("[CoreBankingAdapter:stub] Would transmit #{length(payload.entries)} entries " <>
                "account=#{payload.account_id} date=#{payload.posting_date}")
    :ok
  end

  # ── HTTP mode — POST to core banking REST endpoint ──────────────────────────
  defp do_submit(:http, payload) do
    cfg      = Application.get_env(:vmu_core, :core_banking_adapter, [])
    endpoint = Keyword.fetch!(cfg, :endpoint)
    headers  = [{"Content-Type", "application/json"}, {"Accept", "application/json"}]
    body     = Jason.encode!(payload)

    case :httpc.request(:post, {String.to_charlist(endpoint), headers, 'application/json', body}, [], []) do
      {:ok, {{_, 200, _}, _hdrs, _body}} -> :ok
      {:ok, {{_, status, _}, _hdrs, resp_body}} ->
        {:error, {:http_error, status, resp_body}}
      {:error, reason} ->
        {:error, {:http_failure, reason}}
    end
  end

  # ── File mode — append ISO20022-compatible CSV ───────────────────────────────
  defp do_submit(:file, payload) do
    cfg  = Application.get_env(:vmu_core, :core_banking_adapter, [])
    path = Keyword.get(cfg, :output_path, "/tmp/cms_gl_extract.csv")

    lines = Enum.map(payload.entries, fn e ->
      "#{e.ledger_entry_id},#{e.transaction_code},#{e.gl_account_dr}," <>
      "#{e.gl_account_cr},#{e.dr_amount},#{e.cr_amount}," <>
      "#{e.posting_date},#{e.value_date},\"#{e.narrative}\"\n"
    end)

    File.write(path, lines, [:append])
  end

end
