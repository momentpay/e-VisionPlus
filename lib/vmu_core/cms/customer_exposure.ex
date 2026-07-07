defmodule VmuCore.CMS.CustomerExposure do
  @moduledoc """
  Customer-level exposure roll-up (CMS-G5.1, FR-CMS-030 — unblocks CDM
  FR-016 cross-account limit control).

  One customer (CIF) can hold several accounts; institution-level credit
  decisions need the aggregate view:

      exposure(customer_id)
      #=> %{total_credit_limit:, total_outstanding:, total_otb:,
            account_count:, worst_delinquency:, accounts: [...]}

  - **Outstanding** is bucket-derived (`BalanceBucket.total/1` on each
    account's latest bucket) — the same source of truth EOD uses.
  - CLOSED and WRITTEN_OFF accounts are excluded from limit/OTB totals but
    written-off *principal* is reported separately (`written_off_exposure`)
    because credit policy usually treats it as unrecovered exposure.
  - `headroom/2` is CDM's entry point: how much new limit can be granted
    before breaching the customer cap.
  """

  import Ecto.Query

  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket}
  alias Decimal, as: D

  @counted_statuses ~w[ACTIVE INACTIVE BLOCKED SUSPENDED DELINQUENT POSTING]

  @type exposure :: %{
          customer_id: Ecto.UUID.t(),
          total_credit_limit: Decimal.t(),
          total_outstanding: Decimal.t(),
          total_otb: Decimal.t(),
          written_off_exposure: Decimal.t(),
          worst_delinquency: non_neg_integer(),
          account_count: non_neg_integer(),
          accounts: [map()]
        }

  @doc "Aggregate exposure across all of a customer's accounts."
  @spec exposure(Ecto.UUID.t()) :: exposure()
  def exposure(customer_id) do
    accounts =
      Repo.all(from a in Account, where: a.customer_id == ^customer_id)

    counted   = Enum.filter(accounts, &(&1.account_status in @counted_statuses))
    write_off = Enum.filter(accounts, &(&1.account_status == "WRITTEN_OFF"))

    per_account =
      Enum.map(counted, fn account ->
        outstanding = outstanding(account.account_id)

        %{
          account_id:         account.account_id,
          logo_id:            account.logo_id,
          account_status:     account.account_status,
          credit_limit:       account.credit_limit,
          open_to_buy:        account.open_to_buy,
          outstanding:        outstanding,
          delinquency_bucket: account.delinquency_bucket || 0
        }
      end)

    %{
      customer_id:          customer_id,
      total_credit_limit:   sum_field(per_account, :credit_limit),
      total_outstanding:    sum_field(per_account, :outstanding),
      total_otb:            sum_field(per_account, :open_to_buy),
      written_off_exposure: written_off_exposure(write_off),
      worst_delinquency:    per_account
                            |> Enum.map(& &1.delinquency_bucket)
                            |> Enum.max(fn -> 0 end),
      account_count:        length(per_account),
      accounts:             per_account
    }
  end

  @doc """
  Remaining limit headroom under a customer-level cap (CDM FR-016).
  Returns `Decimal.new(0)` when already at/over the cap — never negative.
  """
  @spec headroom(Ecto.UUID.t(), Decimal.t()) :: Decimal.t()
  def headroom(customer_id, customer_cap) do
    %{total_credit_limit: total} = exposure(customer_id)
    D.max(D.sub(customer_cap, total), D.new(0))
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp outstanding(account_id) do
    bucket =
      Repo.one(
        from b in BalanceBucket,
          where: b.account_id == ^account_id,
          order_by: [desc: b.balance_date],
          limit: 1
      )

    case bucket do
      nil -> D.new(0)
      b -> BalanceBucket.total(b)
    end
  end

  # Written-off exposure = write-off amount = credit_limit − OTB at write-off,
  # but OTB was zeroed at write-off; use the latest bucket total (frozen at
  # write-off since accrual is suppressed)
  defp written_off_exposure(write_off_accounts) do
    write_off_accounts
    |> Enum.map(&outstanding(&1.account_id))
    |> Enum.reduce(D.new(0), &D.add/2)
  end

  defp sum_field(rows, field) do
    rows
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(D.new(0), &D.add/2)
  end
end
