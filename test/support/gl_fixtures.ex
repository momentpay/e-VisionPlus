defmodule VmuCore.GLFixtures do
  @moduledoc """
  Fixtures for tests whose subject reads or writes the posting engine.

  ## Why these are needed

  `gl_accounts` and `posting_rules` are reference data seeded by
  `priv/repo/seed_gl.exs`, not by a migration. Inside the Ecto sandbox every
  test starts from an empty pair of tables, and `Posting.RuleEngine` refuses a
  posting it has no rule for. Before GL Phase C2 that was invisible: no test
  read the posting tables, so a shadow write that silently found no rule
  changed nothing anyone asserted on.

  It is visible now. A migrated reader — `ChargeOffRecovery.total_recovered/1`
  is the first — returns zero rather than failing, because `LedgerQuery` sums
  an empty set. That is a passing-looking test measuring nothing, which is why
  this is a shared fixture rather than three lines copied into each test that
  needs it.

  Tests create their institution on the fly, so `open_institution!/2` also
  supplies what the period gate requires: an open banking date and a period
  covering it. Production has both from `seed_gl.exs`.
  """

  alias VmuCore.GL.{ChartOfAccounts, Periods}
  alias VmuCore.Posting.Rules

  @doc """
  Seeds the chart of accounts and the posting rules.

  Both seeders are idempotent, so calling this in a `setup` block that runs per
  test is safe.
  """
  @spec seed_posting_engine!() :: :ok
  def seed_posting_engine! do
    ChartOfAccounts.seed!()
    Rules.seed!()
    :ok
  end

  @doc """
  Opens a banking date and an accounting period for an institution, so the
  period gate admits postings dated `on`.

  Idempotent in the period case: `gl_periods` carries a GiST exclusion
  constraint against overlapping ranges, so a second covering period is not
  created if one already exists.
  """
  @spec open_institution!(String.t(), String.t(), Date.t()) :: :ok
  def open_institution!(sys_id, bank_id, on \\ Date.utc_today()) do
    {:ok, _} = Periods.open_banking_date(sys_id, bank_id, on)

    if is_nil(Periods.period_for(sys_id, bank_id, on)) do
      {:ok, _} =
        Periods.create_period(sys_id, bank_id, Date.beginning_of_month(on), Date.end_of_month(on))
    end

    :ok
  end
end
