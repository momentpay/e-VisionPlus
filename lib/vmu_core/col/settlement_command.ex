defmodule VmuCore.COL.SettlementCommand do
  @moduledoc """
  Maker-checker command for lump-sum settlement offers (COL-P9, FR-COL-015).

  `request/5` parks an offer (validated against `col.settlement_min_acceptable_percent`
  — an offer can't discount below that floor). `approve/2` gates on the
  approver's ASM role having a high-enough limit in `col.settlement_authority_matrix`
  for the offer's `discount_percent` (mirrors `TRAMS.AdjustmentCommand`'s
  authority-limit shape, but by discount percent rather than dollar delta — a
  role's tier entry is its ceiling, so a role can approve anything up to its own
  limit, not just its specific band). `settle/3` is the actual money event: posts
  the real payment received, then forgives the remainder via a GL adjustment
  entry (same `"ADJUSTMENT"` transaction code `WriteOffProcessor` already uses —
  no new ledger transaction code to forget registering).
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{COL.CollectionCase, COL.SettlementOffer}
  alias VmuCore.Shared.ModuleConfigEngine
  alias Decimal, as: D

  # M2 (2026-07-17): config-injected — CMS/ASM aren't extracted yet. ASM
  # Operator struct patterns are rewritten as bare %{field: val} map
  # patterns — see vmu_hcs's identical fix.
  @repo Application.compile_env(:vmu_col, :repo, VmuCore.Repo)
  @account_schema Application.compile_env(:vmu_col, :cms_account_schema, VmuCore.CMS.Account)
  @internal_gl_poster Application.compile_env(:vmu_col, :cms_internal_gl_poster, VmuCore.CMS.InternalGlPoster)

  # M5 Phase 2 (2026-07-18) — reconciled onto WalletGl.ChartOfAccounts;
  # these 3 codes previously collided with CardAccountCodes' unrelated
  # "5001 Interchange/MDR Expense" and referenced a phantom "1000" that
  # existed in no registry anywhere.
  @gl_charged_off "1005"
  @gl_retail_recv "1001"
  @gl_cash "3001"

  @doc "Request a settlement offer. discount_percent is computed from the case's current outstanding_amount."
  @spec request(Ecto.UUID.t(), Ecto.UUID.t(), Decimal.t(), Date.t(), String.t()) ::
          {:ok, SettlementOffer.t()} | {:error, term()}
  def request(case_id, account_id, offer_amount, expiry_date, requested_by) do
    with %CollectionCase{} = case_row <- @repo.get(CollectionCase, case_id) || {:error, :case_not_found} do
      outstanding = case_row.outstanding_amount
      discount_percent = compute_discount_percent(outstanding, offer_amount)
      account = @repo.get!(@account_schema, account_id)

      {:ok, min_percent} =
        ModuleConfigEngine.get("col", "settlement_min_acceptable_percent", account.sys_id, account.bank_id)

      max_allowed_discount = D.sub(D.new(100), D.new(min_percent))

      if D.compare(discount_percent, max_allowed_discount) == :gt do
        {:error, {:discount_too_deep, discount_percent, max_allowed_discount}}
      else
        attrs = %{
          case_id: case_id, account_id: account_id, outstanding_amount: outstanding,
          offer_amount: offer_amount, discount_percent: discount_percent,
          expiry_date: expiry_date, requested_by: requested_by
        }

        @repo.insert(SettlementOffer.changeset(%SettlementOffer{}, attrs))
      end
    end
  end

  @doc "Approve a PENDING_APPROVAL settlement offer."
  @spec approve(Ecto.UUID.t(), term()) :: {:ok, SettlementOffer.t()} | {:error, term()}
  def approve(offer_id, %{username: _} = approver) do
    with %SettlementOffer{} = offer <- @repo.get(SettlementOffer, offer_id) || {:error, :not_found},
         :ok <- check_pending(offer),
         :ok <- check_maker_checker(offer, approver),
         :ok <- check_authority(offer, approver) do
      offer |> SettlementOffer.changeset(%{status: "APPROVED", approved_by: approver.username}) |> @repo.update()
    end
  end

  @doc "Reject a PENDING_APPROVAL settlement offer."
  @spec reject(Ecto.UUID.t(), String.t()) :: {:ok, SettlementOffer.t()} | {:error, term()}
  def reject(offer_id, rejected_by) do
    with %SettlementOffer{} = offer <- @repo.get(SettlementOffer, offer_id) || {:error, :not_found},
         :ok <- check_pending(offer) do
      offer |> SettlementOffer.changeset(%{status: "REJECTED", approved_by: rejected_by}) |> @repo.update()
    end
  end

  @doc """
  Record the customer's settlement payment and forgive the remainder. Requires
  `status: "APPROVED"` and not past `expiry_date`. Posts the received amount
  (transaction_code `"PAYMENT"`) then the forgiven remainder, if any
  (transaction_code `"ADJUSTMENT"`, same GL direction `WriteOffProcessor` uses).
  Case → `RECOVERED`, offer → `PAID`.
  """
  @spec settle(Ecto.UUID.t(), Decimal.t(), String.t()) :: {:ok, SettlementOffer.t()} | {:error, term()}
  def settle(offer_id, actual_amount, reference) do
    with %SettlementOffer{status: "APPROVED"} = offer <- @repo.get(SettlementOffer, offer_id) || {:error, :not_found},
         :ok <- check_not_expired(offer) do
      forgiven = D.max(D.sub(offer.outstanding_amount, actual_amount), D.new(0))

      @repo.transaction(fn ->
        case @internal_gl_poster.post(%{
               account_id: offer.account_id, idempotency_key: "SETTLEMENT-#{offer.id}",
               transaction_code: "PAYMENT", dr_amount: actual_amount, cr_amount: actual_amount,
               gl_account_dr: @gl_cash, gl_account_cr: @gl_retail_recv,
               posting_date: Date.utc_today(), value_date: Date.utc_today(),
               narrative: "Settlement payment — offer #{offer.id}", source_ref: reference
             }) do
          {:ok, _} -> :ok
          {:error, :duplicate} -> :ok
          {:error, reason} -> @repo.rollback({:payment_post_failed, reason})
        end

        if D.compare(forgiven, D.new(0)) == :gt do
          case @internal_gl_poster.post(%{
                 account_id: offer.account_id, idempotency_key: "SETTLEMENT-FORGIVE-#{offer.id}",
                 transaction_code: "ADJUSTMENT", dr_amount: forgiven, cr_amount: forgiven,
                 gl_account_dr: @gl_charged_off, gl_account_cr: @gl_retail_recv,
                 posting_date: Date.utc_today(), value_date: Date.utc_today(),
                 narrative: "Settlement forgiveness — offer #{offer.id}"
               }) do
            {:ok, _} -> :ok
            {:error, :duplicate} -> :ok
            {:error, reason} -> @repo.rollback({:forgiveness_post_failed, reason})
          end
        end

        updated =
          offer
          |> SettlementOffer.changeset(%{
            status: "PAID", paid_amount: actual_amount, forgiven_amount: forgiven,
            reference: reference, paid_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })
          |> @repo.update!()

        case @repo.get(CollectionCase, offer.case_id) do
          nil -> :ok
          case_row -> case_row |> CollectionCase.changeset(%{status: "RECOVERED"}) |> @repo.update!()
        end

        Logger.warning("[COL] Settlement paid: offer=#{offer.id} account=#{offer.account_id} " <>
                        "received=#{actual_amount} forgiven=#{forgiven}")

        updated
      end)
    end
  end

  @doc "Pending settlement offers for the approval inbox."
  @spec pending(non_neg_integer()) :: [SettlementOffer.t()]
  def pending(limit \\ 50) do
    @repo.all(from o in SettlementOffer, where: o.status == "PENDING_APPROVAL", order_by: [asc: o.inserted_at], limit: ^limit)
  end

  @doc "This account's bank-scoped settlement authority tiers."
  @spec authority_tiers(term()) :: [map()]
  def authority_tiers(%{sys_id: sys_id, bank_id: bank_id}) do
    case ModuleConfigEngine.get("col", "settlement_authority_matrix", sys_id, bank_id) do
      {:ok, %{"tiers" => tiers}} -> tiers
      _ -> []
    end
  end

  defp compute_discount_percent(outstanding, offer_amount) do
    if D.compare(outstanding, D.new(0)) == :gt do
      D.sub(outstanding, offer_amount) |> D.div(outstanding) |> D.mult(D.new(100)) |> D.round(2)
    else
      D.new(0)
    end
  end

  defp check_pending(%SettlementOffer{status: "PENDING_APPROVAL"}), do: :ok
  defp check_pending(%SettlementOffer{status: status}), do: {:error, {:not_pending, status}}

  defp check_not_expired(%SettlementOffer{expiry_date: expiry}) do
    if Date.compare(Date.utc_today(), expiry) == :gt, do: {:error, :offer_expired}, else: :ok
  end

  defp check_maker_checker(%SettlementOffer{requested_by: maker}, %{username: checker}) when maker == checker,
    do: {:error, :maker_cannot_approve}

  defp check_maker_checker(_, _), do: :ok

  defp check_authority(_offer, %{role: "ADMIN"}), do: :ok

  defp check_authority(offer, %{role: role} = approver) do
    account = @repo.get!(@account_schema, offer.account_id)
    tier = Enum.find(authority_tiers(account), &(&1["role"] == role))

    result =
      cond do
        is_nil(tier) ->
          {:error, {:role_not_authorized, authority_tiers(account)}}

        D.compare(offer.discount_percent, D.new(to_string(tier["max_discount_percent"]))) == :gt ->
          {:error, {:discount_exceeds_authority, offer.discount_percent, tier["max_discount_percent"]}}

        true ->
          :ok
      end

    if result != :ok do
      Logger.info("[COL] Settlement approval denied: offer=#{offer.id} approver=#{approver.username} " <>
                  "role=#{approver.role} reason=#{inspect(result)}")
    end

    result
  end
end
