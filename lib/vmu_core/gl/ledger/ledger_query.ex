defmodule VmuCore.GL.LedgerQuery do
  @moduledoc """
  Read API over the new posting tables, for modules migrating off
  `cms_ledger_entries` (GL Phase C2).

  ## Why an API rather than per-reader queries

  Twelve modules read the legacy ledger, and none of them wants *rows* — they
  want answers: "how much did this account pay during the cycle", "how many
  postings has it had", "which accounts posted on this date". Twelve
  hand-written queries against `journal_entries` would spread the new schema
  across the codebase and make a future change to it a twelve-file edit. One
  API keeps that surface in a single module.

  ## Vocabulary translation

  Readers filter on `cms_ledger_entries.transaction_code`. The new model uses
  `posting_sets.event_type`, which is deliberately a different vocabulary —
  wallet withdrawals post as `PURCHASE` in the legacy enum, and both adjustment
  directions collapse to `ADJUSTMENT` there. This module accepts **legacy
  transaction codes** and translates, so a reader migrating across does not
  also have to change what it means. `posting_rules.legacy_transaction_code`
  is the mapping.

  ## Amounts

  `cms_ledger_entries` carries `dr_amount` and `cr_amount` separately, and
  readers sum one or the other. Under double entry those are equal on every
  row — `LedgerEntry`'s changeset enforces it — so `journal_entries.amount` is
  the same number and `sum_amount/2` serves both.

  ## Not covered

  `cms_ledger_entries.extracted_at` has no equivalent here. It is extraction
  state owned by `CMS.CoreBankingAdapter`, not accounting data, and that
  reader is deliberately last in the C2 order.
  """

  import Ecto.Query, warn: false

  alias VmuCore.Repo
  alias VmuCore.Posting.{JournalEntry, PostingSet}

  # Legacy transaction_code => the event types that produce it.
  # Derived from `Posting.Rules.default_rules/0`'s `legacy_transaction_code`.
  @legacy_code_events %{
    "PURCHASE" => ["PURCHASE", "WITHDRAWAL"],
    "DEPOSIT" => ["DEPOSIT"],
    "PAYMENT" => ["PAYMENT"],
    "INTEREST" => ["INTEREST"],
    "FEE" => ["FEE"],
    "CASH_ADV" => ["CASH_ADV"],
    "REVERSAL" => ["REVERSAL"],
    "ADJUSTMENT" => ["ADJUSTMENT_CREDIT", "ADJUSTMENT_DEBIT"],
    "DISPUTE_CREDIT" => ["DISPUTE_CREDIT"]
  }

  @type filters :: [
          account_ref: String.t() | [String.t()],
          transaction_code: String.t() | [String.t()],
          event_type: String.t() | [String.t()],
          product: String.t(),
          from: Date.t(),
          to: Date.t(),
          on: Date.t(),
          inserted_from: DateTime.t() | NaiveDateTime.t(),
          inserted_to: DateTime.t() | NaiveDateTime.t(),
          gl_account: String.t(),
          idempotency_key: String.t(),
          idempotency_key_prefix: String.t(),
          as_uuid: boolean()
        ]

  @doc """
  Sums posted amounts.

  Replaces `sum(e.dr_amount)` / `sum(e.cr_amount)` over `cms_ledger_entries`.
  Returns `Decimal.new(0)` when nothing matches, never nil, so callers do not
  need the `|| Decimal.new(0)` guard the legacy queries all carry.

      LedgerQuery.sum_amount(account_ref: id, transaction_code: "PAYMENT",
                             from: cycle_start, to: statement_date)
  """
  @spec sum_amount(filters()) :: Decimal.t()
  def sum_amount(filters) do
    filters
    |> base_query()
    |> select([j], coalesce(sum(j.amount), 0))
    |> Repo.one()
    |> case do
      nil -> Decimal.new(0)
      %Decimal{} = d -> d
      n -> Decimal.new(n)
    end
  end

  @doc "Counts matching postings."
  @spec count(filters()) :: non_neg_integer()
  def count(filters) do
    filters |> base_query() |> select([j], count(j.id)) |> Repo.one() || 0
  end

  @doc "True when any posting matches. Cheaper than `count/1` for existence checks."
  @spec exists?(filters()) :: boolean()
  def exists?(filters), do: filters |> base_query() |> Repo.exists?()

  @doc """
  Distinct product accounts with postings matching the filters.

  Replaces `select: e.account_id` with `distinct: true` over the legacy table —
  the shape `CoreBankingAdapter` uses to find accounts needing extraction.
  """
  @spec account_refs(filters()) :: [String.t()]
  def account_refs(filters) do
    filters |> account_refs_query() |> Repo.all()
  end

  @doc """
  The same query as `account_refs/1`, unexecuted, so a caller can embed it with
  `subquery/1` instead of materialising the list.

  `CMS.Oban.AccountLifecycleSweepJob` needs this: *"accounts with no ledger
  activity since the cutoff"* over a live portfolio would otherwise pull every
  recently-active account into memory to build a `not in ^list`.

  `account_ref` is a string column — the new tables hold references from five
  products whose keys are not all the same type — so the select casts to
  `Ecto.UUID` for comparison against a `uuid` column. **Filter by `:product`
  when you do this.** An unfiltered cast would raise on the first reference
  that is not UUID-shaped, and a sweep over one product's accounts has no
  business looking at another product's activity anyway.
  """
  @spec account_refs_query(filters()) :: Ecto.Query.t()
  def account_refs_query(filters) do
    cast? = Keyword.get(filters, :as_uuid, false)

    query =
      filters
      |> Keyword.delete(:as_uuid)
      |> base_query()
      |> distinct(true)

    if cast? do
      select(query, [j], type(j.account_ref, Ecto.UUID))
    else
      select(query, [j], j.account_ref)
    end
  end

  @doc """
  Which of the given idempotency keys have actually posted.

  The reconciliation shape: a caller holds a list of keys it *expects* to find
  and wants the subset that exists, so the difference is its exception list.
  Unlike `entries/1` this has no limit — truncating a reconciliation would
  manufacture gaps that are not there.
  """
  @spec posted_keys([String.t()]) :: MapSet.t(String.t())
  def posted_keys([]), do: MapSet.new()

  def posted_keys(keys) when is_list(keys) do
    [idempotency_key: keys]
    |> base_query()
    |> distinct(true)
    |> select([_j, s], s.idempotency_key)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Postings themselves, most recent first, in a shape close to the legacy row so
  a migrating reader has less to rewrite.

  `:limit` defaults to 500 — an unbounded ledger read is never what a caller
  actually wants.
  """
  @spec entries(filters()) :: [map()]
  def entries(filters) do
    limit = Keyword.get(filters, :limit, 500)

    filters
    |> base_query()
    |> order_by([j, _s], desc: j.posting_date, desc: j.inserted_at)
    |> limit(^limit)
    |> select([j, s], %{
      idempotency_key: s.idempotency_key,
      account_ref: j.account_ref,
      product: j.product,
      event_type: s.event_type,
      dr_gl_account: j.dr_gl_account,
      cr_gl_account: j.cr_gl_account,
      amount: j.amount,
      currency: j.currency,
      transaction_date: j.transaction_date,
      posting_date: j.posting_date,
      gl_date: j.gl_date,
      narrative: j.narrative
    })
    |> Repo.all()
  end

  @doc """
  Event types a legacy `transaction_code` maps to.

  Exposed so a migrating reader can see the translation rather than assume the
  two vocabularies match — they mostly do, and the exceptions are exactly where
  a silent bug would hide.
  """
  @spec events_for_legacy_code(String.t()) :: [String.t()]
  def events_for_legacy_code(code), do: Map.get(@legacy_code_events, code, [code])

  # ---------------------------------------------------------------------------

  defp base_query(filters) do
    JournalEntry
    |> join(:inner, [j], s in PostingSet, on: s.id == j.posting_set_id)
    |> apply_filters(filters)
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:account_ref, refs}, q when is_list(refs) ->
        where(q, [j, _s], j.account_ref in ^Enum.map(refs, &to_string/1))

      {:account_ref, ref}, q ->
        where(q, [j, _s], j.account_ref == ^to_string(ref))

      {:product, product}, q ->
        where(q, [j, _s], j.product == ^product)

      {:transaction_code, code}, q ->
        events = code |> List.wrap() |> Enum.flat_map(&events_for_legacy_code/1) |> Enum.uniq()
        where(q, [_j, s], s.event_type in ^events)

      {:event_type, event}, q ->
        where(q, [_j, s], s.event_type in ^List.wrap(event))

      {:from, date}, q ->
        where(q, [j, _s], j.posting_date >= ^date)

      {:to, date}, q ->
        where(q, [j, _s], j.posting_date <= ^date)

      {:on, date}, q ->
        where(q, [j, _s], j.posting_date == ^date)

      # Row-write time, not posting date. Distinct filters because they are
      # genuinely different questions — HCS's statement windows use
      # `inserted_at`, and migrating them onto `posting_date` would silently
      # change which activity a statement covers.
      {:inserted_from, ts}, q ->
        where(q, [j, _s], j.inserted_at >= ^ts)

      {:inserted_to, ts}, q ->
        where(q, [j, _s], j.inserted_at <= ^ts)

      # Some readers identify a posting family by key prefix rather than by
      # event type — COL's recoveries are keyed "RECOVERY-<ref>". Kept as an
      # explicit filter rather than encouraging callers to build their own
      # LIKE patterns against the new schema.
      # Exact key. Used by the duplicate guards — `PaymentIntake` and TRAMS's
      # posting cycle both ask "has this reference already posted?" before
      # writing. They are the one class of reader that must not be migrated
      # before the backfill: a guard that cannot see history stops guarding.
      {:idempotency_key, keys}, q when is_list(keys) ->
        where(q, [_j, s], s.idempotency_key in ^keys)

      {:idempotency_key, key}, q ->
        where(q, [_j, s], s.idempotency_key == ^key)

      {:idempotency_key_prefix, prefix}, q ->
        where(q, [_j, s], like(s.idempotency_key, ^(prefix <> "%")))

      {:gl_account, account}, q ->
        where(q, [j, _s], j.dr_gl_account == ^account or j.cr_gl_account == ^account)

      {:limit, _}, q ->
        q

      {:as_uuid, _}, q ->
        q

      {key, _}, _q ->
        raise ArgumentError, "unknown LedgerQuery filter: #{inspect(key)}"
    end)
  end
end
