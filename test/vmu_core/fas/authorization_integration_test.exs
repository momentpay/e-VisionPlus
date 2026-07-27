defmodule VmuCore.FAS.AuthorizationIntegrationTest do
  @moduledoc """
  End-to-end integration tests for the Phase 1 authorization path.

  Covers the full chain:
    ParameterEngine (ETS) → resolve_account (DB) → AccountStateCoordinator → FAS.Authorization

  Requires a live PostgreSQL test database (vmu_core_test).
  Run with: mix test test/vmu_core/fas/authorization_integration_test.exs
  """

  use VmuCore.DataCase, async: false

  alias VmuCore.FAS.Authorization
  alias VmuCore.FAS.STIP
  alias VmuCore.CMS.{Account, AccountStateCoordinator}
  alias VmuCore.CTA.Cards
  alias VmuCore.Shared.{Customer, ParameterEngine}

  @table :vmu_parameter_cache

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp seed_parameter_hierarchy do
    # Seed ETS directly (ParameterEngine.refresh_all would need DB records)
    ensure_ets_table()

    :ets.insert(@table, {{:sys,  "0001", :base_currency}, "AED"})
    :ets.insert(@table, {{:bank, "0001", "0010", :country_code}, "ARE"})
    :ets.insert(@table, {{:logo, "0001", "0010", "0100", :bin_prefix}, "543210"})
    :ets.insert(@table, {{:logo, "0001", "0010", "0100", :description}, "Test Logo"})
    :ets.insert(@table, {{:block, "0001", "0010", "0100", "1000", :apr_percentage}, Decimal.new("24.00")})
    :ets.insert(@table, {{:block, "0001", "0010", "0100", "1000", :credit_limit_default}, Decimal.new("5000.00")})
  end

  defp ensure_ets_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, {:read_concurrency, true}])
    else
      :ets.delete_all_objects(@table)
    end
  end

  defp pan_token(pan), do: :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)

  # Way4 parity plan Phase 1 item 4 (Debit, D3) — a distinct BIN/logo
  # tagged product_type: "DEBIT", same raw-ETS-insert style this file
  # already uses (no real ParameterEngine DB round-trip needed for these
  # tests). Does NOT call ensure_ets_table/0 — that would wipe the
  # credit hierarchy `setup` already seeded.
  defp seed_debit_parameter_hierarchy do
    :ets.insert(@table, {{:logo, "0001", "0010", "0200", :bin_prefix}, "555555"})
    :ets.insert(@table, {{:logo, "0001", "0010", "0200", :description}, "Test Debit Logo"})
    :ets.insert(@table, {{:logo, "0001", "0010", "0200", :product_type}, "DEBIT"})
  end

  defp seed_debit_account(pan, initial_balance) do
    {:ok, customer} =
      Repo.insert(Customer.changeset(%Customer{}, %{
        sys_id: "0001", bank_id: "0010", first_name: "Test", last_name: "DebitCardholder"
      }))

    {:ok, account} =
      VmuCore.CMS.DebitAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: "0001", bank_id: "0010",
        logo_id: "0200", block_id: "1000"
      })

    {:ok, _} =
      VmuCore.CMS.DebitFundingCommand.fund(%{
        debit_account_id: account.debit_account_id, amount: initial_balance,
        channel: "ADMIN_MANUAL", posted_by: "operator1"
      })

    {:ok, _card} =
      Cards.issue(%{
        debit_account_id: account.debit_account_id, pan_token: pan_token(pan),
        card_type: "PRIMARY", status: "ACTIVE"
      })

    account
  end

  # Way4 parity plan Phase 1 item 5 (Prepaid, P3) — same raw-ETS-insert
  # style as Debit's hierarchy above, a distinct BIN/logo.
  defp seed_prepaid_parameter_hierarchy do
    :ets.insert(@table, {{:logo, "0001", "0010", "0300", :bin_prefix}, "606060"})
    :ets.insert(@table, {{:logo, "0001", "0010", "0300", :description}, "Test Prepaid Logo"})
    :ets.insert(@table, {{:logo, "0001", "0010", "0300", :product_type}, "PREPAID"})
  end

  defp seed_prepaid_account(pan, initial_balance) do
    {:ok, customer} =
      Repo.insert(Customer.changeset(%Customer{}, %{
        sys_id: "0001", bank_id: "0010", first_name: "Test", last_name: "PrepaidCardholder"
      }))

    {:ok, account} =
      VmuCore.CMS.PrepaidAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: "0001", bank_id: "0010",
        logo_id: "0300", block_id: "1000"
      })

    {:ok, _} =
      VmuCore.CMS.PrepaidLedger.load(%{
        prepaid_account_id: account.prepaid_account_id, amount: initial_balance,
        channel: "ADMIN_MANUAL", posted_by: "operator1"
      })

    {:ok, _card} =
      Cards.issue(%{
        prepaid_account_id: account.prepaid_account_id, pan_token: pan_token(pan),
        card_type: "PRIMARY", status: "ACTIVE"
      })

    account
  end

  defp seed_account(pan, credit_limit, status \\ "ACTIVE") do
    {:ok, customer} =
      Repo.insert(Customer.changeset(%Customer{}, %{
        sys_id: "0001", bank_id: "0010",
        first_name: "Test", last_name: "Cardholder"
      }))

    {:ok, account} =
      Repo.insert(Account.changeset(%Account{}, %{
        customer_id:    customer.customer_id,
        sys_id:         "0001",
        bank_id:        "0010",
        logo_id:        "0100",
        block_id:       "1000",
        pan_token:      pan_token(pan),
        last_four:      String.slice(pan, -4, 4),
        expiry_date:    "1228",
        credit_limit:   credit_limit,
        open_to_buy:    credit_limit,
        account_status: status
      }))

    # Way4 parity plan Phase 1 item 4 (Debit, 2026-07-26) — FAS.Authorization.
    # resolve_account/1 now resolves via the unified cta_cards master
    # (CU-1's real fix, re-ported into standalone vmu_core), not
    # cms_accounts.pan_token directly. A real account always has a real
    # card issued against it; this fixture predates that model and needs
    # to issue one explicitly to stay resolvable.
    {:ok, _card} =
      Cards.issue(%{
        account_id: account.account_id, pan_token: pan_token(pan),
        card_type: "PRIMARY", status: "ACTIVE"
      })

    account
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    seed_parameter_hierarchy()
    STIP.init_cache()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "Authorization.process/1 — happy path" do
    test "approves a valid transaction within OTB" do
      pan = "5432101234567890"
      _account = seed_account(pan, Decimal.new("5000.00"))

      request = %{pan: pan, amount: Decimal.new("100.00"), channel: :pos, mcc: "5411"}
      assert {:ok, "00", approval_code} = Authorization.process(request)
      assert String.length(approval_code) == 6
      assert Regex.match?(~r/^\d{6}$/, approval_code)
    end

    test "OTB is reduced after approval (next auth for same account sees lower OTB)" do
      pan = "5432109876543210"
      account = seed_account(pan, Decimal.new("500.00"))

      req = %{pan: pan, amount: Decimal.new("300.00"), channel: :pos, mcc: "5411"}
      assert {:ok, "00", _} = Authorization.process(req)

      # Second transaction: remaining OTB is 200.00 — 250.00 should be declined
      req2 = %{pan: pan, amount: Decimal.new("250.00"), channel: :pos, mcc: "5411"}
      assert {:error, "51"} = Authorization.process(req2)

      # Clean up coordinator process
      AccountStateCoordinator.refresh(account.account_id)
    end
  end

  describe "Authorization.process/1 — decline cases" do
    test "declines when amount exceeds OTB (RC 51)" do
      pan = "5432105555444433"
      _account = seed_account(pan, Decimal.new("200.00"))

      request = %{pan: pan, amount: Decimal.new("500.00"), channel: :pos, mcc: "5411"}
      assert {:error, "51"} = Authorization.process(request)
    end

    test "declines a blocked account (RC 62)" do
      pan = "5432106666777788"
      account = seed_account(pan, Decimal.new("5000.00"), "BLOCKED")

      request = %{pan: pan, amount: Decimal.new("100.00"), channel: :pos, mcc: "5411"}
      assert {:error, "62"} = Authorization.process(request)

      AccountStateCoordinator.refresh(account.account_id)
    end

    test "returns RC 15 for a BIN not in our logo table" do
      request = %{pan: "9999991234567890", amount: Decimal.new("50.00"), channel: :pos, mcc: "5411"}
      assert {:error, "15"} = Authorization.process(request)
    end

    test "returns RC 14 for a known BIN but no matching account" do
      # BIN 543210 is ours (seeded above) but this PAN has no account record
      request = %{pan: "5432100000000001", amount: Decimal.new("50.00"), channel: :pos, mcc: "5411"}
      assert {:error, "14"} = Authorization.process(request)
    end
  end

  describe "STIP fallback" do
    test "approves offline when amount is within STIP threshold" do
      STIP.init_cache()
      :ets.insert(:vmu_stip_cache, {{"0001", "0100"}, Decimal.new("200.00")})

      assert {:stip_approved, "00"} = STIP.authorize("0001", "0100", Decimal.new("150.00"))
    end

    test "declines offline when amount exceeds STIP threshold" do
      STIP.init_cache()
      :ets.insert(:vmu_stip_cache, {{"0001", "0100"}, Decimal.new("200.00")})

      assert {:stip_declined, "91"} = STIP.authorize("0001", "0100", Decimal.new("300.00"))
    end

    test "declines offline when no threshold is configured" do
      STIP.init_cache()
      assert {:stip_declined, "91"} = STIP.authorize("0001", "XXXX", Decimal.new("50.00"))
    end
  end

  describe "Authorization.process/1 — Debit (Way4 parity plan Phase 1 item 4)" do
    test "approves a debit transaction within available_balance and decrements it" do
      seed_debit_parameter_hierarchy()
      pan = "5555550000000001"
      account = seed_debit_account(pan, Decimal.new("500.00"))

      request = %{pan: pan, amount: Decimal.new("120.00"), channel: :pos, mcc: "5411"}
      assert {:ok, "00", approval_code} = Authorization.process(request)
      assert Regex.match?(~r/^\d{6}$/, approval_code)

      reloaded = Repo.get!(VmuCore.CMS.DebitAccount, account.debit_account_id)
      assert Decimal.equal?(reloaded.available_balance, Decimal.new("380.00"))
    end

    test "declines a debit transaction that exceeds available_balance (RC 51), balance untouched" do
      seed_debit_parameter_hierarchy()
      pan = "5555550000000002"
      account = seed_debit_account(pan, Decimal.new("50.00"))

      request = %{pan: pan, amount: Decimal.new("500.00"), channel: :pos, mcc: "5411"}
      assert {:error, "51"} = Authorization.process(request)

      reloaded = Repo.get!(VmuCore.CMS.DebitAccount, account.debit_account_id)
      assert Decimal.equal?(reloaded.available_balance, Decimal.new("50.00"))
    end
  end

  describe "Authorization.process/1 — Prepaid (Way4 parity plan Phase 1 item 5)" do
    test "approves a prepaid transaction within the stored-value balance and decrements it" do
      seed_prepaid_parameter_hierarchy()
      pan = "6060600000000001"
      account = seed_prepaid_account(pan, Decimal.new("500.00"))

      request = %{pan: pan, amount: Decimal.new("120.00"), channel: :pos, mcc: "5411"}
      assert {:ok, "00", approval_code} = Authorization.process(request)
      assert Regex.match?(~r/^\d{6}$/, approval_code)

      assert Decimal.equal?(
               VmuCore.CMS.PrepaidLedger.balance(account.prepaid_account_id),
               Decimal.new("380.00")
             )
    end

    test "declines a prepaid transaction that exceeds the stored-value balance (RC 51), balance untouched" do
      seed_prepaid_parameter_hierarchy()
      pan = "6060600000000002"
      account = seed_prepaid_account(pan, Decimal.new("50.00"))

      request = %{pan: pan, amount: Decimal.new("500.00"), channel: :pos, mcc: "5411"}
      assert {:error, "51"} = Authorization.process(request)

      assert Decimal.equal?(
               VmuCore.CMS.PrepaidLedger.balance(account.prepaid_account_id),
               Decimal.new("50.00")
             )
    end
  end

  describe "AccountStateCoordinator.ensure_started/1" do
    test "starts and registers in Horde on first call" do
      pan = "5432107777888899"
      account = seed_account(pan, Decimal.new("1000.00"))

      assert {:ok, pid} = AccountStateCoordinator.ensure_started(account.account_id)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "returns same pid on repeated calls (idempotent)" do
      pan = "5432108888999900"
      account = seed_account(pan, Decimal.new("1000.00"))

      assert {:ok, pid1} = AccountStateCoordinator.ensure_started(account.account_id)
      assert {:ok, pid2} = AccountStateCoordinator.ensure_started(account.account_id)
      assert pid1 == pid2
    end
  end
end
