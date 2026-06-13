defmodule VmuCore.LMS.GlProvisioner do
  @moduledoc """
  Posts provisioning GL entries for points earned and merchant settlement.

  GL account codes (LMS chart of accounts):
    7001 — LMS provisioning expense
    7002 — LMS provisioning liability
    7003 — LMS merchant receivable
    7004 — LMS merchant settlement income

  Rates are configured in application environment or ParameterEngine.
  Defaults: provision_rate = 1% of transaction amount; tax_rate = 5%.
  """

  alias VmuCore.CMS.InternalGlPoster
  alias Decimal, as: D

  @doc """
  Posts provisioning GL when points are earned.
  monetary_equiv ≈ original transaction amount; provision = amount × rate; tax on top.
  """
  def post_provisioning(scheme_id, %{monetary_equiv: amount, id: ledger_id}) do
    rate_pct   = provision_rate(scheme_id)
    tax_rate   = tax_rate(scheme_id)
    debit_gl   = gl_account(scheme_id, :provision_debit, "7001")
    credit_gl  = gl_account(scheme_id, :provision_credit, "7002")

    monetary = D.new(amount)
    provision_amount = D.mult(monetary, rate_pct)
    tax_amount       = D.mult(provision_amount, tax_rate)
    total            = D.add(provision_amount, tax_amount) |> D.round(2)

    InternalGlPoster.post(%{
      transaction_code: "ADJUSTMENT",
      gl_account_dr:    debit_gl,
      gl_account_cr:    credit_gl,
      dr_amount:        total,
      cr_amount:        total,
      narrative:        "LMS provisioning for ledger #{ledger_id}",
      idempotency_key:  "lms_prov_#{ledger_id}",
      posting_date:     Date.utc_today(),
      value_date:       Date.utc_today()
    })
  end

  @doc "Posts GL for merchant settlement (charge merchant for bonus points)."
  def post_merchant_settlement(%VmuCore.LMS.MerchantSettlement{} = settlement) do
    InternalGlPoster.post(%{
      transaction_code: "ADJUSTMENT",
      gl_account_dr:    "7003",
      gl_account_cr:    "7004",
      dr_amount:        settlement.settlement_amount,
      cr_amount:        settlement.settlement_amount,
      narrative:        "LMS merchant settlement group=#{settlement.group_id}",
      idempotency_key:  "lms_merch_#{settlement.id}",
      posting_date:     Date.utc_today(),
      value_date:       Date.utc_today()
    })
  end

  # ---------------------------------------------------------------------------
  # Private — config lookups with sensible defaults
  # ---------------------------------------------------------------------------

  defp provision_rate(scheme_id) do
    Application.get_env(:vmu_core, [:lms, :schemes, scheme_id, :provision_rate_pct], "0.01")
    |> D.new()
  end

  defp tax_rate(scheme_id) do
    Application.get_env(:vmu_core, [:lms, :schemes, scheme_id, :tax_rate], "0.05")
    |> D.new()
  end

  defp gl_account(scheme_id, key, default) do
    Application.get_env(:vmu_core, [:lms, :schemes, scheme_id, key], default)
  end
end
