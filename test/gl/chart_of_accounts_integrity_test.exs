defmodule VmuCore.GL.ChartOfAccountsIntegrityTest do
  @moduledoc """
  Guards the invariants Phase 4A established.

  These are cheap to run and expensive to lose. Every one of them corresponds
  to a defect that was actually found in this codebase, not a hypothetical:

    * two modules defining conflicting meanings for the same account code
    * an account code used by live postings that no chart contained (5003)
    * an account picked for a new purpose while another module already used it
      (3002)
    * seed rows violating double entry because `insert_all` bypasses the
      changeset
  """
  use VmuCore.DataCase, async: false

  alias VmuCore.GL.{Account, ChartOfAccounts}
  alias VmuCore.Posting.{Rule, Rules}

  setup do
    ChartOfAccounts.seed!()
    Rules.seed!()
    :ok
  end

  describe "chart of accounts" do
    test "every account's normal_balance is derived from its class" do
      for account <- ChartOfAccounts.all(active: :all) do
        assert account.normal_balance == Account.normal_balance_for(account.account_class),
               "#{account.code} #{account.name}: #{account.account_class} must be " <>
                 "#{Account.normal_balance_for(account.account_class)}-normal, " <>
                 "got #{account.normal_balance}"
      end
    end

    test "stored-value balances are liabilities, not expenses (VMU-ADR-005)" do
      for code <- ~w[2004 2005 2006] do
        account = ChartOfAccounts.get(code)
        assert account, "#{code} must exist — stored value needs a liability account"
        assert account.account_class == "liability"
        assert account.normal_balance == "credit"
      end
    end

    test "no account code carries two meanings across owner modules" do
      duplicates =
        ChartOfAccounts.all(active: :all)
        |> Enum.group_by(& &1.code)
        |> Enum.filter(fn {_code, accounts} -> length(accounts) > 1 end)

      assert duplicates == [], "codes defined more than once: #{inspect(duplicates)}"
    end

    test "no unresolved legacy conflicts remain" do
      conflicts = ChartOfAccounts.conflicts()

      assert conflicts == [],
             "still conflicted: " <>
               Enum.map_join(conflicts, ", ", &"#{&1.code} #{&1.name}")
    end
  end

  describe "posting rules" do
    test "every rule's accounts exist in the chart" do
      for rule <- Rules.all() do
        {dr, cr} = Rule.pair(rule)

        assert ChartOfAccounts.get(dr), "#{rule.product}/#{rule.event_type}: dr #{dr} not in chart"
        assert ChartOfAccounts.get(cr), "#{rule.product}/#{rule.event_type}: cr #{cr} not in chart"
      end
    end

    test "no rule debits and credits the same account" do
      for rule <- Rules.all() do
        {dr, cr} = Rule.pair(rule)
        refute dr == cr, "#{rule.product}/#{rule.event_type} posts #{dr} to itself"
      end
    end

    test "no rule is still awaiting Phase C cutover" do
      pending = Rules.pending_cutover()

      assert pending == [],
             "rules still on legacy accounts: " <>
               Enum.map_join(pending, ", ", &"#{&1.product}/#{&1.event_type}")
    end

    test "wallet has load and withdrawal only — it has no adjustment posting path" do
      events = Rules.all(product: "WALLET") |> Enum.map(& &1.event_type) |> Enum.sort()

      assert events == ["DEPOSIT", "WITHDRAWAL"],
             "wallet rules must mirror InternalGlPoster, which has no " <>
               "post_wallet_adjustment clauses. Got: #{inspect(events)}"
    end
  end

  describe "source guard" do
    # Banning literals outright would demand a cosmetic refactor of ten modules
    # whose codes are already correct, and would not have caught either defect
    # this phase actually found. Both real failures — 5003 used by live wallet
    # postings while registered in no chart, and 3002 assigned to a new purpose
    # while DPS already used it — were *unregistered or colliding* codes, not
    # literals as such. So assert the invariant that matters: every GL code
    # written anywhere in the source must resolve to an active chart account.
    test "every hardcoded GL account code resolves to an active chart account" do
      known = MapSet.new(ChartOfAccounts.all(), & &1.code)

      offenders =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn path ->
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {line, no} ->
            ~r/gl_account_(?:dr|cr):\s*"(\d{4})"/
            |> Regex.scan(line)
            |> Enum.map(fn [_, code] -> {path, no, code, String.trim(line)} end)
          end)
        end)
        |> Enum.reject(fn {_, _, code, _} -> MapSet.member?(known, code) end)

      assert offenders == [],
             "GL codes not registered as active chart accounts:\n" <>
               Enum.map_join(offenders, "\n", fn {path, no, code, line} ->
                 "  #{path}:#{no} -> #{code}  |  #{line}"
               end)
    end

    test "no source file still references a retired stored-value code" do
      retired = ~w[5003]

      offenders =
        Path.wildcard("lib/**/*.ex")
        |> Enum.reject(&String.contains?(String.replace(&1, "\\", "/"), "/gl/ledger/"))
        |> Enum.flat_map(fn path ->
          ~r/gl_account_(?:dr|cr):\s*"(\d{4})"/
          |> Regex.scan(File.read!(path))
          |> Enum.map(fn [_, code] -> {path, code} end)
        end)
        |> Enum.filter(fn {_, code} -> code in retired end)

      assert offenders == [],
             "retired codes still posted to: #{inspect(offenders)}"
    end
  end
end
