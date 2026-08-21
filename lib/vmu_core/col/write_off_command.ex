defmodule VmuCore.COL.WriteOffCommand do
  @moduledoc """
  Maker-checker command for automatic write-offs (COL-P2, FR-COL-020).

  `request/1` is called by `CollectionQueueJob` once an account's DPD crosses
  `col.writeoff_dpd_threshold` — it never posts a write-off directly. A human
  approver, whose ASM role must appear in `col.writeoff_approval_matrix` (ADMIN
  always qualifies, matching `VmuCore.ASM.Authz`'s short-circuit), must call
  `approve/2`, which is what actually invokes `VmuCore.COL.WriteOffProcessor.write_off/1`.

  Mirrors `VmuCore.TRAMS.AdjustmentCommand`'s shape (park → approve/reject →
  post), except approval is gated by role membership in a configured list
  rather than a monetary authority limit — write-off approval is a policy
  decision, not a delta-size decision.

  COL-P7: `request/2` refuses to park a write-off for an account with an open
  dispute (`VmuCore.COL.DisputeExclusion`) — collections should not push an
  account to write-off while a dispute is unresolved on it.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{COL.CollectionCase, COL.WriteOffRequest, COL.WriteOffProcessor, COL.DisputeExclusion}
  alias VmuCore.Shared.ModuleConfigEngine
  alias Decimal, as: D

  # M2 (2026-07-17): config-injected — see settlement_command.ex's identical fix.
  @repo Application.compile_env(:vmu_col, :repo, VmuCore.Repo)
  @account_schema Application.compile_env(:vmu_col, :cms_account_schema, VmuCore.CMS.Account)

  @doc """
  Request an automatic write-off for `account_id`. No-ops (returns the
  existing row) if a PENDING_APPROVAL or POSTED request already exists —
  callers (EOD-triggered) may run repeatedly as DPD keeps advancing.

  Returns `{:ok, :parked, request}` or `{:error, reason}` — including
  `{:error, :open_dispute_exists}` if the account has an unresolved DPS dispute.
  """
  @spec request(Ecto.UUID.t(), keyword()) ::
          {:ok, :parked | :already_pending | :already_posted, WriteOffRequest.t()}
          | {:error, term()}
  def request(account_id, opts \\ []) do
    cond do
      DisputeExclusion.open_dispute?(account_id) ->
        Logger.warning("[COL] Write-off request skipped: account=#{account_id} has an open dispute")
        {:error, :open_dispute_exists}

      true ->
        case existing_active(account_id) do
          %WriteOffRequest{status: "PENDING_APPROVAL"} = req -> {:ok, :already_pending, req}
          %WriteOffRequest{status: "POSTED"} = req -> {:ok, :already_posted, req}
          nil -> park(account_id, opts)
        end
    end
  end

  @doc """
  Approve a PENDING_APPROVAL request — validates maker ≠ checker and that the
  approver's role is authorized by `col.writeoff_approval_matrix` for the
  account's bank, then posts the write-off via `WriteOffProcessor.write_off/1`.

  Returns `{:ok, request}` or `{:error, reason}` with reasons:
  `:not_found` · `:not_pending` · `:maker_cannot_approve` ·
  `{:role_not_authorized, allowed_roles}` · whatever `WriteOffProcessor.write_off/1`
  returns (in which case the request is marked REJECTED, not left dangling).
  """
  @spec approve(Ecto.UUID.t(), term()) ::
          {:ok, WriteOffRequest.t()} | {:error, term()}
  def approve(request_id, %{username: _} = approver) do
    with %WriteOffRequest{} = req <- @repo.get(WriteOffRequest, request_id) || {:error, :not_found},
         :ok <- check_pending(req),
         :ok <- check_maker_checker(req, approver),
         :ok <- check_role_authorized(req, approver) do
      post(req, approver.username)
    end
  end

  @doc "Reject a PENDING_APPROVAL request."
  @spec reject(Ecto.UUID.t(), String.t()) :: {:ok, WriteOffRequest.t()} | {:error, term()}
  def reject(request_id, rejected_by) do
    with %WriteOffRequest{} = req <- @repo.get(WriteOffRequest, request_id) || {:error, :not_found},
         :ok <- check_pending(req) do
      req
      |> WriteOffRequest.changeset(%{status: "REJECTED", approved_by: rejected_by})
      |> @repo.update()
    end
  end

  @doc "Pending write-off requests for the approval inbox."
  @spec pending(non_neg_integer()) :: [WriteOffRequest.t()]
  def pending(limit \\ 50) do
    @repo.all(
      from r in WriteOffRequest,
        where: r.status == "PENDING_APPROVAL",
        order_by: [asc: r.inserted_at],
        limit: ^limit
    )
  end

  @doc "Roles currently authorized to approve write-offs for this account's bank."
  @spec allowed_roles(term()) :: [String.t()]
  def allowed_roles(%{sys_id: sys_id, bank_id: bank_id}) do
    case ModuleConfigEngine.get("col", "writeoff_approval_matrix", sys_id, bank_id) do
      {:ok, roles} -> roles
      {:error, _} -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp existing_active(account_id) do
    @repo.one(
      from r in WriteOffRequest,
        where: r.account_id == ^account_id and r.status in ["PENDING_APPROVAL", "POSTED"],
        order_by: [desc: r.inserted_at],
        limit: 1
    )
  end

  defp park(account_id, opts) do
    account = @repo.get!(@account_schema, account_id)
    write_off_amount = D.sub(account.credit_limit, account.open_to_buy)

    if D.compare(write_off_amount, D.new(0)) != :gt do
      {:error, :zero_balance}
    else
      case_id =
        @repo.one(
          from c in CollectionCase,
            where: c.account_id == ^account_id and c.status in ["OPEN", "AGENCY"],
            select: c.case_id,
            limit: 1
        )

      ifrs9_stage =
        case ModuleConfigEngine.get("col", "writeoff_ifrs9_stage", account.sys_id, account.bank_id) do
          {:ok, stage} -> stage
          {:error, _} -> nil
        end

      attrs = %{
        account_id:       account_id,
        case_id:          case_id,
        dpd_bucket:       account.delinquency_bucket,
        write_off_amount: write_off_amount,
        ifrs9_stage:      ifrs9_stage,
        reason:           Keyword.get(opts, :reason, "AUTO_DPD_#{account.delinquency_bucket}"),
        requested_by:     Keyword.get(opts, :requested_by, "SYSTEM_AUTO")
      }

      case @repo.insert(WriteOffRequest.changeset(%WriteOffRequest{}, attrs)) do
        {:ok, req} ->
          Logger.warning("[COL] Write-off requested: account=#{account_id} " <>
                          "dpd=#{req.dpd_bucket} amount=#{req.write_off_amount}")
          {:ok, :parked, req}

        {:error, cs} ->
          {:error, cs}
      end
    end
  end

  defp check_pending(%WriteOffRequest{status: "PENDING_APPROVAL"}), do: :ok
  defp check_pending(%WriteOffRequest{status: status}), do: {:error, {:not_pending, status}}

  defp check_maker_checker(%WriteOffRequest{requested_by: maker}, %{username: checker})
       when maker == checker,
       do: {:error, :maker_cannot_approve}

  defp check_maker_checker(_, _), do: :ok

  defp check_role_authorized(_req, %{role: "ADMIN"}), do: :ok

  defp check_role_authorized(req, %{role: role}) do
    account = @repo.get!(@account_schema, req.account_id)

    if role in allowed_roles(account) do
      :ok
    else
      {:error, {:role_not_authorized, allowed_roles(account)}}
    end
  end

  defp post(req, approved_by) do
    case WriteOffProcessor.write_off(req.account_id) do
      {:ok, %{write_off_amount: amount}} ->
        req
        |> WriteOffRequest.changeset(%{
          status:           "POSTED",
          approved_by:      approved_by,
          write_off_amount: amount,
          posted_at:        DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> @repo.update()

      {:error, reason} ->
        # Can't post (e.g. account no longer eligible, already written off by
        # another path) — reject rather than leave it dangling in the queue.
        Logger.warning("[COL] Write-off post failed for request=#{req.id}: #{inspect(reason)} — auto-rejecting")

        req
        |> WriteOffRequest.changeset(%{
          status:      "REJECTED",
          approved_by: approved_by,
          reason:      "#{req.reason} | post_failed=#{inspect(reason)}"
        })
        |> @repo.update()

        {:error, reason}
    end
  end
end
