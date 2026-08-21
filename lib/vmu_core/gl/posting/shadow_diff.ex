defmodule VmuCore.Posting.ShadowDiff do
  @moduledoc """
  Compares the legacy ledger against the shadow engine (GL Phase B3).

  This is where Phase B earns its keep. Running both implementations proves
  nothing on its own — the diff is what establishes equivalence, on real
  traffic, before anything is cut over.

  ## The join

  Both sides carry a unique `idempotency_key`, so that is the join. Every
  legacy row in `cms_ledger_entries` should have exactly one matching
  `posting_sets` row once shadow mode has been on for a while.

  ## Classifications

  | Status | Meaning |
  |---|---|
  | `:match` | Same accounts, amount and dates |
  | `:mismatch` | Both present, but they disagree — the finding that matters |
  | `:missing_shadow` | Legacy posted, engine did not. Either shadow was off when it was written, or the engine refused it |
  | `:orphan_shadow` | The **shadow** posted with no legacy row. Should not happen while legacy is authoritative |

  `:missing_shadow` is expected for anything written before shadow mode was
  switched on, which is why the `:since` window exists — comparing against
  history the engine never saw would drown the real findings.

  ## Only shadow-origin sets are compared

  `posting_sets` also holds rows the engine wrote directly — demo seed data,
  and eventually Phase C call sites that have been cut over. Those legitimately
  have no legacy counterpart, and counting them as orphans makes the headline
  number meaningless: 18 seeded demo rows reported as orphans on the first real
  run, which reads as 18 defects.

  So the comparison considers only sets whose `source_module` marks them as
  shadow mirrors (`"shadow:..."`). Pass `include_all: true` to see everything,
  which is useful when checking that a Phase C cutover left nothing behind.
  """

  @shadow_source_prefix "shadow:"

  import Ecto.Query, warn: false

  alias VmuCore.Repo
  alias VmuCore.CMS.LedgerEntry
  alias VmuCore.Posting.{JournalEntry, PostingSet}

  @type row :: %{
          status: :match | :mismatch | :missing_shadow | :orphan_shadow,
          idempotency_key: String.t(),
          differences: [String.t()],
          legacy: map() | nil,
          shadow: map() | nil
        }

  @doc """
  Compares both sides.

  Options:

    * `:since` — only compare legacy rows posted on or after this date.
      Strongly recommended: without it, every row written before shadow mode
      was enabled reports as `:missing_shadow`.
    * `:limit` — cap the **legacy** rows examined (default 500). Shadow rows
      are then fetched for exactly those keys, plus any shadow-only keys in
      the window, so the two sides always correspond. Limiting each side
      independently produced false orphans and false missings once there were
      more rows than the limit — found while verifying the WALLET cutover
      against 1,200 postings
    * `:status` — return only one classification
    * `:include_all` — compare every posting set, not just shadow-origin ones.
      Off by default; see the moduledoc
  """
  @spec compare(keyword()) :: [row()]
  def compare(opts \\ []) do
    since = opts[:since]
    limit = opts[:limit] || 500

    legacy = legacy_rows(since, limit)

    # Drive from the legacy keys so both sides describe the same postings. The
    # shadow side is then everything matching those keys, plus shadow rows in
    # the window that have no legacy counterpart at all (genuine orphans).
    shadow = shadow_rows(since, Map.keys(legacy), limit, opts[:include_all] == true)

    legacy_keys = MapSet.new(Map.keys(legacy))
    shadow_keys = MapSet.new(Map.keys(shadow))

    matched =
      legacy_keys
      |> MapSet.intersection(shadow_keys)
      |> Enum.map(fn key -> compare_pair(key, legacy[key], shadow[key]) end)

    missing =
      legacy_keys
      |> MapSet.difference(shadow_keys)
      |> Enum.map(fn key ->
        %{status: :missing_shadow, idempotency_key: key, differences: [], legacy: legacy[key], shadow: nil}
      end)

    orphans =
      shadow_keys
      |> MapSet.difference(legacy_keys)
      |> Enum.map(fn key ->
        %{status: :orphan_shadow, idempotency_key: key, differences: [], legacy: nil, shadow: shadow[key]}
      end)

    (matched ++ missing ++ orphans)
    |> then(fn rows ->
      case opts[:status] do
        nil -> rows
        status -> Enum.filter(rows, &(&1.status == status))
      end
    end)
    |> Enum.sort_by(&{severity(&1.status), &1.idempotency_key})
  end

  @doc """
  Headline counts. This is the number to watch during Phase B: cutover is
  defensible when `mismatch` and `orphan_shadow` are zero and `match` is a
  meaningful sample of real traffic.
  """
  @spec summary(keyword()) :: map()
  def summary(opts \\ []) do
    rows = compare(opts)

    counts = Enum.frequencies_by(rows, & &1.status)

    %{
      total: length(rows),
      # How many sets shadow mode has actually written. Distinguishes "the diff
      # is clean" from "shadow mode was never switched on" — both show zero
      # mismatches, and only one of them means anything.
      shadow_written: Repo.aggregate(shadow_written_query(opts[:since]), :count),
      match: Map.get(counts, :match, 0),
      mismatch: Map.get(counts, :mismatch, 0),
      missing_shadow: Map.get(counts, :missing_shadow, 0),
      orphan_shadow: Map.get(counts, :orphan_shadow, 0),
      equivalent?: Map.get(counts, :mismatch, 0) == 0 and Map.get(counts, :orphan_shadow, 0) == 0
    }
  end

  # ---------------------------------------------------------------------------

  # How many sets shadow mode has actually written. Distinguishes "the diff is
  # clean" from "shadow mode was never switched on".
  defp shadow_written_query(since) do
    PostingSet
    |> where([s], like(s.source_module, ^(@shadow_source_prefix <> "%")))
    |> then(fn q -> if since, do: where(q, [s], s.posting_date >= ^since), else: q end)
  end

  defp compare_pair(key, legacy, shadow) do
    differences =
      []
      |> diff(:dr_account, legacy.gl_account_dr, shadow.dr_gl_account)
      |> diff(:cr_account, legacy.gl_account_cr, shadow.cr_gl_account)
      |> diff_decimal(:amount, legacy.dr_amount, shadow.amount)
      |> diff(:posting_date, legacy.posting_date, shadow.posting_date)
      |> diff(:currency, legacy.currency, shadow.currency)

    %{
      status: if(differences == [], do: :match, else: :mismatch),
      idempotency_key: key,
      differences: Enum.reverse(differences),
      legacy: legacy,
      shadow: shadow
    }
  end

  defp diff(acc, _field, same, same), do: acc
  defp diff(acc, field, legacy, shadow), do: ["#{field}: legacy #{inspect(legacy)} vs shadow #{inspect(shadow)}" | acc]

  defp diff_decimal(acc, field, legacy, shadow) do
    cond do
      is_nil(legacy) or is_nil(shadow) ->
        ["#{field}: legacy #{inspect(legacy)} vs shadow #{inspect(shadow)}" | acc]

      Decimal.equal?(legacy, shadow) ->
        acc

      true ->
        ["#{field}: legacy #{legacy} vs shadow #{shadow}" | acc]
    end
  end

  defp legacy_rows(since, limit) do
    LedgerEntry
    |> then(fn q -> if since, do: where(q, [e], e.posting_date >= ^since), else: q end)
    |> order_by([e], desc: e.posting_date)
    |> limit(^limit)
    |> select([e], %{
      idempotency_key: e.idempotency_key,
      transaction_code: e.transaction_code,
      gl_account_dr: e.gl_account_dr,
      gl_account_cr: e.gl_account_cr,
      dr_amount: e.dr_amount,
      currency: e.currency,
      posting_date: e.posting_date
    })
    |> Repo.all()
    |> Map.new(&{&1.idempotency_key, &1})
  end

  # Joined to the journal entry rather than read off the set, because the
  # journal is where the account pair lives — the set records the execution,
  # the journal records the movement.
  defp shadow_rows(since, legacy_keys, limit, include_all?) do
    PostingSet
    |> join(:inner, [s], j in JournalEntry, on: j.posting_set_id == s.id)
    |> then(fn q -> if since, do: where(q, [s, _j], s.posting_date >= ^since), else: q end)
    |> then(fn q ->
      if include_all?,
        do: q,
        else: where(q, [s, _j], like(s.source_module, ^(@shadow_source_prefix <> "%")))
    end)
    # Everything matching a legacy key in this window, plus anything with no
    # legacy row at all. The second half is what surfaces real orphans; the
    # first is what stops the two windows drifting apart.
    |> where(
      [s, _j],
      s.idempotency_key in ^legacy_keys or
        not exists(
          from(e in LedgerEntry,
            where: e.idempotency_key == parent_as(:set).idempotency_key,
            select: 1
          )
        )
    )
    |> from(as: :set)
    |> order_by([s, _j], desc: s.posting_date)
    |> limit(^(limit * 2))
    |> select([s, j], %{
      idempotency_key: s.idempotency_key,
      event_type: s.event_type,
      product: s.product,
      dr_gl_account: j.dr_gl_account,
      cr_gl_account: j.cr_gl_account,
      amount: j.amount,
      currency: j.currency,
      posting_date: s.posting_date,
      gl_date: s.gl_date,
      source_module: s.source_module
    })
    |> Repo.all()
    |> Map.new(&{&1.idempotency_key, &1})
  end

  # Mismatches first — they are the only class that means the engine is wrong.
  defp severity(:mismatch), do: 0
  defp severity(:orphan_shadow), do: 1
  defp severity(:missing_shadow), do: 2
  defp severity(:match), do: 3
end
