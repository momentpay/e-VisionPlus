defmodule VmuCore.Posting.Shadow do
  @moduledoc """
  Runs the new posting engine alongside the legacy one, writing to separate
  tables so the two can be compared on real traffic (GL Phase B2).

  ## The contract

  **A shadow write must never affect the real posting.** `InternalGlPoster`
  remains authoritative for the whole of Phase B. Everything here is wrapped
  so that a failure — a bug in the engine, a missing period, a database
  problem — is logged and swallowed. The legacy path returns whatever it was
  always going to return.

  This is the same fail-safe discipline the authorization path uses: FAS never
  lets a TRAM hook change an authorization response.

  ## Off by default

      config :vmu_core, VmuCore.Posting.Shadow, enabled: true

  Application config rather than the Module Configuration Framework, which is
  the usual idiom here: `ModuleConfigEngine.get/3` is keyed by institution and
  reads through ETS, but this flag is a **rollout** concern, not per-bank
  business configuration, and it is checked on every single ledger write. A
  deployment-level switch with no per-posting lookup is the right shape.

  Off means zero overhead — the check is a config read and nothing else runs.

  Per-institution rollout, if it is ever wanted, belongs in `only_institutions`
  rather than in the module config cascade:

      config :vmu_core, VmuCore.Posting.Shadow,
        enabled: true,
        only_institutions: [{"MMPD", "MMBD"}]

  ## Why the amounts are compared, not the rows

  The two implementations write different shapes: `cms_ledger_entries` is one
  flat row per movement, while the engine writes a set, an entry, two legs, a
  journal entry and a consolidated GL row. They are joined on
  `idempotency_key`, which both sides carry and which is unique on both.
  """

  require Logger

  alias VmuCore.GL.InstitutionResolver
  alias VmuCore.Posting.{Cutover, RuleEngine}

  @doc """
  Mirrors a legacy posting through `RuleEngine`.

  Returns `:ok` for products still in shadow — the caller is not expected to
  check it, and nothing here can influence them.

  For a product that has been **cut over** (`Posting.Cutover`), returns
  `{:error, reason}` when the engine write fails, and the caller is expected to
  abort. That inversion is the entire content of Phase C1.
  """
  @spec mirror(map()) :: :ok | {:error, term()}
  def mirror(attrs) do
    if enabled?() or cutover_possible?() do
      run(attrs)
    else
      :ok
    end
  end

  # Shadow can be off while a product is cut over — at that point the engine is
  # no longer a mirror, it is the system of record for that product, and the
  # shadow switch must not be able to disable it.
  defp cutover_possible?, do: Cutover.products() != []

  defp run(attrs) do
    product = attrs |> Map.get(:account_id) |> to_string() |> product_of()

    if Cutover.authoritative?(product) do
      # Authoritative: failures propagate. No rescue — a posting that the
      # engine rejects must not be allowed to stand in the legacy table.
      case do_mirror(attrs) do
        :ok -> :ok
        {:error, reason} -> {:error, {:cutover_failed, product, reason}}
      end
    else
      shadow_safely(attrs)
    end
  end

  defp shadow_safely(attrs) do
    do_mirror(attrs)
    :ok
  rescue
    error ->
      Logger.warning("[GL shadow] swallowed #{inspect(error.__struct__)}: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("[GL shadow] swallowed #{kind}: #{inspect(reason)}")
      :ok
  end

  defp product_of(""), do: nil

  defp product_of(account_ref) do
    case InstitutionResolver.resolve_product(account_ref) do
      {:ok, product} -> product
      _ -> nil
    end
  end

  @doc "True when shadow posting is switched on."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, false) == true

  @doc "True when shadow posting is on for this institution."
  @spec enabled?(String.t(), String.t()) :: boolean()
  def enabled?(sys_id, bank_id) do
    enabled?() and
      case Keyword.get(config(), :only_institutions) do
        nil -> true
        list -> {sys_id, bank_id} in list
      end
  end

  defp config, do: Application.get_env(:vmu_core, __MODULE__, [])

  # ---------------------------------------------------------------------------

  defp do_mirror(attrs) do
    with {:ok, product} <- infer_product(attrs),
         {:ok, event_type} <- infer_event_type(attrs, product),
         account_ref <- to_string(attrs[:account_id]),
         {:ok, {sys_id, bank_id}} <- InstitutionResolver.resolve(account_ref, product),
         true <- enabled?(sys_id, bank_id) or {:error, :institution_not_in_rollout} do
      result =
        RuleEngine.execute(%{
          event_type: event_type,
          product: product,
          account_ref: account_ref,
          amount: attrs[:dr_amount] || attrs[:cr_amount],
          idempotency_key: attrs[:idempotency_key],
          sys_id: sys_id,
          bank_id: bank_id,
          currency: attrs[:currency] || "AED",
          posting_date: attrs[:posting_date],
          gl_date: attrs[:posting_date],
          transaction_date: attrs[:value_date],
          bindings: %{},
          source_module: "shadow:InternalGlPoster"
        })

      log(result, attrs)

      case result do
        {:ok, _} -> :ok
        {:ok, :duplicate, _} -> :ok
        {:error, :quarantined, exception} -> {:error, {:quarantined, exception.reason}}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    else
      {:error, reason} ->
        Logger.debug("[GL shadow] skipped #{attrs[:idempotency_key]}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # The legacy row does not name its product — it is implied by the account
  # table the id came from. Resolve it the same way the resolver does, then
  # trust that answer rather than guessing from the account codes, which is
  # what created the two-charts problem in the first place.
  defp infer_product(attrs) do
    account_ref = to_string(attrs[:account_id])

    cond do
      account_ref in [nil, ""] -> {:error, :no_account}
      true -> product_from_tables(account_ref)
    end
  end

  # Ask the resolver which table the account actually lives in, rather than
  # probing each product in turn. The probing version was subtly wrong: it
  # returned whichever product was tried first once the account was cached,
  # which made a credit account look like a debit account. See the resolver's
  # moduledoc.
  defp product_from_tables(account_ref) do
    case InstitutionResolver.resolve_product(account_ref) do
      {:ok, product} -> {:ok, product}
      {:error, reason} -> {:error, reason}
    end
  end

  # Map the legacy `transaction_code` onto a posting-rule event type. They are
  # deliberately not the same vocabulary: `transaction_code` is a constrained
  # enum on `cms_ledger_entries` with no WITHDRAWAL member, and both adjustment
  # directions share one code.
  defp infer_event_type(attrs, product) do
    code = attrs[:transaction_code]
    dr = attrs[:gl_account_dr]

    case {code, product} do
      {"PURCHASE", "WALLET"} -> {:ok, "WITHDRAWAL"}
      {"ADJUSTMENT", _} -> {:ok, adjustment_direction(dr, product)}
      {nil, _} -> {:error, :no_transaction_code}
      {c, _} -> {:ok, c}
    end
  end

  # Direction is recoverable from which side the stored-value liability sits
  # on: debiting the liability reduces the customer's balance.
  defp adjustment_direction(dr_account, product) do
    liability =
      case product do
        "DEBIT" -> "2004"
        "PREPAID" -> "2005"
        "WALLET" -> "2006"
        _ -> nil
      end

    if dr_account == liability, do: "ADJUSTMENT_DEBIT", else: "ADJUSTMENT_CREDIT"
  end

  defp log({:ok, _set}, attrs),
    do: Logger.debug("[GL shadow] mirrored #{attrs[:idempotency_key]}")

  defp log({:ok, :duplicate, _}, _attrs), do: :ok

  defp log({:error, :quarantined, exception}, attrs) do
    Logger.info(
      "[GL shadow] #{attrs[:idempotency_key]} quarantined: #{exception.reason}. " <>
        "The legacy posting still succeeded — shadow mode never blocks it."
    )
  end

  defp log({:error, reason}, attrs),
    do: Logger.warning("[GL shadow] #{attrs[:idempotency_key]} failed: #{inspect(reason)}")

  defp log(other, attrs),
    do: Logger.warning("[GL shadow] #{attrs[:idempotency_key]} unexpected: #{inspect(other)}")
end
