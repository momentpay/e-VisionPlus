defmodule VmuCore.CMS.CoreBankingAdapter do
  @moduledoc """
  GL extract interface between the CMS ledger and the core banking system.

  ## Purpose (3J)

  After each EOD cycle, GL entries posted to `cms_ledger_entries` must be
  extracted and transmitted to the core banking system for settlement and
  general ledger reconciliation. This adapter:

  1. Queries all un-extracted entries for a given account and date.
  2. Groups entries into a standardised extract payload.
  3. Submits the payload to the configured core banking endpoint.
  4. Marks entries as extracted (`extracted_at` timestamp).

  ## Configuration

  The adapter mode is controlled by application config:

      config :vmu_core, :core_banking_adapter,
        mode: :stub   # :stub | :http | :file | :kafka

  - `:stub`  — Logs the extract, no external I/O (default; safe for dev/test)
  - `:http`  — POSTs a JSON payload to `:endpoint` URL
  - `:file`  — Appends to a CSV/ISO20022 flat file at `:output_path`
  - `:kafka` — Publishes to a Kafka topic via `:topic` config

  ## Idempotency

  Each GL entry carries a unique `idempotency_key` set by the posting function.
  The extract marks entries with `extracted_at`; re-running the extract for the
  same date will skip already-extracted rows. This makes the extract safe to
  replay on failure.

  ## GL account mapping

  Standard CMS double-entry accounts:
  | GL Code | Description                  |
  |---------|------------------------------|
  | 1001    | Card Receivables              |
  | 1003    | Unearned Revenue              |
  | 1004    | Fee Receivables               |
  | 2001    | Interest Income               |
  | 2002    | Fee Income                    |
  | 3001    | Adjustment / Suspense         |
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CMS.LedgerEntry}

  @type extract_result :: {:ok, %{count: integer(), total_amount: Decimal.t()}} | {:error, term()}

  @doc """
  Extract and submit all un-extracted GL entries for `account_id` on `eod_date`.

  Returns `{:ok, %{count: n, total_amount: d}}` on success.
  """
  @spec extract_for(binary(), Date.t()) :: extract_result()
  def extract_for(account_id, eod_date) do
    entries = fetch_unextracted(account_id, eod_date)

    if Enum.empty?(entries) do
      {:ok, %{count: 0, total_amount: Decimal.new(0)}}
    else
      payload = build_payload(account_id, eod_date, entries)

      case submit(payload) do
        :ok ->
          mark_extracted(entries)
          total = Enum.reduce(entries, Decimal.new(0), fn e, acc ->
            Decimal.add(acc, e.dr_amount || Decimal.new(0))
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
    account_ids =
      Repo.all(
        from e in LedgerEntry,
          where: e.posting_date == ^eod_date and is_nil(e.extracted_at),
          distinct: true,
          select: e.account_id
      )

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

  defp fetch_unextracted(account_id, eod_date) do
    Repo.all(
      from e in LedgerEntry,
        where: e.account_id   == ^account_id
          and  e.posting_date == ^eod_date
          and  is_nil(e.extracted_at),
        order_by: [asc: e.inserted_at]
    )
  end

  defp build_payload(account_id, eod_date, entries) do
    %{
      source:      "CMS",
      extract_ts:  DateTime.utc_now() |> DateTime.to_iso8601(),
      account_id:  account_id,
      posting_date: Date.to_iso8601(eod_date),
      entries: Enum.map(entries, fn e ->
        %{
          ledger_entry_id:  e.id,
          transaction_code: e.transaction_code,
          gl_account_dr:    e.gl_account_dr,
          gl_account_cr:    e.gl_account_cr,
          dr_amount:        Decimal.to_string(e.dr_amount || Decimal.new(0)),
          cr_amount:        Decimal.to_string(e.cr_amount || Decimal.new(0)),
          posting_date:     Date.to_iso8601(e.posting_date),
          value_date:       Date.to_iso8601(e.value_date || eod_date),
          narrative:        e.narrative,
          idempotency_key:  e.idempotency_key
        }
      end)
    }
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

  defp mark_extracted(entries) do
    ids        = Enum.map(entries, & &1.id)
    extracted_at = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.update_all(
      from(e in LedgerEntry, where: e.id in ^ids),
      set: [extracted_at: extracted_at]
    )
  end
end
