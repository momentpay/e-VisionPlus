defmodule VmuCore.GL.ChartOfAccounts do
  @moduledoc """
  The enterprise Chart of Accounts registry (GL Phase A1).

  Reconciles the two conflicting hardcoded code sets that both write to
  `cms_ledger_entries` today (see §9 of `docs/gl/GL_Module_Design_and_Plan.md`):

    * `VmuCore.FAS.GL.CardAccountCodes` — 1001/2001/4001/5001/9001
    * `VmuCore.CMS.InternalGlPoster` — a different 12-code set

  Where the two disagree, `default_accounts/0` carries the **reconciled**
  meaning and records the disagreement in `legacy_conflict`, so the conflict
  is visible in queryable data rather than buried in two module docstrings.

  Nothing posts against this registry yet. Phase A is build-only; the live
  posting paths are migrated onto it in Phase C, one call site at a time,
  after the Phase B shadow diff proves equivalence.

  ## Provenance

  Accounts 1001–9001 are the 26-account set from `WalletGl.ChartOfAccounts`,
  which Avenza already reconciled onto (M5 Phase 2, 2026-07-18). That set was
  built for a credit-only `InternalGlPoster` and therefore has **no accounts
  for Debit/Prepaid/Wallet stored value** — this repository grew those
  products afterwards (Way4 parity Phase 1). Accounts 2004–2006 and 3005 are
  net-new here for exactly that reason, and are the ones most needing
  accounting sign-off.
  """

  import Ecto.Query, warn: false

  alias VmuCore.Repo
  alias VmuCore.GL.Account

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc "Returns the account, or nil."
  @spec get(String.t()) :: Account.t() | nil
  def get(code) when is_binary(code), do: Repo.get(Account, code)

  @doc "True when `code` is a registered, active account."
  @spec valid?(String.t()) :: boolean()
  def valid?(code) when is_binary(code) do
    Repo.exists?(from a in Account, where: a.code == ^code and a.active == true)
  end

  def valid?(_), do: false

  @doc "All accounts, ordered by code. `active: :all` includes retired ones."
  @spec all(keyword()) :: [Account.t()]
  def all(opts \\ []) do
    Account
    |> then(fn q -> if opts[:active] == :all, do: q, else: where(q, [a], a.active == true) end)
    |> then(fn q -> if m = opts[:owner_module], do: where(q, [a], a.owner_module == ^m), else: q end)
    |> then(fn q -> if c = opts[:account_class], do: where(q, [a], a.account_class == ^c), else: q end)
    |> order_by([a], a.code)
    |> Repo.all()
  end

  @doc """
  Accounts whose meaning is still disputed by a live posting path.

  Should be empty once Phase C completes. Until then this is the
  authoritative list of what still needs remapping — and the reason the
  trial balance cannot currently be trusted at account level for the codes
  it returns.
  """
  @spec conflicts() :: [Account.t()]
  def conflicts do
    Account
    |> where([a], not is_nil(a.legacy_conflict))
    |> order_by([a], a.code)
    |> Repo.all()
  end

  @doc "Register a new account, or update an existing one by code."
  @spec register(String.t(), map()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def register(code, attrs) when is_binary(code) and is_map(attrs) do
    (get(code) || %Account{})
    |> Account.changeset(Map.put(attrs, :code, code))
    |> Repo.insert_or_update()
  end

  @doc """
  Seeds `default_accounts/0`. Idempotent — safe to re-run; updates existing
  rows rather than duplicating or failing.
  """
  @spec seed!() :: :ok
  def seed! do
    Enum.each(default_accounts(), fn attrs ->
      {:ok, _} = register(attrs.code, attrs)
    end)
  end

  # ---------------------------------------------------------------------------
  # The chart
  # ---------------------------------------------------------------------------

  @doc """
  The reconciled enterprise chart.

  `normal_balance` is intentionally absent — it is derived from
  `account_class` by `Account.normal_balance_for/1` and enforced by a DB
  check constraint, so it cannot be set inconsistently.
  """
  @spec default_accounts() :: [map()]
  def default_accounts do
    assets() ++ liabilities() ++ clearing() ++ revenue() ++ expenses() ++ loyalty() ++
      suspense() ++ legacy()
  end

  # Codes that live postings use today but that no chart ever contained.
  # Registered `active: false` so they cannot be chosen for new postings, but
  # exist so referential integrity holds while the legacy paths still run —
  # `posting_rules.legacy_*_account` has a real FK to this table, which is how
  # 5003 was found in the first place. Retired once Phase C completes.
  defp legacy do
    [
      %{code: "5003", name: "Wallet Stored-Value Liability (legacy)", account_class: "liability",
        owner_module: "vmu_cms", active: false,
        description: "Used by CMS.InternalGlPoster for wallet load and withdrawal. Never " <>
                     "registered in any chart of accounts, and sits in the 5xxx expense " <>
                     "range despite being a liability."}
    ]
  end

  defp assets do
    [
      %{code: "1001", name: "Card Receivables", account_class: "asset", owner_module: "vmu_fas",
        description: "Amounts owed by cardholders for retail purchases."},
      %{code: "1002", name: "Cash Advance Receivable", account_class: "asset", owner_module: "vmu_cms",
        description: "Amounts owed by cardholders for cash advances."},
      %{code: "1003", name: "Accrued Interest Receivable", account_class: "asset", owner_module: "vmu_cms",
        description: "Interest accrued but not yet paid by the cardholder."},
      %{code: "1004", name: "Fee Receivable", account_class: "asset", owner_module: "vmu_cms",
        description: "Fees charged but not yet paid by the cardholder."},
      %{code: "1005", name: "Charged-Off Receivable", account_class: "asset", owner_module: "vmu_col",
        description: "Receivable moved here on write-off (180+ DPD or manual trigger); " <>
                     "forgiven balance on a settlement offer."},
      %{code: "1006", name: "HCS Employee Pool Receivable", account_class: "asset", owner_module: "vmu_hcs",
        description: "Amounts swept from fleet/HCS employee sub-accounts into the central " <>
                     "position, pending crediting to the parent."},
      %{code: "1007", name: "ITS Interchange Receivable", account_class: "asset", owner_module: "vmu_its",
        description: "Interchange owed to the issuer by the scheme network, pending clearing."},
      %{code: "1008", name: "ITS FAR Receivable", account_class: "asset", owner_module: "vmu_its",
        description: "Financial Adjustment Request amount owed to the issuer (positive FAR)."},
      %{code: "1009", name: "HCS Fleet Receivable", account_class: "asset", owner_module: "vmu_hcs",
        description: "Fuel and fleet card spend receivable from the operating company. " <>
                     "Separate from 1001 Card Receivables so corporate fleet exposure is " <>
                     "reportable apart from consumer card exposure — they are different " <>
                     "credit risks and finance bucket them separately. Added 2026-08-05 " <>
                     "when HCS gained its own product labels."}
    ]
  end

  defp liabilities do
    [
      %{code: "2001", name: "Customer Credit Liability", account_class: "liability", owner_module: "vmu_fas",
        description: "Outstanding credit card balances owed to the bank."},
      %{code: "2002", name: "HCS Parent Account Payable", account_class: "liability", owner_module: "vmu_hcs",
        description: "Amount credited to a fleet/HCS company's parent billing account from " <>
                     "an employee-pool sweep."},
      %{code: "2003", name: "ITS FAR Payable", account_class: "liability", owner_module: "vmu_its",
        description: "Financial Adjustment Request amount owed by the issuer (negative FAR)."},

      # --- Net-new: stored-value liabilities -----------------------------------
      # Absent from the inherited 26-account set because that set was built for
      # a credit-only poster. Debit/Prepaid/Wallet arrived later (Way4 parity
      # Phase 1) and were given 5001/5002/5003 — codes the 5xxx range reserves
      # for expenses, two of which were already taken. These are the correct
      # home and the accounts most needing accounting sign-off.
      %{code: "2004", name: "Debit Deposit Liability", account_class: "liability", owner_module: "vmu_cms",
        description: "Cardholder funds held in a debit account — a deposit the bank owes " <>
                     "the customer, not a receivable."},
      %{code: "2005", name: "Prepaid Stored-Value Liability", account_class: "liability", owner_module: "vmu_cms",
        description: "Loaded prepaid value owed to the cardholder (closed-loop)."},
      %{code: "2006", name: "Wallet Stored-Value Liability", account_class: "liability", owner_module: "vmu_cms",
        description: "Digital wallet balance owed to the customer."}
    ]
  end

  defp clearing do
    [
      %{code: "2007", name: "WPS Salary Disbursement Liability", account_class: "liability",
        owner_module: "vmu_wps",
        description: "Wages disbursed to workers under a Wage Protection System scheme and " <>
                     "not yet spent. Separate from 2005 Prepaid Stored-Value Liability " <>
                     "because salary float is regulated money with a reporting obligation " <>
                     "to a labour authority, and a regulator asking what we hold on behalf " <>
                     "of workers must not be answered with a number that also includes gift " <>
                     "cards. Added 2026-08-06 (Phase W1)."},
      %{code: "3001", name: "Payment / Adjustment Clearing", account_class: "asset", owner_module: "vmu_cms",
        description: "Cash received from cardholder payments, financial adjustments, and COL " <>
                     "settlement/recovery payments, awaiting reconciliation to a real bank account."},
      %{code: "3005", name: "Bank Cash / Funding Clearing", account_class: "asset", owner_module: "vmu_cms",
        description: "Cash movement for Debit/Prepaid/Wallet funding, spend and adjustment — " <>
                     "the counterparty leg of every stored-value posting."},
      %{code: "3003", name: "Disputed Receivable", account_class: "asset", owner_module: "vmu_dps",
        description: "Amount expected from the acquirer/scheme for a dispute under investigation " <>
                     "(cardholder holds provisional credit in the meantime)."},
      %{code: "3004", name: "Scheme Recovery Clearing", account_class: "asset", owner_module: "vmu_dps",
        description: "Clears 3003 when a dispute resolves CLOSED_WIN and the scheme reimburses the issuer."}
    ]
  end

  defp revenue do
    [
      %{code: "4001", name: "Fee Revenue", account_class: "revenue", owner_module: "vmu_fas",
        description: "Annual fees, late fees, cash advance fees."},
      %{code: "4002", name: "Interest Income", account_class: "revenue", owner_module: "vmu_cms",
        description: "Interest accrued on outstanding balances. Separated from 4001 Fee " <>
                     "Revenue on 2026-08-02 — both `CardAccountCodes.journal_pair/1` and " <>
                     "`InternalGlPoster.post_interest/4` previously booked interest as fee " <>
                     "income, so the two could not be told apart in the trial balance."},
      %{code: "4003", name: "Interchange Income", account_class: "revenue", owner_module: "vmu_trams",
        description: "Interchange earned by the issuer on cardholder transactions."},
      %{code: "4004", name: "Recovery Income", account_class: "revenue", owner_module: "vmu_col",
        description: "Amounts recovered on previously charged-off receivables."},
      %{code: "4005", name: "ITS FAR Income", account_class: "revenue", owner_module: "vmu_its",
        description: "Net income from Financial Adjustment Requests."}
    ]
  end

  defp expenses do
    [
      %{code: "5001", name: "Interchange / MDR Expense", account_class: "expense", owner_module: "vmu_fas",
        description: "Scheme interchange and MDR paid by the issuer."},
      %{code: "5002", name: "ITS FAR Expense", account_class: "expense", owner_module: "vmu_its",
        description: "Net expense from Financial Adjustment Requests."}
    ]
  end

  defp loyalty do
    [
      %{code: "7001", name: "LMS Provisioning Expense", account_class: "expense", owner_module: "vmu_lms",
        description: "Cost of loyalty points accrued to cardholders."},
      %{code: "7002", name: "LMS Provisioning Liability", account_class: "liability", owner_module: "vmu_lms",
        description: "Outstanding loyalty points liability."},
      %{code: "7003", name: "LMS Merchant Receivable", account_class: "asset", owner_module: "vmu_lms",
        description: "Amounts owed by merchants funding loyalty schemes."},
      %{code: "7004", name: "LMS Merchant Settlement Income", account_class: "revenue", owner_module: "vmu_lms",
        description: "Income from merchant-funded loyalty settlement."}
    ]
  end

  defp suspense do
    [
      %{code: "9001", name: "Suspense", account_class: "asset", owner_module: "vmu_fas",
        description: "Items awaiting posting confirmation or a settlement gap. " <>
                     "A non-zero balance here is an operational exception, not a normal state."}
    ]
  end
end
