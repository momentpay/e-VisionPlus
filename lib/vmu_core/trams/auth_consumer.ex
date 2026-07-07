defmodule VmuCore.TRAMS.AuthConsumer do
  @moduledoc """
  FAS → TRAM feed (TRAM-P2, spec 10 §2.1).

  Translates FAS authorization outcomes into TRAM transaction lifecycle
  events. Called from FAS's async persistence paths — never on the
  authorization hot path — and every entry point is fail-safe (ADR-T2): a
  TRAM failure logs and returns `:error`, it can never affect an
  authorization response or FAS persistence.

  | FAS source | TRAM effect |
  |---|---|
  | `Authorization.persist_async` (standard 0100) | open transaction + `authorization_approved` / `authorization_declined` + identifiers |
  | `ReversalHandler.do_reverse` (0400 matched) | `authorization_reversed` on the original transaction |
  | `IncrementalHandler` extend/trim | `incremental_authorization` / `authorization_partially_reversed` |
  | `CompletionHandler.process_completion` (matched) | `completion_received` → CLEARED |

  Idempotency: transaction creation is keyed on `fas_authorization_id`
  (unique index) via `EventStore.open/3`, so FAS retries cannot create
  duplicates. Transactions predating TRAM (no aggregate row) are skipped with
  a debug log rather than back-filled.
  """

  require Logger

  alias VmuCore.TRAMS.EventStore

  @doc """
  Record a standard authorization outcome. `record` is the persisted
  `%FAS.AuthorizationRecord{}`; `ctx` is FAS's request context (used for
  DE43 merchant name); `decision_path` for the event payload.
  """
  @spec record_authorization(struct(), map(), map()) :: :ok | :error
  def record_authorization(record, ctx, decision_path \\ %{}) do
    safe(fn ->
      event_type =
        if record.rc == "00", do: "authorization_approved", else: "authorization_declined"

      attrs = %{
        account_id:           record.account_id,
        pan_token:            record.pan_token,
        sys_id:               record.sys_id,
        logo_id:              record.logo_id,
        merchant_id:          record.merchant_id,
        merchant_name:        merchant_name(ctx),
        mcc:                  record.mcc,
        transaction_type:     transaction_type(record.channel),
        channel:              record.channel,
        amount:               record.amount,
        currency:             record.currency,
        fas_authorization_id: record.id,
        transaction_date:     DateTime.utc_now() |> DateTime.truncate(:second)
      }

      payload = %{
        rc:            record.rc,
        approval_code: record.approval_code,
        stip_used:     record.stip_used,
        path:          Map.get(decision_path, :path)
      }

      with {:ok, txn} <- EventStore.open(attrs, event_type, payload) do
        EventStore.add_identifier(txn.transaction_id, %{
          stan:      record.stan,
          rrn:       record.rrn,
          auth_code: record.approval_code,
          source:    "authorization"
        })

        :ok
      end
    end)
  end

  @doc """
  Record a matched 0400 reversal against the original authorization's
  transaction. `original_auth` is the matched `%FAS.AuthorizationRecord{}`.
  """
  @spec record_reversal(struct(), map()) :: :ok | :error
  def record_reversal(original_auth, fields) do
    safe(fn ->
      with_transaction(original_auth, fn txn ->
        EventStore.append(txn.transaction_id, "authorization_reversed", %{
          reversal_stan: Map.get(fields, 11),
          reversal_rrn:  Map.get(fields, 37),
          amount:        original_auth.amount
        }, actor: "network")
      end)
    end)
  end

  @doc """
  Record an incremental authorization (extend) or acquirer-initiated trim
  (partial reversal) against the original transaction.

  `kind` is `:extend` or `:trim`.
  """
  @spec record_incremental(struct(), Decimal.t(), String.t() | nil, :extend | :trim) ::
          :ok | :error
  def record_incremental(original_auth, new_total, new_approval_code, kind) do
    safe(fn ->
      event_type =
        case kind do
          :extend -> "incremental_authorization"
          :trim   -> "authorization_partially_reversed"
        end

      with_transaction(original_auth, fn txn ->
        result =
          EventStore.append(txn.transaction_id, event_type, %{
            new_total:     new_total,
            approval_code: new_approval_code
          }, actor: "network")

        if new_approval_code do
          EventStore.add_identifier(txn.transaction_id, %{
            auth_code: new_approval_code,
            source:    "authorization"
          })
        end

        result
      end)
    end)
  end

  @doc """
  Record a matched 0200 completion — the final-amount advice. Moves the
  transaction to CLEARED and records the settled amount on the aggregate.
  """
  @spec record_completion(struct(), Decimal.t(), map()) :: :ok | :error
  def record_completion(original_auth, final_amount, fields) do
    safe(fn ->
      with_transaction(original_auth, fn txn ->
        result =
          EventStore.append(txn.transaction_id, "completion_received", %{
            final_amount: final_amount,
            stan:         Map.get(fields, 11),
            rrn:          Map.get(fields, 37)
          }, actor: "network")

        with {:ok, %{transaction: updated}} <- result do
          updated
          |> Ecto.Changeset.change(settled_amount: final_amount)
          |> VmuCore.Repo.update()
        end

        result
      end)
    end)
  end

  @doc """
  Sync the TRAM aggregate after a settlement confirmation posted the ledger
  entry (called from `FAS.SettlementPostingAdapter.confirm_one/1` — the
  settlement_core HTTP path). Without this, aggregates on that path lag until
  the nightly posting cycle's ledger-key check.

  The aggregate may still be AUTHORIZED here (settlement_core confirmed
  before any clearing file/0200 was seen), so the state is walked
  AUTHORIZED → CLEARED → POSTED as needed. Already-POSTED aggregates are a
  no-op, so this is idempotent against the posting cycle racing it.
  """
  @spec record_settlement_confirmation(struct(), Decimal.t(), Date.t()) :: :ok | :error
  def record_settlement_confirmation(auth, settled_amount, settled_date) do
    safe(fn ->
      with_transaction(auth, fn txn ->
        txn =
          if txn.state in ["AUTHORIZED", "AUTH_MAINTENANCE"] do
            case EventStore.append(txn.transaction_id, "settlement_matched", %{
                   settled_amount: settled_amount,
                   settlement_date: settled_date,
                   source: "settlement_core_confirm"
                 }, actor: "system") do
              {:ok, %{transaction: updated}} ->
                updated
                |> Ecto.Changeset.change(settled_amount: settled_amount)
                |> VmuCore.Repo.update!()

              {:error, _} ->
                txn
            end
          else
            txn
          end

        if txn.state == "CLEARED" do
          EventStore.append(txn.transaction_id, "transaction_posted",
            %{source: "settlement_core_confirm"}, actor: "system")
        else
          :ok
        end
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp with_transaction(original_auth, fun) do
    case EventStore.by_fas_authorization(original_auth.id) do
      nil ->
        Logger.debug("[TRAMS.AuthConsumer] No TRAM transaction for auth " <>
                     "#{original_auth.id} (pre-dates TRAM feed) — skipped")
        :ok

      txn ->
        fun.(txn)
    end
  end

  # ATM channel = cash advance; everything else defaults to purchase.
  defp transaction_type("atm"), do: "CASH_ADV"
  defp transaction_type(_),     do: "PURCHASE"

  # DE43 = card acceptor name/location (may be absent in the field map)
  defp merchant_name(%{fields: fields}) when is_map(fields) do
    case Map.get(fields, 43) do
      name when is_binary(name) -> name |> String.trim() |> String.slice(0, 40)
      _ -> nil
    end
  end

  defp merchant_name(_), do: nil

  defp safe(fun) do
    case fun.() do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.error("[TRAMS.AuthConsumer] feed error: #{inspect(reason)}")
        :error
    end
  rescue
    e ->
      Logger.error("[TRAMS.AuthConsumer] feed crashed: #{Exception.message(e)}")
      :error
  end
end
