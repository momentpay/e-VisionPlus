defmodule VmuCore.ITS.FeeClaimProcessor do
  @moduledoc """
  Creates and settles interchange fee claims for Mastercard/Visa clearing records.

  Called from VmuCore.TRAMS.MastercardIpm and VmuCore.TRAMS.VisaBaseIi after
  a clearing record is successfully inserted and matched.

  GL codes:
    its_interchange_recv    — DR (interchange receivable asset)
    its_interchange_income  — CR (interchange income)
  """

  alias VmuCore.ITS.FeeClaim
  alias VmuCore.CMS.InternalGlPoster
  alias VmuCore.Shared.ParameterEngine
  alias VmuCore.Repo
  import Ecto.Query
  alias Decimal, as: D

  @doc """
  Creates an interchange fee claim for one matched clearing record.
  Idempotent — re-insertion on the same clearing_record_id returns existing claim.
  """
  def create_claim(clearing_record) do
    idempotency_key = "fee_#{clearing_record.id}"

    # Check for existing claim (idempotency)
    case Repo.get_by(FeeClaim, idempotency_key: idempotency_key) do
      %FeeClaim{} = existing -> {:ok, existing}
      nil -> do_create_claim(clearing_record, idempotency_key)
    end
  end

  defp do_create_claim(clearing_record, idempotency_key) do
    network = clearing_record.network || "MC"
    mcc     = clearing_record.mcc

    rate         = lookup_interchange_rate(network, mcc)
    scheme_fee   = lookup_scheme_fee(network)
    gross        = D.new(clearing_record.amount)
    ic_amount    = D.mult(gross, rate) |> D.round(2)
    fee_amount   = D.mult(gross, scheme_fee) |> D.round(2)
    net_ic       = D.sub(ic_amount, fee_amount)

    cs = FeeClaim.changeset(%FeeClaim{}, %{
      clearing_record_id: clearing_record.id,
      network:            network,
      claim_type:         "INTERCHANGE_INCOME",
      mcc:                mcc,
      gross_amount:       gross,
      interchange_rate:   rate,
      interchange_amount: ic_amount,
      scheme_fee_amount:  fee_amount,
      net_interchange:    net_ic,
      currency:           clearing_record.currency || "AED",
      processing_date:    Date.utc_today(),
      status:             "PENDING",
      idempotency_key:    idempotency_key,
      inserted_at:        DateTime.utc_now()
    })

    case Repo.insert(cs, on_conflict: :nothing, conflict_target: :idempotency_key) do
      {:ok, claim} ->
        post_interchange_gl(claim, clearing_record.account_id)
        {:ok, claim}

      {:error, cs} ->
        {:error, cs}
    end
  end

  @doc """
  Settles all PENDING claims with processing_date up to settlement_date.
  Called from FeeSettlementJob monthly.
  """
  def settle_claims(settlement_date) do
    claims =
      from(f in FeeClaim,
        where: f.status == "PENDING" and f.processing_date <= ^settlement_date
      )
      |> Repo.all()

    {count, _} =
      Repo.update_all(
        from(f in FeeClaim,
          where: f.status == "PENDING" and f.processing_date <= ^settlement_date
        ),
        set: [status: "SETTLED", settlement_date: settlement_date]
      )

    total = Enum.reduce(claims, D.new(0), fn c, acc -> D.add(acc, c.net_interchange) end)
    {:ok, %{settled_count: count, total_settled: total}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp lookup_interchange_rate(network, mcc) do
    key = "its_interchange_rate_#{String.downcase(network)}_#{mcc || "default"}"

    case ParameterEngine.get("SYS", "SYS", "SYS", nil, key) do
      {:ok, val} when is_binary(val) -> D.new(val)
      _                              -> D.new("0.0165")
    end
  end

  defp lookup_scheme_fee(network) do
    key = "its_scheme_fee_#{String.downcase(network)}"

    case ParameterEngine.get("SYS", "SYS", "SYS", nil, key) do
      {:ok, val} when is_binary(val) -> D.new(val)
      _                              -> D.new("0.0010")
    end
  end

  defp post_interchange_gl(claim, account_id) do
    gl_account_id = if account_id, do: to_string(account_id), else: "SYSTEM"

    InternalGlPoster.post(%{
      account_id:       gl_account_id,
      idempotency_key:  "its_fee_gl_#{claim.id}",
      transaction_code: "INTERCHANGE_INCOME",
      dr_amount:        claim.net_interchange,
      cr_amount:        claim.net_interchange,
      gl_account_dr:    "its_interchange_recv",
      gl_account_cr:    "its_interchange_income",
      posting_date:     claim.processing_date,
      value_date:       claim.processing_date,
      narrative:        "Interchange #{claim.network} clearing #{claim.clearing_record_id}"
    })
  end
end
