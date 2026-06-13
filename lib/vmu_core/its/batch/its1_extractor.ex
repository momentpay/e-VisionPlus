defmodule VmuCore.ITS.Batch.Its1Extractor do
  @moduledoc """
  ITS1 batch step — extracts pending copy requests and CHARGEBACK_FILED disputes
  and routes them to TRAMS for card scheme network submission.

  In VisionPlus batch cycle this runs at 21:00, before TRAMS clearing.
  """

  require Logger
  alias VmuCore.ITS.{CopyRequest, CopyRequestManager}
  alias VmuCore.DPS.Dispute
  alias VmuCore.Repo
  import Ecto.Query

  @doc """
  Run ITS1 extraction for batch_date.
  Returns %{copy_requests_sent: n, chargebacks_submitted: n}.
  """
  def run(batch_date) do
    cr_result  = extract_copy_requests(batch_date)
    cb_result  = extract_chargebacks(batch_date)

    Logger.info("[ITS1] batch=#{batch_date} copy_requests=#{cr_result.sent} chargebacks=#{cb_result.submitted}")

    {:ok, %{
      copy_requests_sent:     cr_result.sent,
      chargebacks_submitted:  cb_result.submitted
    }}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp extract_copy_requests(batch_date) do
    pending =
      from(r in CopyRequest,
        where: r.status == "PENDING",
        preload: []
      )
      |> Repo.all()

    Enum.each(pending, fn request ->
      submit_to_trams(request)

      Repo.update_all(
        from(r in CopyRequest, where: r.id == ^request.id),
        set: [
          status:          "SENT",
          sent_at:         DateTime.utc_now(),
          its1_batch_date: batch_date,
          updated_at:      DateTime.utc_now()
        ]
      )
    end)

    %{sent: length(pending)}
  end

  defp extract_chargebacks(batch_date) do
    chargeback_disputes =
      from(d in Dispute,
        where: d.status == "CHARGEBACK_FILED"
          and is_nil(field(d, :submitted_at))
      )
      |> Repo.all()

    Enum.each(chargeback_disputes, fn dispute ->
      CopyRequestManager.raise_request(%{
        dispute_id:         dispute.dispute_id,
        account_id:         dispute.account_id,
        card_number_token:  Map.get(dispute, :card_number_token, ""),
        transaction_date:   dispute.transaction_date,
        transaction_amount: dispute.dispute_amount,
        network:            dispute.network || "MASTERCARD",
        arn:                Map.get(dispute, :arn),
        request_type:       "RETRIEVAL_REQUEST",
        request_reason:     "CHARGEBACK"
      })

      Repo.update_all(
        from(d in Dispute, where: d.dispute_id == ^dispute.dispute_id),
        set: [submitted_at: DateTime.utc_now()]
      )
    end)

    %{submitted: length(chargeback_disputes)}
  end

  defp submit_to_trams(request) do
    %{
      request_id: request.id,
      network:    request.network,
      arn:        request.arn,
      type:       request.request_type
    }
    |> VmuCore.TRAMS.Oban.SchemeSubmissionJob.new()
    |> Oban.insert()
  end
end
