defmodule VmuCore.CMS.ExternalPaymentCommand do
  @moduledoc """
  Initiates a wallet-out payment to an external bank account — A2A (W011)
  and Instant Payments (W012), Digital Wallet Phase W6 (2026-07-29). Two
  gates before money ever leaves the wallet:

    1. **Risk** — `FAS.RiskAdapter.evaluate/1`, the same `mw_risk`
       fraud/AML scoring pipeline FAS's card-authorization path already
       uses. `:decline` or `:review` blocks the payment before any
       balance movement — fail-closed; `:review` has no manual-release
       queue built yet (a known gap, same posture as KYC-P4's flagged
       sanctions-hit-override gap).
    2. **Rail** — `CMS.RailProvider.impl/0`, the pluggable adapter
       (`docs/wallet/DIGITAL_WALLET_Module_Requirements.md` §4/§5).

  The `ExternalPayment` row is always persisted first, before either gate
  runs — every attempt gets a permanent, queryable id regardless of
  outcome (same posture as `Kyc.Request` always being created before
  approve/reject), rather than losing the audit trail to a rolled-back
  transaction. If the rail declines after the wallet was already debited,
  the debit is explicitly reversed (compensating credit, not a
  transaction rollback — matches how a real async settlement rail would
  actually behave: you don't know the outcome until after the debit is
  already committed).

  The reversal deliberately bypasses `WalletVelocityLimits` — it isn't
  new money in, it's undoing money that should never have left, so a
  customer's DAILY/MONTHLY cap must never block getting their own funds
  back.
  """

  alias VmuCore.{Repo, CMS.WalletAccount, CMS.ExternalPayment, CMS.WalletWithdrawalCommand, CMS.InternalGlPoster, CMS.RailProvider}
  alias VmuCore.FAS.RiskAdapter

  @doc """
  attrs = %{wallet_account_id:, rail_type: "A2A" | "INSTANT", amount:,
            currency:, destination: %{...}, initiated_by:}
  """
  @spec initiate(map()) :: {:ok, ExternalPayment.t()} | {:error, term()}
  def initiate(attrs) do
    account = Repo.get!(WalletAccount, attrs.wallet_account_id)
    risk = evaluate_risk(account, attrs)

    case %ExternalPayment{} |> ExternalPayment.changeset(payment_attrs(account, attrs, initial_status(risk), risk)) |> Repo.insert() do
      {:ok, payment} ->
        case risk.decision do
          :approve -> move_funds(account, attrs, payment)
          blocked -> {:error, {:risk_blocked, blocked, payment}}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp initial_status(%{decision: :approve}), do: "initiated"
  defp initial_status(_blocked), do: "risk_declined"

  defp evaluate_risk(account, attrs) do
    {:ok, risk} =
      RiskAdapter.evaluate(%{
        rrn: nil, stan: nil,
        amount: Decimal.to_float(attrs.amount), currency: attrs.currency,
        sys_id: account.sys_id, pan: account.wallet_account_id,
        merchant_id: destination_ref(attrs.destination),
        terminal_id: attrs.rail_type, mcc: nil, mti: "external_payment"
      })

    risk
  end

  defp destination_ref(destination), do: destination["account_number"] || destination[:account_number]

  defp move_funds(account, attrs, payment) do
    idempotency_key = "external_payment:#{payment.id}"
    narrative = "#{attrs.rail_type} payment via #{attrs.initiated_by}"

    case WalletWithdrawalCommand.withdraw(account.wallet_account_id, attrs.amount, narrative, idempotency_key) do
      {:ok, %{ledger_entry: ledger_entry}} ->
        payment
        |> ExternalPayment.changeset(%{
          "ledger_entry_id" => ledger_entry.id, "status" => "submitted",
          "submitted_at" => DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update!()
        |> dispatch_to_rail(account, attrs)

      {:error, reason} ->
        fail(payment, reason)
    end
  end

  defp dispatch_to_rail(payment, account, attrs) do
    case RailProvider.impl().initiate(payment) do
      {:ok, %{external_reference: ref, status: status}} ->
        completed_at = if status == "completed", do: DateTime.utc_now() |> DateTime.truncate(:second)

        updated =
          payment
          |> ExternalPayment.changeset(%{"external_reference" => ref, "status" => status, "completed_at" => completed_at})
          |> Repo.update!()

        {:ok, updated}

      {:error, reason} ->
        reverse_debit(account, attrs, payment)
        fail(payment, {:rail_error, reason})
    end
  end

  defp reverse_debit(account, attrs, payment) do
    idempotency_key = "external_payment_reversal:#{payment.id}"

    Repo.transaction(fn ->
      import Ecto.Query

      {:ok, ledger_entry} =
        InternalGlPoster.post_wallet_load(
          account.wallet_account_id, attrs.amount, Date.utc_today(),
          "EXTERNAL_PAYMENT_REVERSAL", idempotency_key
        )

      {1, _} =
        Repo.update_all(
          from(w in WalletAccount, where: w.wallet_account_id == ^account.wallet_account_id),
          inc: [available_balance: attrs.amount]
        )

      ledger_entry
    end)
  end

  defp fail(payment, reason) do
    updated =
      payment
      |> ExternalPayment.changeset(%{"status" => "failed", "failure_reason" => inspect(reason)})
      |> Repo.update!()

    {:error, {reason, updated}}
  end

  defp payment_attrs(account, attrs, status, risk) do
    %{
      "wallet_account_id" => account.wallet_account_id,
      "customer_id" => account.customer_id,
      "rail_type" => attrs.rail_type,
      "rail_provider" => to_string(RailProvider.impl()),
      "amount" => attrs.amount,
      "currency" => attrs.currency,
      "destination" => attrs.destination,
      "status" => status,
      "risk_decision" => %{
        "decision" => to_string(risk.decision),
        "score" => risk.score,
        "fired_rules" => risk.fired_rules,
        "model_version" => risk.model_version
      },
      "initiated_by" => attrs.initiated_by
    }
  end
end
