defmodule VmuCore.CMS.PaymentIntake do
  @moduledoc """
  Channel-validated payment intake (CMS-G1 G1.5, FR-CMS-061/-062/-063/-068).

  The single entry point for applying a customer payment to an account:

  1. **Channel validation** — the channel must appear in the BANK-level
     `payment_channels_enabled` parameter (ADR-C3; v1 = gateway,
     direct_debit — enabling more channels is a parameter edit, not code).
  2. **Idempotency** — the caller's `reference` (gateway txn ID / mandate
     ref) keys the ledger entry as `"payment:<reference>"`; a redelivered
     webhook or retried job cannot double-apply.
  3. **Distribution** — allocates across balance buckets via
     `RepaymentDistributor.distribute_configured/3` (LOGO-configured
     hierarchy, ADR-C1) and persists the updated bucket.
  4. **GL** — posts one PAYMENT ledger entry (DR 9001 payment clearing /
     CR 1001 card receivables per the CardAccountCodes PAYMENT pattern).
  5. **OTB restore** — credits open-to-buy in the AccountStateCoordinator
     and stamps `last_payment_date`.

  Overpayment: any remainder beyond total outstanding stays on the bucket as
  a credit balance implicitly (buckets reach zero, remainder reported) —
  refund workflow is CMS-G4.1.

  Returns `{:ok, %{allocated: Decimal, remainder: Decimal, postings: [...]}}`
  or `{:error, reason}`.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket, CMS.LedgerEntry,
                 CMS.InternalGlPoster, CMS.RepaymentDistributor,
                 CMS.AccountStateCoordinator, CMS.Payment}
  alias VmuCore.Shared.ParameterEngine
  alias Decimal, as: D

  @valid_channels ~w[gateway direct_debit mobile_wallet branch_cash branch transfer]

  @doc """
  Apply a payment.

  Params (map):
    - `:account_id` — target account
    - `:amount`     — Decimal, > 0
    - `:channel`    — one of #{inspect(@valid_channels)}
    - `:reference`  — external unique reference (idempotency key basis)
  """
  @spec receive_payment(map()) :: {:ok, map()} | {:error, term()}
  def receive_payment(%{account_id: account_id, amount: amount,
                        channel: channel, reference: reference}) do
    with :ok <- validate_amount(amount),
         :ok <- validate_reference(reference),
         %Account{} = account <- Repo.get(Account, account_id) || {:error, :account_not_found},
         :ok <- validate_channel(account, channel),
         :ok <- check_idempotency(reference) do
      case account.account_status do
        # CMS-G4.3: money for a charged-off account is a RECOVERY — never
        # bucket distribution / OTB restore (the balance was written off)
        "WRITTEN_OFF" ->
          case VmuCore.CMS.ChargeOffRecovery.record_recovery(account_id, amount, reference) do
            {:ok, recovery} -> {:ok, Map.put(recovery, :routed, :charge_off_recovery)}
            {:error, _} = err -> err
          end

        _ ->
          apply_payment(account, amount, channel, reference)
      end
    end
  end

  @doc """
  Register an unmatched receipt in SUSPENSE (CMS-G2.3, FR-CMS-069) — money
  arrived but no account could be identified (bad reference, closed account,
  name-only transfer). No GL posting and no bucket movement: funds sit in
  the clearing account until ops applies or returns them.

  Params: `:amount`, `:channel`, `:reference` (unique), optional `:note`.
  """
  @spec receive_unmatched(map()) :: {:ok, Payment.t()} | {:error, term()}
  def receive_unmatched(%{amount: amount, channel: channel, reference: reference} = params) do
    with :ok <- validate_amount(amount),
         :ok <- validate_reference(reference),
         :ok <- check_idempotency(reference) do
      %Payment{}
      |> Payment.changeset(%{
        reference: reference,
        amount: amount,
        channel: channel,
        status: "SUSPENSE",
        note: params[:note]
      })
      |> Repo.insert()
    end
  end

  @doc """
  Apply a SUSPENSE payment to an account (ops action from the suspense
  queue). Runs the normal distribution/GL/OTB path and flips the register
  row to POSTED — the original reference is preserved, so the eventual
  ledger key is the same one a direct application would have produced.
  """
  @spec apply_suspense(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def apply_suspense(payment_id, account_id) do
    with %Payment{status: "SUSPENSE"} = row <-
           Repo.get(Payment, payment_id) || {:error, :not_found},
         %Account{} = account <-
           Repo.get(Account, account_id) || {:error, :account_not_found} do
      apply_payment(account, row.amount, row.channel, row.reference, row)
    else
      %Payment{status: status} -> {:error, {:not_in_suspense, status}}
      {:error, _} = err -> err
    end
  end

  @doc "SUSPENSE rows awaiting ops action, oldest first."
  @spec suspense_queue(non_neg_integer()) :: [Payment.t()]
  def suspense_queue(limit \\ 50) do
    Repo.all(
      from p in Payment,
        where: p.status == "SUSPENSE",
        order_by: [asc: p.inserted_at],
        limit: ^limit
    )
  end

  @doc "Channels enabled for an account's BANK (for UI/channel adapters)."
  @spec enabled_channels(Account.t()) :: [String.t()]
  def enabled_channels(%Account{} = account) do
    case ParameterEngine.get(account.sys_id, account.bank_id, account.logo_id,
                             account.block_id || "", :payment_channels_enabled) do
      {:ok, csv} when is_binary(csv) and csv != "" ->
        csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

      _ ->
        ["gateway", "direct_debit"]
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_amount(%D{} = amount) do
    if D.compare(amount, D.new(0)) == :gt, do: :ok, else: {:error, :invalid_amount}
  end

  defp validate_amount(_), do: {:error, :invalid_amount}

  defp validate_reference(ref) when is_binary(ref) and byte_size(ref) > 0, do: :ok
  defp validate_reference(_), do: {:error, :reference_required}

  defp validate_channel(account, channel) do
    cond do
      channel not in @valid_channels ->
        {:error, {:unknown_channel, channel}}

      channel not in enabled_channels(account) ->
        {:error, {:channel_not_enabled, channel}}

      true ->
        :ok
    end
  end

  defp check_idempotency(reference) do
    cond do
      # Payment register is authoritative (CMS-G2)
      match?(%Payment{status: "SUSPENSE"}, Repo.get_by(Payment, reference: reference)) ->
        {:error, :reference_in_suspense}

      Repo.exists?(from p in Payment, where: p.reference == ^reference) ->
        {:error, :duplicate_payment}

      # Belt-and-braces: pre-register ledger entries (G1-era payments)
      Repo.exists?(from e in LedgerEntry, where: e.idempotency_key == ^ledger_key(reference)) ->
        {:error, :duplicate_payment}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Application
  # ---------------------------------------------------------------------------

  defp apply_payment(account, amount, channel, reference, suspense_row \\ nil) do
    bucket = latest_bucket(account.account_id)

    if is_nil(bucket) do
      {:error, :no_balance_bucket}
    else
      {:ok, %{updated_bucket: new_bucket, gl_postings: postings, remainder: remainder}} =
        RepaymentDistributor.distribute_configured(amount, bucket, account)

      allocated = D.sub(amount, remainder)

      result =
        Repo.transaction(fn ->
          persist_bucket!(bucket, new_bucket)
          post_payment_ledger!(account, amount, channel, reference)
          record_payment!(account, amount, allocated, remainder, channel,
                          reference, postings, suspense_row)

          Repo.update_all(
            from(a in Account, where: a.account_id == ^account.account_id),
            set: [last_payment_date: Date.utc_today(),
                  updated_at: NaiveDateTime.utc_now()]
          )
        end)

      case result do
        {:ok, _} ->
          # OTB restore outside the DB transaction — ASC is an in-memory
          # GenServer. Restore the ALLOCATED portion (outstanding actually
          # reduced); overpayment remainder awaits the CMS-G4 refund flow.
          if D.compare(allocated, D.new(0)) == :gt do
            AccountStateCoordinator.credit_open_to_buy(account.account_id, allocated)
          end

          RepaymentDistributor.credit_hcs_limits(account.account_id, allocated)

          Logger.info("[PaymentIntake] account=#{account.account_id} " <>
                      "amount=#{amount} allocated=#{allocated} " <>
                      "remainder=#{remainder} channel=#{channel} ref=#{reference}")

          {:ok, %{allocated: allocated, remainder: remainder, postings: postings}}

        {:error, reason} ->
          Logger.error("[PaymentIntake] failed ref=#{reference}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp latest_bucket(account_id) do
    Repo.one(
      from b in BalanceBucket,
        where: b.account_id == ^account_id,
        order_by: [desc: b.balance_date],
        limit: 1
    )
  end

  # Payment register row (CMS-G2) — postings stored as %{"field" => "amount"}
  # so PaymentReversal can re-debit the exact distribution
  defp record_payment!(account, amount, allocated, remainder, channel,
                       reference, postings, suspense_row) do
    postings_map =
      Map.new(postings, fn %{bucket_field: field, amount: amt} ->
        {to_string(field), D.to_string(amt)}
      end)

    attrs = %{
      account_id: account.account_id,
      reference:  reference,
      amount:     amount,
      allocated:  allocated,
      remainder:  remainder,
      channel:    channel,
      status:     "POSTED",
      postings:   postings_map
    }

    case suspense_row do
      %Payment{} = row -> row |> Payment.changeset(attrs) |> Repo.update!()
      nil              -> %Payment{} |> Payment.changeset(attrs) |> Repo.insert!()
    end
  end

  @bucket_fields ~w[retail_balance cash_balance bt_balance accrued_interest
                    unpaid_fees emi_balance]a

  defp persist_bucket!(bucket, new_bucket) do
    changes =
      @bucket_fields
      |> Enum.map(fn f -> {f, Map.get(new_bucket, f)} end)
      |> Enum.reject(fn {_f, v} -> is_nil(v) end)

    Repo.update_all(
      from(b in BalanceBucket, where: b.bucket_id == ^bucket.bucket_id),
      set: changes ++ [updated_at: NaiveDateTime.utc_now()]
    )
  end

  # One PAYMENT entry for the full received amount (CardAccountCodes PAYMENT
  # pattern: DR payment clearing — 9001 suspense stands in for the external
  # NOSTRO until core-banking clearing accounts are mapped — / CR 1001).
  defp post_payment_ledger!(account, amount, channel, reference) do
    case InternalGlPoster.post(%{
           account_id:       account.account_id,
           idempotency_key:  ledger_key(reference),
           transaction_code: "PAYMENT",
           dr_amount:        amount,
           cr_amount:        amount,
           gl_account_dr:    "9001",
           gl_account_cr:    "1001",
           posting_date:     Date.utc_today(),
           value_date:       Date.utc_today(),
           narrative:        "Payment via #{channel} ref=#{reference}",
           source_ref:       reference
         }) do
      {:ok, _entry} -> :ok
      {:error, :duplicate} -> :ok
      {:error, reason} -> Repo.rollback({:gl_post_failed, reason})
    end
  end

  defp ledger_key(reference), do: "payment:#{reference}"
end
