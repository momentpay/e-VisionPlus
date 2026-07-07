defmodule VmuCore.TRAMS.IpmPipeline do
  @moduledoc """
  Broadway pipeline for high-volume Mastercard IPM file processing (G7).

  Architecture:
    - 1 producer   : reads 1644-byte records from the IPM file path
    - 10 processors: parse bitmap, extract DEs, insert clearing records
    - 1 batcher     : accumulates matched records for bulk GL posting

  Usage:
    VmuCore.TRAMS.IpmPipeline.process_file("/path/to/mc_ipm_20260614.bin")

  Cron (Oban IpmPipelineJob triggers this at 21:30 each batch cycle day):
    {:ok, _} = DynamicSupervisor.start_child(
      VmuCore.PipelineSupervisor,
      {VmuCore.TRAMS.IpmPipeline, file_path: path}
    )
  """

  use Broadway

  require Logger
  alias VmuCore.TRAMS.{ClearingRecord, MastercardIpm}
  alias VmuCore.{Repo, CMS.Account}
  import Ecto.Query

  @record_length 1644
  @presentment_mti "1240"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    file_path = Keyword.fetch!(opts, :file_path)

    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {VmuCore.TRAMS.IpmFileProducer, [file_path: file_path, record_length: @record_length]},
        concurrency: 1
      ],
      processors: [
        default: [concurrency: 10]
      ],
      batchers: [
        gl: [concurrency: 1, batch_size: 50, batch_timeout: 5_000]
      ]
    )
  end

  # ---------------------------------------------------------------------------
  # Broadway callbacks
  # ---------------------------------------------------------------------------

  @impl Broadway
  def handle_message(_processor, %Broadway.Message{data: record_binary} = message, _context) do
    case process_record(record_binary) do
      {:ok, attrs} ->
        Broadway.Message.put_data(message, attrs)
        |> Broadway.Message.put_batcher(:gl)

      {:skip, _reason} ->
        Broadway.Message.failed(message, :not_presentment)

      {:error, reason} ->
        Logger.warning("[IpmPipeline] Record failed: #{inspect(reason)}")
        Broadway.Message.failed(message, reason)
    end
  end

  @impl Broadway
  def handle_batch(:gl, messages, _batch_info, _context) do
    attrs_list =
      messages
      |> Enum.map(& &1.data)
      |> Enum.reject(&is_nil/1)

    Repo.transaction(fn ->
      Enum.each(attrs_list, fn attrs ->
        case Repo.insert(ClearingRecord.changeset(%ClearingRecord{}, attrs),
                         on_conflict: :nothing,
                         conflict_target: :idempotency_key) do
          {:ok, rec} when not is_nil(rec.account_id) ->
            VmuCore.ITS.FeeClaimProcessor.create_claim(rec)
          _ ->
            :ok
        end
      end)
    end)

    # TRAM matching (TRAM-P3 3C) — after the batch commits, so the matching
    # engine's own transactions don't nest inside the insert transaction.
    # Re-fetch by idempotency_key: on_conflict :nothing returns a struct even
    # when the row already existed, so the fetch resolves the real DB row.
    Enum.each(attrs_list, &match_inserted_record/1)

    messages
  end

  defp match_inserted_record(%{idempotency_key: key}) when is_binary(key) do
    case Repo.get_by(ClearingRecord, idempotency_key: key) do
      %ClearingRecord{match_status: "UNMATCHED"} = rec ->
        VmuCore.TRAMS.MatchingEngine.match_clearing_record(rec)

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.error("[IpmPipeline] TRAM matching failed for #{key}: #{Exception.message(e)}")
  end

  defp match_inserted_record(_), do: :ok

  @impl Broadway
  def handle_failed(messages, _context) do
    Enum.each(messages, fn msg ->
      Logger.error("[IpmPipeline] Failed message: #{inspect(msg.status)}")
    end)
    messages
  end

  # ---------------------------------------------------------------------------
  # Record processing
  # ---------------------------------------------------------------------------

  defp process_record(binary) when byte_size(binary) == @record_length do
    case binary do
      <<mti::binary-size(4), _rest::binary>> when mti == @presentment_mti ->
        case MastercardIpm.parse_record(binary) do
          {:ok, attrs} ->
            account_id = resolve_account(attrs.pan_token)

            idempotency_key =
              :crypto.hash(:sha256, "mc_#{attrs.rrn}_#{attrs.transaction_date}_#{attrs.amount}")
              |> Base.encode16(case: :lower)

            {:ok, Map.merge(attrs, %{account_id: account_id, idempotency_key: idempotency_key})}

          error -> error
        end

      _ ->
        {:skip, :not_presentment}
    end
  end
  defp process_record(_), do: {:error, :wrong_record_length}

  defp resolve_account(pan_token) do
    Repo.one(from a in Account, where: a.pan_token == ^pan_token, select: a.account_id)
  end
end

defmodule VmuCore.TRAMS.IpmFileProducer do
  @moduledoc """
  Broadway GenStage producer that reads 1644-byte records from an IPM file.
  Emits one Broadway.Message per record.
  """

  use GenStage
  require Logger

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    file_path     = Keyword.fetch!(opts, :file_path)
    record_length = Keyword.get(opts, :record_length, 1644)
    {:producer, %{file_path: file_path, record_length: record_length, records: :not_loaded}}
  end

  @impl true
  def handle_demand(demand, %{records: :not_loaded} = state) do
    records = load_records(state.file_path, state.record_length)
    Logger.info("[IpmFileProducer] Loaded #{length(records)} records from #{state.file_path}")
    handle_demand(demand, %{state | records: records})
  end

  @impl true
  def handle_demand(demand, %{records: records} = state) do
    {to_emit, remaining} = Enum.split(records, demand)

    messages =
      Enum.map(to_emit, fn record ->
        %Broadway.Message{
          data:         record,
          acknowledger: Broadway.NoopAcknowledger.init()
        }
      end)

    {:noreply, messages, %{state | records: remaining}}
  end

  defp load_records(file_path, record_length) do
    case File.read(file_path) do
      {:ok, binary} ->
        count = div(byte_size(binary), record_length)
        for i <- 0..(count - 1) do
          binary_part(binary, i * record_length, record_length)
        end

      {:error, reason} ->
        Logger.error("[IpmFileProducer] Cannot read #{file_path}: #{inspect(reason)}")
        []
    end
  end
end

defmodule VmuCore.TRAMS.Oban.IpmPipelineJob do
  @moduledoc """
  Oban job that starts the Broadway IpmPipeline for a given IPM file.
  Scheduled at 21:30 each batch day by the cron scheduler.
  """

  use Oban.Worker, queue: :clearing, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"file_path" => file_path}}) do
    {:ok, _pid} =
      DynamicSupervisor.start_child(
        VmuCore.PipelineSupervisor,
        {VmuCore.TRAMS.IpmPipeline, file_path: file_path}
      )
    :ok
  end
end
