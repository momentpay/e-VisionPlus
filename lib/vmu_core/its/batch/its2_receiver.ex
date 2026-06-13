defmodule VmuCore.ITS.Batch.Its2Receiver do
  @moduledoc """
  ITS2 batch step — processes incoming scheme responses from TRAMS.

  Handles:
    - COPY_RESPONSE: fulfills or declines copy requests, advances linked DPS disputes
    - FAR: ingests Financial Adjustment Records, auto-accepts those below threshold
    - Unknown record types are skipped

  In VisionPlus batch cycle this runs at 02:00, after TRAMS clearing (Phase 4).
  """

  require Logger
  alias VmuCore.ITS.{CopyRequest, CopyRequestManager, FinancialAdjustmentProcessor}
  alias VmuCore.Repo
  import Ecto.Query

  @doc """
  Process all incoming scheme response records for batch_date.

  incoming_records: list of maps with :record_type and record-specific fields.
  Returns summary counts.
  """
  def run(batch_date, incoming_records) do
    results = Enum.map(incoming_records, &process_record(&1, batch_date))

    summary = %{
      fulfilled:   Enum.count(results, &match?({:ok, :fulfilled}, &1)),
      declined:    Enum.count(results, &match?({:ok, :declined}, &1)),
      far_applied: Enum.count(results, &match?({:ok, :far}, &1)),
      skipped:     Enum.count(results, &match?({:ok, :skipped}, &1)),
      errors:      Enum.count(results, &match?({:error, _}, &1))
    }

    Logger.info("[ITS2] batch=#{batch_date} #{inspect(summary)}")
    {:ok, summary}
  end

  # ---------------------------------------------------------------------------
  # Private — record type handlers
  # ---------------------------------------------------------------------------

  defp process_record(%{record_type: "COPY_RESPONSE", request_id: id} = record, _batch_date) do
    case record[:response_code] do
      "00" ->
        case CopyRequestManager.mark_fulfilled(id, %{reason: record[:reason]}) do
          {:ok, _} -> {:ok, :fulfilled}
          err      -> err
        end

      code ->
        mark_declined(id, code)
        {:ok, :declined}
    end
  end

  defp process_record(%{record_type: "FAR"} = record, _batch_date) do
    case FinancialAdjustmentProcessor.ingest_far(%{
      network:            record[:network],
      adjustment_type:    record[:adjustment_type],
      reference_no:       record[:reference_no],
      adjustment_amount:  record[:amount],
      reason_code:        record[:reason_code],
      reason_description: record[:reason_description],
      original_txn_date:  record[:original_txn_date]
    }) do
      {:ok, far} ->
        if FinancialAdjustmentProcessor.auto_acceptable?(far) do
          case FinancialAdjustmentProcessor.accept(far.id) do
            {:ok, _} -> {:ok, :far}
            err      -> err
          end
        else
          Logger.info("[ITS2] FAR #{far.reference_no} queued for manual review (amount above threshold)")
          {:ok, :far}
        end

      {:error, :duplicate} ->
        {:ok, :skipped}

      err ->
        err
    end
  end

  defp process_record(_unknown, _batch_date), do: {:ok, :skipped}

  defp mark_declined(request_id, reason_code) do
    Repo.update_all(
      from(r in CopyRequest, where: r.id == ^request_id),
      set: [
        status:          "DECLINED",
        response_reason: reason_code,
        its2_batch_date: Date.utc_today(),
        updated_at:      DateTime.utc_now()
      ]
    )
  end
end
