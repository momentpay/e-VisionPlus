defmodule VmuCore.FAS.DpanCache do
  @moduledoc """
  ETS-backed DPAN → account resolution for the authorization hot path
  (NTS Phase D, 2026-08-01) — structurally mirrors `FAS.HotCardCache`
  (same GenServer-refreshed, `:ets.lookup/2`-only-on-the-hot-path shape),
  with one deliberate asymmetry documented below.

  Loads every `ACTIVE` `NTS.Token` (a real, scheme-confirmed DPAN — see
  `NTS.Token`'s moduledoc on why `PENDING`/`PUSHED` tokens don't have a
  usable `dpan` yet) joined to its underlying card's resolved account,
  keyed by `pan_token(dpan)` — the same hash `FAS.Authorization.
  resolve_account/1` already computes for every transaction, reused, not
  duplicated.

  ## Fail-open vs. fail-closed — the deliberate asymmetry vs. HotCardCache

  `HotCardCache` is a **deny-list**: no data means "not blocked," a safe
  default, so it fails *open* on a missing/empty table (rescues to
  `:clean`). `DpanCache` is an **allow-list** used to *resolve* the
  account in the first place — a missing/empty entry must fail *closed*.
  This falls out naturally here: `check/1` returning `:not_found` simply
  means "not resolvable via a token," and `FAS.Authorization.
  resolve_account/1` falls through to the existing real-PAN resolution
  path for that case — the same `{:error, :account_not_found}` decline
  already covers an unresolvable transaction either way. Do **not** "fix"
  this to mirror `HotCardCache`'s rescue clause; they solve different
  problems.

  ## Why the cached account-block check matters *now*, concretely

  `NTS.TokenServiceProviders.MastercardMdes.suspend_token/1` is honestly
  `{:error, :mdes_lifecycle_api_not_in_scope}` (Token Connect's real spec
  has no lifecycle-management endpoints) — meaning `CardLifecycle.
  block/3`'s call into `NTS.TokenLifecycle.suspend_for_card/2` can never
  actually flip a real MDES token's local status to `SUSPENDED` today (the
  TSP call always fails, so the local transition never happens either).
  Without this cache independently re-checking the underlying account's
  block/active status on every refresh, a blocked card's DPAN would stay
  silently authorizable through the token path. This is real
  defense-in-depth, not a hypothetical.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.CTA.Card
  alias VmuCore.CMS.{Account, DebitAccount, PrepaidAccount}
  alias VmuCore.NTS.Token

  @table :vmu_dpan_cache
  @refresh_ms :timer.minutes(5)

  # ---------------------------------------------------------------------------
  # Public API — called directly on the auth hot path
  # ---------------------------------------------------------------------------

  @doc """
  Resolves an already-hashed token (the caller passes `pan_token(pan)` it
  already computed, same convention as `HotCardCache.check/1`) to the
  account/card a live DPAN maps to.

  Returns:
    - `{:ok, {account_id, card_id}}` — a live, active token
    - `:blocked`   — the token is real but its underlying account is
                     currently blocked/inactive (see moduledoc)
    - `:not_found` — not a known DPAN (most transactions — a real PAN)
  """
  @spec check(String.t()) :: {:ok, {binary(), binary()}} | :blocked | :not_found
  def check(token) do
    case :ets.lookup(@table, token) do
      [{_token, :blocked}] -> :blocked
      [{_token, {account_id, card_id}}] -> {:ok, {account_id, card_id}}
      [] -> :not_found
    end
  rescue
    # Table not yet created (race at boot) — fail closed: an unresolvable
    # token is not the same risk profile as an unresolvable hot-card check.
    _ -> :not_found
  end

  @doc "Forces an immediate synchronous refresh. Primarily for tests and NTS.TokenLifecycle's hooks."
  @spec refresh() :: :ok
  def refresh do
    GenServer.call(__MODULE__, :force_refresh)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    load_active_tokens()
    schedule_refresh()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    load_active_tokens()
    schedule_refresh()
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:force_refresh, _from, state) do
    load_active_tokens()
    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp load_active_tokens do
    rows =
      Repo.all(
        from t in Token,
          join: c in Card, on: c.card_id == t.card_id,
          where: t.status == "ACTIVE" and not is_nil(t.dpan),
          select: {t.dpan, c.card_id, c.account_id, c.debit_account_id, c.prepaid_account_id}
      )

    entries =
      Enum.map(rows, fn {dpan, card_id, account_id, debit_account_id, prepaid_account_id} ->
        value =
          case resolve_and_check_block(account_id, debit_account_id, prepaid_account_id) do
            {:ok, resolved_account_id} -> {resolved_account_id, card_id}
            :blocked -> :blocked
          end

        {pan_token(dpan), value}
      end)

    :ets.delete_all_objects(@table)
    :ets.insert(@table, entries)

    Logger.info("[FAS] DpanCache loaded #{length(entries)} active token(s)")
  rescue
    e ->
      Logger.warning("[FAS] DpanCache refresh failed: #{inspect(e)}")
  end

  defp resolve_and_check_block(account_id, nil, nil) when not is_nil(account_id) do
    case Repo.one(from a in Account, where: a.account_id == ^account_id, select: {a.account_status, a.block_code}) do
      {"ACTIVE", nil} -> {:ok, account_id}
      _ -> :blocked
    end
  end

  defp resolve_and_check_block(nil, debit_account_id, nil) when not is_nil(debit_account_id) do
    case Repo.one(from a in DebitAccount, where: a.debit_account_id == ^debit_account_id, select: {a.status, a.block_code}) do
      {"ACTIVE", nil} -> {:ok, debit_account_id}
      _ -> :blocked
    end
  end

  defp resolve_and_check_block(nil, nil, prepaid_account_id) when not is_nil(prepaid_account_id) do
    case Repo.one(from a in PrepaidAccount, where: a.prepaid_account_id == ^prepaid_account_id, select: {a.status, a.block_code}) do
      {"ACTIVE", nil} -> {:ok, prepaid_account_id}
      _ -> :blocked
    end
  end

  defp resolve_and_check_block(_account_id, _debit_account_id, _prepaid_account_id), do: :blocked

  # Same hash FAS.Authorization.pan_token/1 uses — deliberately duplicated
  # (a private one-liner, not worth a shared module for) rather than
  # exposing it from Authorization just for this.
  defp pan_token(pan), do: :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_ms)
  end
end
