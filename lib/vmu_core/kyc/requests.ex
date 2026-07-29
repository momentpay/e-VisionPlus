defmodule VmuCore.Kyc.Requests do
  @moduledoc """
  Context for `VmuCore.Kyc.Request` — submit/review/approve/reject
  (`docs/kyc/KYC_Implementation_Tracker.md` §7 KYC-P2). Approve/reject both
  fire `VmuCore.Kyc.StatusSync` — the real integration point that keeps the
  five pre-existing per-product `kyc_status` flags accurate.
  """

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.Kyc.{Request, Method, StatusSync, Journey}

  @doc "List requests, optionally filtered by product_type/status/customer_id."
  @spec list(map()) :: [Request.t()]
  def list(filters \\ %{}) do
    Request
    |> maybe_filter(:product_type, Map.get(filters, "product_type"))
    |> maybe_filter(:status, Map.get(filters, "status"))
    |> maybe_filter(:customer_id, Map.get(filters, "customer_id"))
    |> order_by([r], desc: r.inserted_at)
    |> Repo.all()
  end

  @spec get(binary()) :: Request.t() | nil
  def get(request_id), do: Repo.get(Request, request_id)

  @spec get!(binary()) :: Request.t()
  def get!(request_id), do: Repo.get!(Request, request_id)

  @doc """
  Submit a new KYC request against an active method. Snapshots the method's
  `fields`/`version`/`step` at submission time — a later edit to the method
  never corrupts how this submission renders or which step it counted as
  (`docs/kyc/KYC_Implementation_Tracker.md` §3.3).

  Returns `{:error, :step_locked}` if an earlier *required* step for this
  product isn't approved for this customer yet (`Kyc.Journey`, §KYC-P3.5) —
  a defensive backstop; the submission UI shouldn't offer a locked step as
  selectable in the first place, but this is checked here too rather than
  trusted from the caller.
  """
  @spec submit(Method.t(), map()) :: {:ok, Request.t()} | {:error, Ecto.Changeset.t() | :step_locked}
  def submit(%Method{} = method, attrs) do
    customer_id = attrs["customer_id"] || attrs[:customer_id]

    if customer_id && not Journey.submittable?(customer_id, method) do
      {:error, :step_locked}
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs =
        attrs
        |> Map.merge(%{
          "kyc_method_id" => method.method_id,
          "method_version" => method.version,
          "fields_snapshot" => method.fields,
          "product_type" => method.product_type,
          "step" => method.step,
          "application_number" => generate_application_number(),
          "status" => "submitted",
          "submitted_at" => now
        })

      %Request{}
      |> Request.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc "Move a submitted request into review."
  @spec start_review(Request.t(), binary()) :: {:ok, Request.t()} | {:error, Ecto.Changeset.t()}
  def start_review(%Request{} = request, reviewer_id) do
    request
    |> Request.changeset(%{"status" => "under_review", "reviewer_id" => reviewer_id})
    |> Repo.update()
  end

  @doc "Approve a request. Syncs the target product's kyc_status (StatusSync)."
  @spec approve(Request.t(), binary(), String.t() | nil) :: {:ok, Request.t()} | {:error, Ecto.Changeset.t()}
  def approve(%Request{} = request, reviewer_id, reason \\ nil) do
    decide(request, "approved", reviewer_id, reason)
  end

  @doc "Reject a request. Syncs the target product's kyc_status (StatusSync)."
  @spec reject(Request.t(), binary(), String.t()) :: {:ok, Request.t()} | {:error, Ecto.Changeset.t()}
  def reject(%Request{} = request, reviewer_id, reason) do
    decide(request, "rejected", reviewer_id, reason)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp decide(request, status, reviewer_id, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      request
      |> Request.changeset(%{
        "status" => status,
        "reviewer_id" => reviewer_id,
        "decision_reason" => reason,
        "reviewed_at" => now
      })
      |> Repo.update()

    with {:ok, updated} <- result do
      StatusSync.sync(updated)
      {:ok, updated}
    end
  end

  defp generate_application_number do
    "KYC-" <> (:rand.uniform(900_000_000) + 100_000_000 |> Integer.to_string())
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query
  defp maybe_filter(query, field, value), do: where(query, [r], field(r, ^field) == ^value)
end
