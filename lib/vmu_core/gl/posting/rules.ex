defmodule VmuCore.Posting.Rules do
  @moduledoc """
  The posting-rule registry (GL Phase A2).

  `default_rules/0` is transcribed **from the live code**, not from any
  specification — `CMS.InternalGlPoster`'s 13 posting functions and
  `FAS.GL.CardAccountCodes.journal_pair/1`'s 6 clauses. That direction
  matters: those functions encode behaviour (idempotency shape, transaction
  codes, narratives) that no design document records, and Phase B's shadow
  diff is only meaningful if the legacy side reproduces them exactly.

  ## Coverage, stated honestly

  These 19 rules cover the two *centralised* posting paths. They are not yet
  the full set — `cms_ledger_entries` is also written directly by
  `FAS.SettlementPostingAdapter`, `TRAMS.AdjustmentCommand`,
  `COL.SettlementCommand`, `COL.WriteOffProcessor`, `ITS`'s two processors,
  `LMS.GlProvisioner`, `HCS`'s payment sweep, `DPS.Dispute` and several CMS
  commands. Enumerating and converting those is Phase B/C work; this registry
  is the target they migrate onto.
  """

  import Ecto.Query, warn: false

  alias VmuCore.Repo
  alias VmuCore.Posting.Rule

  # ---------------------------------------------------------------------------
  # Lookup
  # ---------------------------------------------------------------------------

  @doc "Fetch the active rule for an event/product pair."
  @spec fetch(String.t(), String.t()) :: {:ok, Rule.t()} | {:error, :no_rule}
  def fetch(event_type, product) do
    case Repo.get_by(Rule, event_type: event_type, product: product, active: true) do
      nil  -> {:error, :no_rule}
      rule -> {:ok, rule}
    end
  end

  @doc "All active rules, ordered for stable display."
  @spec all(keyword()) :: [Rule.t()]
  def all(opts \\ []) do
    Rule
    |> then(fn q -> if opts[:active] == :all, do: q, else: where(q, [r], r.active == true) end)
    |> then(fn q -> if p = opts[:product], do: where(q, [r], r.product == ^p), else: q end)
    |> order_by([r], [r.product, r.event_type])
    |> Repo.all()
  end

  @doc """
  Rules whose live posting path still disagrees with the reconciled chart.

  This is the Phase C worklist. It should be empty when the cutover is done.
  """
  @spec pending_cutover() :: [Rule.t()]
  def pending_cutover do
    Rule
    |> where([r], not is_nil(r.legacy_dr_account))
    |> order_by([r], [r.product, r.event_type])
    |> Repo.all()
  end

  @doc "Upsert a rule by its `{event_type, product}` key."
  @spec upsert(map()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def upsert(%{event_type: e, product: p} = attrs) do
    (Repo.get_by(Rule, event_type: e, product: p) || %Rule{})
    |> Rule.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Seeds `default_rules/0`. Idempotent."
  @spec seed!() :: :ok
  def seed! do
    Enum.each(default_rules(), fn attrs -> {:ok, _} = upsert(attrs) end)
  end

  # ---------------------------------------------------------------------------
  # The rules
  # ---------------------------------------------------------------------------

  @igp "CMS.InternalGlPoster"
  @cac "FAS.GL.CardAccountCodes"

  @doc "Every rule transcribed from live code. See moduledoc for coverage limits."
  @spec default_rules() :: [map()]
  def default_rules,
    do:
      credit_rules() ++ card_rules() ++ debit_rules() ++ prepaid_rules() ++ wallet_rules() ++
        hcs_rules() ++ recovery_rules() ++ wps_rules()

  # --- CMS credit ledger (InternalGlPoster) ----------------------------------
  defp credit_rules do
    [
      %{event_type: "INTEREST", product: "CREDIT",
        dr_account: "1003", cr_account: "4002",
        legacy_transaction_code: "INTEREST",
        narrative_template: "Monthly interest accrual", source_module: @igp,
        notes: "Legacy credits 2001, which the reconciled chart defines as Customer " <>
               "Credit Liability. Interest income is 4002."},

      %{event_type: "FEE", product: "CREDIT",
        dr_account: "1004", cr_account: "4001",
        legacy_transaction_code: "FEE",
        narrative_template: "Fee: {fee_type}", source_module: @igp,
        notes: "Legacy credits 2002 (HCS Parent Account Payable in the reconciled " <>
               "chart). Fee revenue is 4001."},

      %{event_type: "PAYMENT", product: "CREDIT",
        dr_account: "3001", cr_account: "1001",
        legacy_transaction_code: "PAYMENT",
        narrative_template: "Cardholder payment", source_module: @igp,
        notes: "Already consistent with the reconciled chart — no cutover needed."},

      # --- Added 2026-08-04, derived from live data during the C2 backfill ----
      # `cms_accounts` backs BOTH the CREDIT and CREDIT_CARD product labels —
      # `InstitutionResolver.resolve_product/1` returns CREDIT for that table,
      # while the card-side rules below were registered under CREDIT_CARD. So a
      # real posting on a credit account whose event only existed on the card
      # side resolved to no rule at all. The backfill made that measurable: 17
      # of 33 historical rows were unreplayable for exactly this reason.
      #
      # Pairs are taken from what those rows actually store, not re-derived.
      %{event_type: "PURCHASE", product: "CREDIT",
        dr_account: "1001", cr_account: "2001",
        legacy_transaction_code: "PURCHASE",
        narrative_template: "Card purchase", source_module: @igp,
        notes: "Same pair as CREDIT_CARD/PURCHASE — the distinction is the " <>
               "product label the account resolves to, not the accounting."},

      %{event_type: "CASH_ADV", product: "CREDIT",
        dr_account: "1002", cr_account: "2001",
        legacy_transaction_code: "CASH_ADV",
        narrative_template: "Cash advance", source_module: @igp,
        notes: "Debits 1002 Cash Advance Receivable, not 1001 — cash advances " <>
               "are tracked separately from retail for interest purposes."},

      %{event_type: "DISPUTE_CREDIT", product: "CREDIT",
        dr_account: "3003", cr_account: "1001",
        legacy_transaction_code: "DISPUTE_CREDIT",
        narrative_template: "Provisional credit — dispute", source_module: "DPS.Dispute",
        notes: "3003 Disputed Receivable, per the Phase 4A DPS remap. The " <>
               "CREDIT_CARD rule still shows the pre-remap 2001/1001 pair used " <>
               "for reverse lookup only."},

      %{event_type: "ADJUSTMENT_DEBIT", product: "CREDIT",
        dr_account: "1001", cr_account: "9001",
        legacy_transaction_code: "ADJUSTMENT",
        narrative_template: "{narrative}", source_module: "CMS.CreditBalanceRefund",
        notes: "Raises the receivable against suspense — a refund of a credit " <>
               "balance to the cardholder."},

      %{event_type: "ADJUSTMENT_CREDIT", product: "CREDIT",
        dr_account: "9001", cr_account: "1001",
        legacy_transaction_code: "ADJUSTMENT",
        narrative_template: "{narrative}", source_module: "CMS.FinancialAdjustment",
        notes: "The reverse direction — reduces the receivable."}
    ]
  end

  # --- FAS/TRAMS credit-card pairs (CardAccountCodes.journal_pair/1) ---------
  # journal_pair/1 is used for reverse lookup in VmuCoreGlAdapter and to
  # generate TRAMS adjustments. All pairs already match the reconciled chart;
  # INTEREST was corrected 2026-08-02 (was 4001 Fee Revenue).
  defp card_rules do
    [
      %{event_type: "PURCHASE", product: "CREDIT_CARD", dr_account: "1001", cr_account: "2001",
        legacy_transaction_code: "PURCHASE", narrative_template: "Card purchase", source_module: @cac},

      %{event_type: "CASH_ADV", product: "CREDIT_CARD", dr_account: "1001", cr_account: "2001",
        legacy_transaction_code: "CASH_ADV", narrative_template: "Cash advance", source_module: @cac},

      %{event_type: "FEE", product: "CREDIT_CARD", dr_account: "2001", cr_account: "4001",
        legacy_transaction_code: "FEE", narrative_template: "Card fee", source_module: @cac,
        notes: "A different fee model from the CREDIT product's rule: increases the " <>
               "cardholder liability rather than raising a fee receivable. Both are live."},

      %{event_type: "INTEREST", product: "CREDIT_CARD", dr_account: "2001", cr_account: "4002",
        legacy_transaction_code: "INTEREST", narrative_template: "Card interest", source_module: @cac,
        notes: "Corrected 2026-08-02: was 4001 Fee Revenue. The change also made " <>
               "INTEREST distinguishable from FEE in the adapter's reverse lookup, " <>
               "where it had been unreachable."},

      %{event_type: "REVERSAL", product: "CREDIT_CARD", dr_account: "2001", cr_account: "1001",
        legacy_transaction_code: "REVERSAL", narrative_template: "Reversal", source_module: @cac},

      %{event_type: "DISPUTE_CREDIT", product: "CREDIT_CARD", dr_account: "2001", cr_account: "1001",
        legacy_transaction_code: "DISPUTE_CREDIT", narrative_template: "Dispute credit", source_module: @cac}
    ]
  end

  # --- Stored-value products -------------------------------------------------
  # Remapped in Phase 4A: cash clearing 1006 → 3005; stored value out of the
  # 5xxx expense range into 2004/2005/2006. The live posters now emit these,
  # so no legacy divergence remains.
  defp debit_rules do
    stored_value("DEBIT", "2004", "5001",
      deposit:    {"DEPOSIT",  "Debit account funding: {channel}"},
      spend:      {"PURCHASE", "Debit card purchase settlement"},
      adjustments: true)
  end

  defp prepaid_rules do
    stored_value("PREPAID", "2005", "5002",
      deposit:    {"DEPOSIT",  "Prepaid account load: {channel}"},
      spend:      {"PURCHASE", "Prepaid card purchase settlement"},
      adjustments: true)
  end

  defp wallet_rules do
    # Wallet has only load and withdrawal in `InternalGlPoster` — there are no
    # `post_wallet_adjustment` clauses, unlike Debit and Prepaid. Generating
    # adjustment rules here would invent posting paths that do not exist, and
    # a rule carrying legacy accounts asserts that live code posts that way.
    stored_value("WALLET", "2006", "5003",
      deposit:    {"DEPOSIT",    "Wallet account load: {channel}"},
      spend:      {"WITHDRAWAL", "{narrative}"},
      adjustments: false)
  end

  # --- WPS salary disbursement -----------------------------------------------
  #
  # Added 2026-08-06 (Phase W1). WPS workers hold ordinary
  # `cms_prepaid_accounts` rows, so before this they resolved as `PREPAID` and
  # their balances were indistinguishable from gift-card float. That matters
  # more here than it did for HCS: salary float is **regulated money** with a
  # reporting obligation to a labour authority, and a regulator asking what the
  # bank holds on behalf of workers cannot be answered with a number that also
  # includes prepaid top-ups. Hence account 2007, and hence its own product.
  #
  # ## WITHDRAWAL exists even though its account pair matches PURCHASE
  #
  # Both move money out of the salary liability into cash clearing, so the debit
  # and credit are identical. The event is still separate because this
  # population is **cash-out heavy** — that is the single most important thing
  # to be able to report on for a WPS programme, and `posting_sets.event_type`
  # is what makes it queryable. A shared account pair is not a reason to
  # collapse two events that answer different questions.
  #
  # ## Superset of PREPAID
  #
  # Every PREPAID event is covered, because `InstitutionResolver` relabels
  # existing prepaid accounts once they join a roster and `Posting.Cutover`
  # makes the engine authoritative — a narrower set would turn a working
  # posting path into a failing one at the moment of relabelling. Same
  # invariant HCS established, asserted by the same test.
  defp wps_rules do
    liability = "2007"
    cash = "3005"

    [
      %{event_type: "DEPOSIT", product: "WPS_PREPAID",
        dr_account: cash, cr_account: liability,
        legacy_transaction_code: "DEPOSIT",
        narrative_template: "WPS salary credit: {pay_period}", source_module: @igp,
        notes: "The salary credit itself. Employer money arrives through cash clearing " <>
               "and becomes a liability to the worker."},

      %{event_type: "PURCHASE", product: "WPS_PREPAID",
        dr_account: liability, cr_account: cash,
        legacy_transaction_code: "PURCHASE",
        narrative_template: "WPS card purchase", source_module: @igp,
        notes: "Retail spend against disbursed wages."},

      %{event_type: "WITHDRAWAL", product: "WPS_PREPAID",
        dr_account: liability, cr_account: cash,
        legacy_transaction_code: "PURCHASE",
        narrative_template: "WPS cash withdrawal: {channel}", source_module: @igp,
        notes: "ATM cash-out. Same account pair as PURCHASE by design — see the " <>
               "module comment. Kept separate because cash-out volume is the " <>
               "headline metric for a WPS programme."},

      %{event_type: "REVERSAL", product: "WPS_PREPAID",
        dr_account: liability, cr_account: cash,
        legacy_transaction_code: "REVERSAL",
        narrative_template: "WPS employer refund: {reason}", source_module: @igp,
        notes: "Employer refund of a salary credit that should not have been paid — " <>
               "an overpayment or a worker who had already left. Distinct from a " <>
               "worker withdrawal because the money returns to the employer."},

      %{event_type: "ADJUSTMENT_CREDIT", product: "WPS_PREPAID",
        dr_account: cash, cr_account: liability,
        legacy_transaction_code: "ADJUSTMENT",
        narrative_template: "WPS adjustment (credit): {narrative}", source_module: @igp,
        notes: "Correction increasing the worker's balance."},

      %{event_type: "ADJUSTMENT_DEBIT", product: "WPS_PREPAID",
        dr_account: liability, cr_account: cash,
        legacy_transaction_code: "ADJUSTMENT",
        narrative_template: "WPS adjustment (debit): {narrative}", source_module: @igp,
        notes: "Correction reducing the worker's balance."}
    ]
  end

  # --- Post-charge-off recovery ----------------------------------------------
  #
  # Added 2026-08-06 during C3. `COL.WriteOffProcessor.post_recovery/3` labels
  # its posting `PAYMENT`, because `cms_ledger_entries.transaction_code` has no
  # RECOVERY member — but a recovery credits **recovery income**, where a
  # payment credits the receivable. While the caller passed raw account codes
  # that distinction survived by accident; once the rule decides the accounts it
  # has to be a rule.
  #
  # The pair is the same for every product: money arrives through payment
  # clearing and lands in recovery income. Only the receivable differs between
  # products, and a recovery does not touch it — the balance was already
  # written off.
  defp recovery_rules do
    for product <- ~w[CREDIT CREDIT_CARD HCS_FLEET HCS_CORPORATE] do
      %{event_type: "RECOVERY", product: product,
        dr_account: "3001", cr_account: "4004",
        legacy_transaction_code: "PAYMENT",
        narrative_template: "Post-charge-off recovery", source_module: @igp,
        notes: "Recovery income 4004, not the receivable. The legacy enum has no " <>
               "RECOVERY code, so the caller names the event explicitly — see " <>
               "Posting.LegacyEvent."}
    end
  end

  # --- HCS corporate and fleet cards -----------------------------------------
  #
  # HCS cards hang off real `cms_accounts` rows — `HCS.CompanyOnboarding` and
  # `HCS.FleetOnboarding` each provision one — so before 2026-08-05 they
  # resolved as product `CREDIT` and posted to the consumer card accounts,
  # `1001` / `2001`. That worked, but it meant corporate fleet exposure was
  # indistinguishable from a consumer credit card on the balance sheet, and the
  # two HCS accounts already registered in the chart (`1006`, `2002`) had never
  # received a single posting.
  #
  # `InstitutionResolver` now labels these accounts `HCS_FLEET` and
  # `HCS_CORPORATE`, and these are their rules.
  #
  # ## Why this mirrors the CREDIT event set exactly
  #
  # All eight CREDIT events are covered, not just the six the live data happens
  # to show. `Posting.Cutover` makes the engine authoritative for these
  # products, so a `{:error, :no_rule}` **aborts the real posting** — a partial
  # event set would turn a working posting path into a failing one the moment
  # an account was relabelled. The rule set has to be a superset of what the
  # old label could handle before the relabel is safe.
  #
  # ## What changes per event
  #
  # The receivable moves from `1001` to the product's own account, and the
  # liability from `2001` (owed by a consumer cardholder) to `2002` (owed by
  # the operating company — which is what central-liability HCS billing means).
  # Fee and interest are untouched: fee revenue is fee revenue regardless of who
  # holds the card.
  defp hcs_rules do
    hcs_product("HCS_FLEET", "1009", "fleet") ++
      hcs_product("HCS_CORPORATE", "1006", "corporate")
  end

  defp hcs_product(product, receivable, label) do
    payable = "2002"

    [
      %{event_type: "PURCHASE", product: product,
        dr_account: receivable, cr_account: payable,
        legacy_transaction_code: "PURCHASE",
        narrative_template: "HCS #{label} card purchase", source_module: @igp,
        notes: "Mirrors CREDIT PURCHASE (1001/2001) with the HCS receivable and the " <>
               "parent company payable."},

      %{event_type: "CASH_ADV", product: product,
        dr_account: "1002", cr_account: payable,
        legacy_transaction_code: "CASH_ADV",
        narrative_template: "HCS #{label} cash advance", source_module: @igp,
        notes: "Cash advance receivable 1002 is shared across products; only the " <>
               "liability side is HCS-specific."},

      %{event_type: "PAYMENT", product: product,
        dr_account: "3001", cr_account: receivable,
        legacy_transaction_code: "PAYMENT",
        narrative_template: "HCS #{label} settlement", source_module: @igp,
        notes: "Company settles the receivable through payment clearing."},

      %{event_type: "FEE", product: product,
        dr_account: "1004", cr_account: "4001",
        legacy_transaction_code: "FEE",
        narrative_template: "HCS #{label} fee: {fee_type}", source_module: @igp,
        notes: "Identical to CREDIT — fee revenue does not depend on who holds the card."},

      %{event_type: "INTEREST", product: product,
        dr_account: "1003", cr_account: "4002",
        legacy_transaction_code: "INTEREST",
        narrative_template: "HCS #{label} interest accrual", source_module: @igp,
        notes: "Identical to CREDIT — interest income does not depend on who holds the card."},

      %{event_type: "DISPUTE_CREDIT", product: product,
        dr_account: "3003", cr_account: receivable,
        legacy_transaction_code: "DISPUTE_CREDIT",
        narrative_template: "HCS #{label} dispute credit", source_module: @igp,
        notes: "Mirrors CREDIT DISPUTE_CREDIT against the HCS receivable."},

      %{event_type: "ADJUSTMENT_CREDIT", product: product,
        dr_account: "9001", cr_account: receivable,
        legacy_transaction_code: "ADJUSTMENT",
        narrative_template: "HCS #{label} adjustment (credit)", source_module: @igp,
        notes: "Mirrors CREDIT ADJUSTMENT_CREDIT against the HCS receivable."},

      %{event_type: "ADJUSTMENT_DEBIT", product: product,
        dr_account: receivable, cr_account: "9001",
        legacy_transaction_code: "ADJUSTMENT",
        narrative_template: "HCS #{label} adjustment (debit)", source_module: @igp,
        notes: "Mirrors CREDIT ADJUSTMENT_DEBIT against the HCS receivable."}
    ]
  end

  # The stored-value products share one posting shape: cash clearing on one
  # side, the product's own liability on the other. Generated rather than
  # transcribed three times, so a product cannot drift from the pattern by
  # copy-paste — but the event set is explicit per product, because they
  # genuinely differ.
  defp stored_value(product, liability, _legacy_liability, opts) do
    cash = "3005"

    {deposit_event, deposit_narrative} = Keyword.fetch!(opts, :deposit)
    {spend_event, spend_narrative}     = Keyword.fetch!(opts, :spend)

    base = [
      %{event_type: deposit_event, product: product,
        dr_account: cash, cr_account: liability,
        legacy_transaction_code: "DEPOSIT",
        narrative_template: deposit_narrative, source_module: @igp},

      %{event_type: spend_event, product: product,
        dr_account: liability, cr_account: cash,
        # Wallet withdrawal posts as "PURCHASE" in cms_ledger_entries today —
        # transaction_code there is a constrained enum with no WITHDRAWAL member.
        legacy_transaction_code: "PURCHASE",
        narrative_template: spend_narrative, source_module: @igp}
    ]

    if Keyword.fetch!(opts, :adjustments) do
      base ++
        [
          %{event_type: "ADJUSTMENT_CREDIT", product: product,
            dr_account: cash, cr_account: liability,
            legacy_transaction_code: "ADJUSTMENT",
            narrative_template: "{narrative}", source_module: @igp},

          %{event_type: "ADJUSTMENT_DEBIT", product: product,
            dr_account: liability, cr_account: cash,
            legacy_transaction_code: "ADJUSTMENT",
            narrative_template: "{narrative}", source_module: @igp}
        ]
    else
      base
    end
  end
end
