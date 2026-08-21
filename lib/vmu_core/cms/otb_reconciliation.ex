defmodule VmuCore.CMS.OtbReconciliation do
  @moduledoc """
  Reconstructs an account's true `open_to_buy`/`cash_open_to_buy` from durable
  state, instead of trusting `cms_accounts.open_to_buy`/`cash_open_to_buy` —
  which nothing keeps in sync with live authorization activity (every write
  site is an administrative action: create, manual limit change, close,
  reopen, write-off — never a live-auth sync).

  `fas_pending_holds` is the durable source. Its own migration
  (`20260617000004_create_fas_pending_holds.exs`) says exactly why it exists:
  "Replaces the in-memory-only OTB reduction in AccountStateCoordinator,
  ensuring holds survive process restarts." Every approved credit
  authorization already creates a hold row (`FAS.Authorization.approve/2` →
  `persist_async/5` → `create_pending_hold/2`, async, off the response path),
  and reversal/completion handlers already mutate `cleared_at`/`reversal_at`/
  `hold_amount` on these rows in place — so "active holds" is self-correcting
  with zero new bookkeeping here.

  Used by `VmuCore.CMS.AccountStateCoordinator.load_state/1` (boot-time
  reconstruction — the actual crash-durability fix) and
  `VmuCore.CMS.Oban.OtbReconciliationSweepJob` (periodic write-back into
  `cms_accounts`, so direct DB readers like the operator console don't see a
  permanently stale value) — one shared implementation so the two call sites
  can't silently drift apart on the underlying math.
  """

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.CMS.Account
  alias VmuCore.FAS.{PendingHold, AuthorizationRecord}

  # Mirrors AccountStateCoordinator's own cash-transaction classification
  # (channel :atm, or MCC in this list) — kept here as the single shared
  # definition; AccountStateCoordinator.cash_transaction?/2 references
  # cash_mcc_groups/0 rather than maintaining a second copy.
  @cash_mcc_groups ~w[6010 6011 6012 6050 6051 6540]

  @doc "The MCC groups treated as cash-equivalent transactions."
  @spec cash_mcc_groups :: [String.t()]
  def cash_mcc_groups, do: @cash_mcc_groups

  @doc """
  Reconstructs `open_to_buy`/`cash_open_to_buy` for `account` from its
  `credit_limit`/`cash_limit` minus currently-active holds.

  "Active" = `cleared_at IS NULL AND reversal_at IS NULL` — the same
  predicate already used by `FAS.HoldAgingMonitor` and
  `TRAMS.Oban.AuthExpirySweepJob`, deliberately not additionally filtered on
  `expires_at`: live in-memory OTB doesn't proactively restore an
  expired-but-unswept hold either, so filtering here would silently diverge
  from current live behavior instead of matching it.

  `cash_open_to_buy` is `nil` whenever `account.cash_limit` is `nil`
  (unconstrained cash), matching `AccountStateCoordinator.check_cash_otb/3`'s
  existing nil short-circuit.
  """
  @spec reconstruct(Account.t()) :: %{
          open_to_buy: Decimal.t(),
          cash_open_to_buy: Decimal.t() | nil
        }
  def reconstruct(%Account{} = account) do
    total_holds = active_holds_total(account.account_id)

    cash_open_to_buy =
      if is_nil(account.cash_limit) do
        nil
      else
        Decimal.sub(account.cash_limit, cash_holds_total(account.account_id))
      end

    %{
      open_to_buy: Decimal.sub(account.credit_limit, total_holds),
      cash_open_to_buy: cash_open_to_buy
    }
  end

  defp active_holds_total(account_id) do
    Repo.one(
      from h in PendingHold,
        where: h.account_id == ^account_id and is_nil(h.cleared_at) and is_nil(h.reversal_at),
        select: coalesce(sum(h.hold_amount), 0)
    )
  end

  defp cash_holds_total(account_id) do
    Repo.one(
      from h in PendingHold,
        join: a in AuthorizationRecord, on: a.id == h.fas_authorization_id,
        where: h.account_id == ^account_id and is_nil(h.cleared_at) and is_nil(h.reversal_at) and
                 (a.channel == "atm" or a.mcc in ^@cash_mcc_groups),
        select: coalesce(sum(h.hold_amount), 0)
    )
  end
end
