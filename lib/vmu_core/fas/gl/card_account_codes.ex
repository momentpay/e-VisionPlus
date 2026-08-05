defmodule VmuCore.FAS.GL.CardAccountCodes do
  @moduledoc """
  Chart-of-accounts codes for card transaction GL entries (FAS-P5 5B).

  VisionPlus maps to a five-account card GL structure:

    1001  Card Receivables        — amounts owed by cardholders (asset, DR-normal)
    2001  Customer Credit Liability — outstanding credit card balances (liability, CR-normal)
    4001  Fee Revenue             — annual fees, late fees, cash advance fees (income, CR-normal)
    5001  Interchange / MDR Expense — scheme interchange paid by issuer (expense, DR-normal)
    9001  Suspense                — items awaiting posting confirmation / settlement gap

  ## Journal patterns per transaction type

    PURCHASE (settlement confirmed):
      DR 1001 Card Receivables
      CR 2001 Customer Credit Liability

    CASH_ADV (cash advance settled):
      DR 1001 Card Receivables
      CR 2001 Customer Credit Liability

    FEE (annual fee, late fee, etc.):
      DR 2001 Customer Credit Liability  ← fee increases what customer owes
      CR 4001 Fee Revenue

    INTEREST (monthly interest charge):
      DR 2001 Customer Credit Liability
      CR 4002 Interest Income            ← corrected 2026-08-02: was 4001 Fee
                                           Revenue, which commingled interest
                                           and fee income. See journal_pair/1.

    PAYMENT (customer pays):
      DR bank/NOSTRO clearing account (external)
      CR 1001 Card Receivables           ← reduces outstanding receivable

    REVERSAL (auth reversal):
      DR 2001 Customer Credit Liability  ← reverses the liability
      CR 1001 Card Receivables           ← reverses the receivable

    DISPUTE_CREDIT (chargeback credit to customer):
      DR 2001 Customer Credit Liability
      CR 1001 Card Receivables

  ## AFEX mapping

  When posting to AFEX (the external GL), vmu_core codes map 1:1 to AFEX's
  own account hierarchy — no translation needed for these five codes.
  """

  @card_receivables    "1001"
  @credit_liability    "2001"
  @fee_revenue         "4001"
  @interest_income     "4002"
  @interchange_expense "5001"
  @suspense            "9001"

  def card_receivables,    do: @card_receivables
  def credit_liability,    do: @credit_liability
  def fee_revenue,         do: @fee_revenue
  def interest_income,     do: @interest_income
  def interchange_expense, do: @interchange_expense
  def suspense,            do: @suspense

  @all_codes [@card_receivables, @credit_liability, @fee_revenue, @interest_income,
              @interchange_expense, @suspense]

  @doc "Returns true when `code` is a known vmu_core card account code."
  @spec valid?(String.t()) :: boolean()
  def valid?(code), do: code in @all_codes

  @doc "All known card GL account codes."
  @spec all() :: [String.t()]
  def all, do: @all_codes

  @doc """
  Returns the (dr_account, cr_account) pair for a transaction_code.
  Returns `nil` for unknown codes.
  """
  @spec journal_pair(String.t()) :: {String.t(), String.t()} | nil
  def journal_pair("PURCHASE"),       do: {@card_receivables, @credit_liability}
  def journal_pair("CASH_ADV"),       do: {@card_receivables, @credit_liability}
  def journal_pair("FEE"),            do: {@credit_liability,  @fee_revenue}
  # Interest credits 4002 Interest Income, NOT 4001 Fee Revenue (2026-08-02).
  # Two defects in one line before this change:
  #   1. Misclassification — interest revenue booked into the fee revenue
  #      account, so the two could not be separated in the trial balance.
  #   2. FEE and INTEREST returned an identical pair, which made INTEREST
  #      unreachable in `VmuCoreGlAdapter.infer_transaction_code/2` (it scans
  #      FEE first), silently labelling any interest entry arriving through
  #      that adapter as "FEE".
  # 4002 is registered in @all_codes above so `valid?/1` accepts it — omitting
  # that would make the adapter reject every entry posting to the new account.
  def journal_pair("INTEREST"),       do: {@credit_liability,  @interest_income}
  def journal_pair("REVERSAL"),       do: {@credit_liability,  @card_receivables}
  def journal_pair("DISPUTE_CREDIT"), do: {@credit_liability,  @card_receivables}
  def journal_pair(_),                do: nil
end
