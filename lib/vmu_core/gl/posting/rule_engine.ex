defmodule VmuCore.Posting.RuleEngine do
  @moduledoc """
  Turns a business event into balanced financial records (GL Phase A5).

  This is the piece that joins the module together:

      business event
        → posting rule lookup          (Posting.Rules)
        → GL date validation           (GL.Periods — refuses closed periods)
        → PostingSet + Entry + Legs    (double entry, DB-enforced)
        → JournalEntry                 (the subledger)
        → GL ledger consolidation      (per account correspondence + GL date)

  All of it inside one `Repo.transaction/1`. The deferred balance trigger runs
  at COMMIT, so a set that fails to balance takes the whole thing down rather
  than leaving a half-written execution behind.

  ## Idempotency

  `idempotency_key` is unique on `posting_sets`. A replay returns
  `{:ok, :duplicate, existing_set}` rather than an error, because retrying an
  Oban job must be safe and must not look like a failure.

  ## Refusals are recorded, not raised

  A posting whose GL date falls in a closed period returns
  `{:error, :quarantined, exception}` and a row lands in
  `gl_posting_exceptions`. Losing a real financial event is worse than
  recording it as an exception — see `GL.PostingException`.

  ## Closed-period policy (Phase C0)

      config :vmu_core, VmuCore.Posting.RuleEngine,
        on_closed_period: :quarantine   # :quarantine (default) | :allow

  `:quarantine` refuses the posting. That is the correct end state and what
  Phase B ran with.

  `:allow` posts anyway **and still records the exception**. It exists because
  `InternalGlPoster` has no concept of an accounting period and accepts
  back-dated postings silently — under cutover, where an engine failure aborts
  the real posting, `:quarantine` would start failing EOD re-runs that
  previously succeeded. `:allow` is behaviour-preserving relative to legacy
  while no longer being silent about it.

  Tightening to `:quarantine` is then a deliberate control decision, separate
  from the cutover itself. The operational rule it depends on is WAY4's own:
  do not close a period until EOD has run for every day in it.

  ## Not yet wired

  Nothing calls this. Phase B shadow-runs it alongside `InternalGlPoster` and
  diffs the output; Phase C moves call sites onto it one at a time.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Multi
  alias VmuCore.Repo
  alias VmuCore.GL.{LedgerEntry, Periods}
  alias VmuCore.Posting.{JournalEntry, PostingEntry, PostingLeg, PostingSet, Rule, Rules}

  @type event :: %{
          required(:event_type) => String.t(),
          required(:product) => String.t(),
          required(:account_ref) => String.t(),
          required(:amount) => Decimal.t(),
          required(:idempotency_key) => String.t(),
          required(:sys_id) => String.t(),
          required(:bank_id) => String.t(),
          optional(:currency) => String.t(),
          optional(:posting_date) => Date.t(),
          optional(:transaction_date) => Date.t(),
          optional(:gl_date) => Date.t(),
          optional(:bindings) => map(),
          optional(:source_module) => String.t(),
          optional(:correlation_id) => String.t(),
          optional(:accounts) => {String.t(), String.t()},
          optional(:narrative) => String.t()
        }

  @doc """
  Executes one business event.

  Returns:

    * `{:ok, posting_set}` — written and balanced
    * `{:ok, :duplicate, posting_set}` — this key was already executed
    * `{:error, :no_rule}` — no posting rule for `{event_type, product}`
    * `{:error, :quarantined, exception}` — refused by the period gate
    * `{:error, reason}` — validation or database failure
  """
  @spec execute(event()) ::
          {:ok, PostingSet.t()}
          | {:ok, :duplicate, PostingSet.t()}
          | {:error, :no_rule}
          | {:error, :quarantined, term()}
          | {:error, term()}
  def execute(event) do
    with {:ok, event} <- normalise(event),
         :ok <- check_not_duplicate(event),
         {:ok, rule} <- Rules.fetch(event.event_type, event.product),
         {:ok, _period} <- validate_or_quarantine(event) do
      write(event, rule)
    else
      {:duplicate, set} -> {:ok, :duplicate, set}
      other -> other
    end
  end

  # ---------------------------------------------------------------------------
  # Steps
  # ---------------------------------------------------------------------------

  defp normalise(event) do
    banking = Periods.banking_date(event.sys_id, event.bank_id)

    # The four dates. posting_date defaults to the banking date; gl_date
    # defaults to posting_date. A reversal supplies them explicitly and they
    # legitimately differ — that case is the reason these are separate fields.
    banking_date = banking && banking.current_banking_date
    posting_date = event[:posting_date] || banking_date

    cond do
      is_nil(banking_date) ->
        {:error, :no_banking_date}

      is_nil(event[:amount]) or Decimal.compare(event.amount, 0) != :gt ->
        {:error, :invalid_amount}

      true ->
        {:ok,
         event
         |> Map.put_new(:currency, "AED")
         |> Map.put_new(:bindings, %{})
         |> Map.put_new(:source_module, "RuleEngine")
         |> Map.put(:posting_date, posting_date)
         |> Map.put(:gl_date, event[:gl_date] || posting_date)
         |> Map.put(:banking_date, banking_date)}
    end
  end

  defp check_not_duplicate(event) do
    case Repo.get_by(PostingSet, idempotency_key: event.idempotency_key) do
      nil -> :ok
      set -> {:duplicate, set}
    end
  end

  defp validate_or_quarantine(event) do
    case Periods.validate_gl_date(event.sys_id, event.bank_id, event.gl_date) do
      {:ok, period} ->
        {:ok, period}

      {:error, reason} ->
        # The exception is recorded either way. The policy decides only whether
        # the posting is also refused — never whether the violation is visible.
        {:ok, exception} =
          Periods.quarantine(event.sys_id, event.bank_id, event.gl_date, reason,
            banking_date: event.banking_date,
            detail:
              "#{event.event_type}/#{event.product} amount=#{event.amount} " <>
                "key=#{event.idempotency_key}" <>
                if(closed_period_policy() == :allow, do: " [ALLOWED by policy]", else: "")
          )

        case closed_period_policy() do
          :allow ->
            Logger.warning(
              "[GL] #{event.idempotency_key} posted into a closed period " <>
                "(#{reason}, gl_date=#{event.gl_date}) — allowed by policy, exception recorded"
            )

            {:ok, :no_period}

          _ ->
            Logger.warning(
              "[GL] quarantined #{event.idempotency_key}: #{reason} gl_date=#{event.gl_date}"
            )

            {:error, :quarantined, exception}
        end
    end
  end

  @doc "Current closed-period policy. Defaults to `:quarantine`."
  @spec closed_period_policy() :: :quarantine | :allow
  def closed_period_policy do
    :vmu_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:on_closed_period, :quarantine)
  end

  defp write(event, rule) do
    # `:accounts` overrides the rule's pair. Used only by the history backfill
    # (`priv/repo/backfill_gl_history.exs`), which must reproduce each legacy
    # row's **stored** account pair rather than what today's rule would emit —
    # otherwise it would silently "correct" history, including the 16 rows
    # Phase 4A already remapped in place.
    {dr, cr} = event[:accounts] || Rule.pair(rule)
    narrative = event[:narrative] || Rule.render_narrative(rule, event.bindings)

    Multi.new()
    |> Multi.insert(:set, set_changeset(event, rule, narrative))
    |> Multi.insert(:entry, fn %{set: set} ->
      PostingEntry.changeset(%PostingEntry{}, %{
        posting_set_id: set.id,
        sequence: 1,
        amount: event.amount,
        currency: event.currency,
        narrative: narrative
      })
    end)
    |> Multi.insert(:leg_dr, fn %{entry: entry} ->
      leg_changeset(entry, "debit", dr, event.currency)
    end)
    |> Multi.insert(:leg_cr, fn %{entry: entry} ->
      leg_changeset(entry, "credit", cr, event.currency)
    end)
    |> Multi.insert(:journal, fn %{set: set, entry: entry} ->
      JournalEntry.changeset(%JournalEntry{}, %{
        posting_set_id: set.id,
        posting_entry_id: entry.id,
        account_ref: set.account_ref,
        product: set.product,
        dr_gl_account: dr,
        cr_gl_account: cr,
        amount: entry.amount,
        currency: entry.currency,
        transaction_date: set.transaction_date,
        posting_date: set.posting_date,
        gl_date: set.gl_date,
        narrative: narrative
      })
    end)
    |> Multi.run(:consolidate, fn _repo, %{set: set} ->
      consolidate(set, dr, cr, event.amount)
    end)
    |> Multi.update(:posted, fn %{set: set} ->
      PostingSet.changeset(set, %{status: "POSTED"})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{posted: set}} -> {:ok, set}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp set_changeset(event, rule, narrative) do
    PostingSet.changeset(%PostingSet{}, %{
      event_type: event.event_type,
      product: event.product,
      account_ref: event.account_ref,
      idempotency_key: event.idempotency_key,
      currency: event.currency,
      total_amount: event.amount,
      transaction_date: event[:transaction_date],
      posting_date: event.posting_date,
      gl_date: event.gl_date,
      banking_date: event.banking_date,
      narrative: narrative,
      source_module: event.source_module,
      correlation_id: event[:correlation_id],
      posting_rule_id: rule.id,
      sys_id: event.sys_id,
      bank_id: event.bank_id,
      status: "DRAFT"
    })
  end

  defp leg_changeset(entry, direction, account, currency) do
    PostingLeg.changeset(%PostingLeg{}, %{
      posting_entry_id: entry.id,
      direction: direction,
      gl_account: account,
      amount: entry.amount,
      currency: currency
    })
  end

  # ---------------------------------------------------------------------------
  # GL consolidation
  # ---------------------------------------------------------------------------

  # One GL ledger entry per (institution, gl_date, dr, cr, currency,
  # generation). Journal entries accumulate into it — this is the bank's-books
  # view, where journal entries are the customer's-account view.
  #
  # `generation` implements WAY4's rule that once an entry is CLOSED, further
  # activity for the same correspondence on the same date opens a *second*
  # entry rather than reopening the first. Without it, "closed" would either be
  # a lie or would have to reject late activity outright.
  # ## Why this is an upsert and not a read-then-update
  #
  # It accumulates in the **database**, with `ON CONFLICT DO UPDATE SET
  # amount = gl_ledger_entries.amount + EXCLUDED.amount`, rather than reading
  # the row, adding in Elixir and writing the total back.
  #
  # The read-then-update version lost writes. Two postings into the same
  # correspondence on the same date would both read the same `existing.amount`,
  # both compute `existing + their own`, and the second update would overwrite
  # the first — the second posting's amount landing in the GL and the first
  # one's silently vanishing. Nothing raised: the journal entry was written
  # either way, so the customer-facing view stayed correct while the bank's
  # books quietly under-reported.
  #
  # Found 2026-08-05 building the trial balance, which is exactly the report
  # that makes it visible: `journal_entries` summed to 1,737,568.84 against
  # `gl_ledger_entries`' 1,728,263.33, a 9,305.51 shortfall over 19 postings.
  # Every one of them was dated 2026-08-03 — the only day this database had
  # concurrent posting traffic.
  #
  # The unique index `gl_ledger_entries_correspondence_idx` is what makes the
  # upsert well-defined, and it already existed.
  defp consolidate(set, dr, cr, amount) do
    generation = next_open_generation(set, dr, cr)

    # `gl_ledger_entries` timestamps are `:utc_datetime_usec` — no truncation.
    now = DateTime.utc_now()

    entry = %{
      sys_id: set.sys_id,
      bank_id: set.bank_id,
      gl_date: set.gl_date,
      dr_account: dr,
      cr_account: cr,
      currency: set.currency,
      amount: amount,
      entry_count: 1,
      generation: generation,
      status: "OPEN",
      inserted_at: now,
      updated_at: now
    }

    {_count, _} =
      Repo.insert_all(
        LedgerEntry,
        [entry],
        on_conflict:
          from(l in LedgerEntry,
            update: [inc: [amount: ^amount, entry_count: 1], set: [updated_at: ^now]]
          ),
        conflict_target: [
          :sys_id,
          :bank_id,
          :gl_date,
          :dr_account,
          :cr_account,
          :currency,
          :generation
        ]
      )

    {:ok, :consolidated}
  end

  defp next_open_generation(set, dr, cr) do
    latest =
      Repo.one(
        from(l in LedgerEntry,
          where:
            l.sys_id == ^set.sys_id and l.bank_id == ^set.bank_id and
              l.gl_date == ^set.gl_date and l.dr_account == ^dr and
              l.cr_account == ^cr and l.currency == ^set.currency,
          order_by: [desc: l.generation],
          limit: 1
        )
      )

    case latest do
      nil -> 1
      %LedgerEntry{status: "OPEN", generation: g} -> g
      %LedgerEntry{generation: g} -> g + 1
    end
  end

end
