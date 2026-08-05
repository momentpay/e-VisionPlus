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
  def default_rules, do: credit_rules() ++ card_rules() ++ debit_rules() ++ prepaid_rules() ++ wallet_rules()

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
