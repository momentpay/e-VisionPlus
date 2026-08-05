defmodule VmuCore.Posting.RuleEngineTest do
  @moduledoc """
  End-to-end tests for the posting engine, against real Postgres.

  No mocked repo — `CLAUDE.md` requires a real test database, and most of what
  is worth testing here (the deferred balance trigger, the period exclusion
  constraint, referential integrity on account codes) exists in the database
  and would simply be absent from a mock.
  """
  use VmuCore.DataCase, async: false

  import Ecto.Query

  alias VmuCore.GL.{ChartOfAccounts, LedgerEntry, Periods}
  alias VmuCore.Posting.{JournalEntry, PostingEntry, PostingLeg, PostingSet, RuleEngine, Rules}

  @sys "TS01"
  @bank "TB01"

  setup do
    # The test environment sets `on_closed_period: :allow` globally so migrated
    # readers see mirrored postings (config/test.exs). These tests assert the
    # opposite behaviour, so they pin the policy explicitly rather than
    # inheriting whatever the environment happens to set.
    previous = Application.get_env(:vmu_core, RuleEngine, [])
    Application.put_env(:vmu_core, RuleEngine, on_closed_period: :quarantine)
    on_exit(fn -> Application.put_env(:vmu_core, RuleEngine, previous) end)

    ChartOfAccounts.seed!()
    Rules.seed!()

    today = ~D[2026-08-15]
    {:ok, _} = Periods.open_banking_date(@sys, @bank, today)

    period =
      case Periods.period_for(@sys, @bank, today) do
        nil ->
          {:ok, p} = Periods.create_period(@sys, @bank, ~D[2026-08-01], ~D[2026-08-31])
          p

        existing ->
          existing
      end

    %{today: today, period: period}
  end

  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        event_type: "DEPOSIT",
        product: "DEBIT",
        account_ref: "debit-acct-1",
        amount: Decimal.new("250.00"),
        idempotency_key: "test:#{System.unique_integer([:positive])}",
        sys_id: @sys,
        bank_id: @bank,
        bindings: %{"channel" => "ATM"}
      },
      overrides
    )
  end

  describe "execute/1 happy path" do
    test "writes a balanced set, entry, two legs, a journal entry and a GL entry", %{today: today} do
      assert {:ok, set} = RuleEngine.execute(event())

      assert set.status == "POSTED"
      assert set.sys_id == @sys
      assert set.gl_date == today
      assert set.narrative == "Debit account funding: ATM"

      entries = Repo.all(from e in PostingEntry, where: e.posting_set_id == ^set.id)
      assert [entry] = entries
      assert Decimal.equal?(entry.amount, Decimal.new("250.00"))

      legs = Repo.all(from l in PostingLeg, where: l.posting_entry_id == ^entry.id)
      assert length(legs) == 2

      # Reconciled chart: cash clearing 3005 debited, debit liability 2004 credited.
      assert %{"debit" => "3005", "credit" => "2004"} =
               Map.new(legs, &{&1.direction, &1.gl_account})

      sum =
        Enum.reduce(legs, Decimal.new(0), fn l, acc ->
          Decimal.add(acc, PostingLeg.signed_amount(l))
        end)

      assert Decimal.equal?(sum, Decimal.new(0)), "legs must net to zero"

      assert je = Repo.one(from j in JournalEntry, where: j.posting_set_id == ^set.id)
      assert je.dr_gl_account == "3005"
      assert je.cr_gl_account == "2004"
      assert je.account_ref == "debit-acct-1"

      assert gl =
               Repo.one(
                 from l in LedgerEntry,
                   where: l.sys_id == ^@sys and l.gl_date == ^today and l.dr_account == "3005"
               )

      assert Decimal.equal?(gl.amount, Decimal.new("250.00"))
      assert gl.entry_count == 1
      assert gl.generation == 1
      assert gl.status == "OPEN"
    end

    test "stored value credits a liability, never an expense" do
      for {product, liability} <- [{"DEBIT", "2004"}, {"PREPAID", "2005"}, {"WALLET", "2006"}] do
        {:ok, set} = RuleEngine.execute(event(%{product: product, event_type: "DEPOSIT"}))

        je = Repo.one(from j in JournalEntry, where: j.posting_set_id == ^set.id)
        assert je.cr_gl_account == liability

        account = ChartOfAccounts.get(liability)
        assert account.account_class == "liability", "#{product} must credit a liability"
      end
    end
  end

  describe "GL consolidation" do
    test "several executions on one date accumulate into one GL entry", %{today: today} do
      for _ <- 1..3, do: {:ok, _} = RuleEngine.execute(event(%{amount: Decimal.new("100.00")}))

      gl =
        Repo.one(
          from l in LedgerEntry,
            where:
              l.sys_id == ^@sys and l.gl_date == ^today and
                l.dr_account == "3005" and l.cr_account == "2004"
        )

      assert gl.entry_count == 3
      assert Decimal.equal?(gl.amount, Decimal.new("300.00"))
    end

    test "activity after a GL entry closes opens a new generation, not a reopened entry",
         %{today: today} do
      {:ok, _} = RuleEngine.execute(event(%{amount: Decimal.new("100.00")}))

      gl = Repo.one(from l in LedgerEntry, where: l.gl_date == ^today and l.dr_account == "3005")
      {:ok, _} = gl |> LedgerEntry.changeset(%{status: "CLOSED"}) |> Repo.update()

      {:ok, _} = RuleEngine.execute(event(%{amount: Decimal.new("50.00")}))

      generations =
        Repo.all(
          from l in LedgerEntry,
            where: l.gl_date == ^today and l.dr_account == "3005",
            order_by: l.generation,
            select: {l.generation, l.status, l.amount}
        )

      assert [{1, "CLOSED", _}, {2, "OPEN", second}] = generations
      assert Decimal.equal?(second, Decimal.new("50.00"))
    end
  end

  describe "GL consolidation is an aggregate of the journal" do
    # The invariant that the lost-update bug violated: `gl_ledger_entries` is a
    # pure aggregate of `journal_entries`, so the two must always total the same.
    # The old read-add-write `consolidate/4` broke it silently — journal entries
    # were correct while the GL under-reported, which is the direction that
    # matters, because the customer-facing view stays right and only the bank's
    # books are wrong.
    test "the GL total equals the journal total over a run of postings" do
      amounts = for n <- 1..25, do: Decimal.new("#{n}.37")

      for amount <- amounts do
        assert {:ok, _} = RuleEngine.execute(event(%{amount: amount}))
      end

      journal_total = Repo.one(from j in JournalEntry, select: coalesce(sum(j.amount), 0))
      gl_total = Repo.one(from l in LedgerEntry, select: coalesce(sum(l.amount), 0))
      expected = Enum.reduce(amounts, Decimal.new(0), &Decimal.add(&2, &1))

      assert Decimal.equal?(journal_total, expected)
      assert Decimal.equal?(gl_total, expected), "GL must aggregate the journal exactly"

      gl = Repo.one(from l in LedgerEntry, where: l.dr_account == "3005" and l.cr_account == "2004")
      assert gl.entry_count == 25
    end

    test "entry_count and amount stay in step when postings interleave products" do
      for {product, n} <- [{"DEBIT", 5}, {"PREPAID", 3}, {"WALLET", 4}], _ <- 1..n do
        assert {:ok, _} = RuleEngine.execute(event(%{product: product, amount: Decimal.new("10.00")}))
      end

      journal_total = Repo.one(from j in JournalEntry, select: coalesce(sum(j.amount), 0))
      gl_total = Repo.one(from l in LedgerEntry, select: coalesce(sum(l.amount), 0))
      gl_count = Repo.one(from l in LedgerEntry, select: coalesce(sum(l.entry_count), 0))

      assert Decimal.equal?(journal_total, gl_total)
      assert gl_count == 12
    end
  end

  describe "idempotency" do
    test "replaying a key returns the original set without writing again" do
      key = "test:replay:#{System.unique_integer([:positive])}"

      assert {:ok, first} = RuleEngine.execute(event(%{idempotency_key: key}))
      assert {:ok, :duplicate, second} = RuleEngine.execute(event(%{idempotency_key: key}))

      assert first.id == second.id
      assert 1 == Repo.aggregate(from(s in PostingSet, where: s.idempotency_key == ^key), :count)
    end
  end

  describe "the period gate" do
    test "a posting into a closed period is quarantined, not written", %{period: period} do
      {:ok, _} = Periods.close_period(period, "test")

      assert {:error, :quarantined, exception} = RuleEngine.execute(event())
      assert exception.reason == "GL_DATE_IN_CLOSED_PERIOD"
      refute exception.resolved

      assert 0 == Repo.aggregate(from(s in PostingSet, where: s.sys_id == ^@sys), :count)
    end

    test "a posting with no period at all is quarantined" do
      assert {:error, :quarantined, exception} =
               RuleEngine.execute(event(%{gl_date: ~D[2020-01-01]}))

      assert exception.reason == "NO_OPEN_PERIOD"
    end

    test "a posting after the banking day closes is quarantined" do
      {:ok, _} = Periods.close_banking_date(@sys, @bank)

      assert {:error, :quarantined, exception} = RuleEngine.execute(event())
      assert exception.reason == "BANKING_DATE_CLOSED"
    end
  end

  describe "refusals" do
    test "an unknown event/product combination is refused" do
      assert {:error, :no_rule} = RuleEngine.execute(event(%{event_type: "SETTLEMENT"}))
    end

    test "a non-positive amount is refused before anything is written" do
      assert {:error, :invalid_amount} = RuleEngine.execute(event(%{amount: Decimal.new("0")}))
      assert {:error, :invalid_amount} = RuleEngine.execute(event(%{amount: Decimal.new("-5")}))
    end

    test "an institution with no banking date is refused" do
      assert {:error, :no_banking_date} =
               RuleEngine.execute(event(%{sys_id: "ZZZZ", bank_id: "ZZZZ"}))
    end
  end

  describe "reversal date semantics" do
    test "a reversal keeps the original posting_date but takes today's gl_date" do
      {:ok, original} =
        RuleEngine.execute(event(%{posting_date: ~D[2026-08-05], gl_date: ~D[2026-08-05]}))

      attrs = PostingSet.reversal_attrs(original, ~D[2026-08-20], "rev:#{original.idempotency_key}")

      assert attrs.posting_date == ~D[2026-08-05], "must land in the original period"
      assert attrs.gl_date == ~D[2026-08-20], "books record the correction when made"
      assert attrs.reverses_id == original.id
      assert attrs.sys_id == @sys
    end
  end
end
