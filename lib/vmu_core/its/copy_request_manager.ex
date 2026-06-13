defmodule VmuCore.ITS.CopyRequestManager do
  @moduledoc """
  Manages the lifecycle of copy/retrieval requests sent to card schemes.

  Integrates with DPS: when a copy request is fulfilled, the linked dispute
  advances from RETRIEVAL_REQUESTED to CHARGEBACK_FILED automatically.
  """

  alias VmuCore.ITS.CopyRequest
  alias VmuCore.DPS.Dispute
  alias VmuCore.Repo
  import Ecto.Query

  @mastercard_deadline_days 45
  @visa_deadline_days       30

  @doc """
  Raises a copy or retrieval request. Idempotent via idempotency_key.
  Can be triggered from DPS (dispute-driven) or OperatorPortal (inquiry).
  """
  def raise_request(attrs) do
    deadline = calculate_deadline(attrs[:network] || "MC", Date.utc_today())

    idempotency_key = "copy_#{attrs[:account_id]}_#{attrs[:transaction_date]}_#{attrs[:arn] || :rand.uniform(999999)}"

    %CopyRequest{}
    |> CopyRequest.changeset(Map.merge(attrs, %{
      status:          "PENDING",
      deadline_date:   deadline,
      idempotency_key: idempotency_key
    }))
    |> Repo.insert(on_conflict: :nothing, conflict_target: :idempotency_key)
    |> case do
      {:ok, %CopyRequest{id: nil}} -> {:error, :duplicate}
      result -> result
    end
  end

  @doc """
  Marks a copy request FULFILLED. Called from ITS2 batch when a positive
  response arrives from the scheme. Advances the linked DPS dispute if present.
  """
  def mark_fulfilled(request_id, response_attrs \\ %{}) do
    Repo.transaction(fn ->
      request = Repo.get!(CopyRequest, request_id)

      request
      |> CopyRequest.changeset(%{
        status:          "FULFILLED",
        fulfilled_at:    DateTime.utc_now(),
        response_reason: response_attrs[:reason],
        its2_batch_date: Date.utc_today()
      })
      |> Repo.update!()

      if request.dispute_id do
        advance_dispute_to_chargeback(request.dispute_id)
      end

      :ok
    end)
  end

  @doc """
  Expires all SENT copy requests past their deadline_date.
  Called daily from CopyRequestExpiryJob.
  """
  def expire_overdue do
    today = Date.utc_today()

    {count, _} =
      Repo.update_all(
        from(r in CopyRequest,
          where: r.status == "SENT" and r.deadline_date < ^today
        ),
        set: [status: "EXPIRED", updated_at: DateTime.utc_now()]
      )

    {:ok, %{expired: count}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp calculate_deadline("MASTERCARD", from_date), do: Date.add(from_date, @mastercard_deadline_days)
  defp calculate_deadline("MC", from_date),          do: Date.add(from_date, @mastercard_deadline_days)
  defp calculate_deadline("VISA", from_date),        do: Date.add(from_date, @visa_deadline_days)
  defp calculate_deadline("VI", from_date),          do: Date.add(from_date, @visa_deadline_days)
  defp calculate_deadline(_, from_date),             do: Date.add(from_date, 30)

  defp advance_dispute_to_chargeback(dispute_id) do
    dispute = Repo.get!(Dispute, dispute_id)

    if dispute.status == "RETRIEVAL_REQUESTED" do
      dispute
      |> Dispute.changeset(%{status: "CHARGEBACK_FILED"})
      |> Repo.update!()
    end
  end
end
