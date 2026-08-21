defmodule VmuCoreWeb.Admin.Nav do
  @moduledoc """
  The admin console's navigation taxonomy — the single source of truth for
  what the module dock and the contextual sidebar render.

  ## Three levels

      nav module   (top dock — a business domain of a card issuer)
        └─ group   (sidebar heading)
             └─ item  (a leaf screen)

  ## Why this shape rather than the old five sections

  The console previously grouped its screens into five sections
  (`:hierarchy/:operations/:financial/:fas/:security`). Those were an ASM
  permission heuristic — "who touches this during a shift" — not an
  information architecture. They put Debit Cards, KYC Requests and
  Collections in one undifferentiated "Operations" bucket, which is fine at
  ten screens and unusable at sixty.

  These thirteen modules are the domains of an **issuing** platform, in the
  shape VisionPlus and Way4 organise them, cross-checked against
  `docs/compare/Kosa_Handbook_Alignment_Assessment.md`'s domain rings. Note
  this is deliberately *not* the taxonomy of the acquiring backoffice whose
  visual design this console follows: an issuer's spine runs
  Customer → Account → Card → Authorization → Billing → Collections, where an
  acquirer's runs Merchant → Terminal → Payments → Clearing → Settlement.

  ## Item status

  `:live` items have a screen behind them today. `:planned` items are real,
  already-identified gaps — mostly named in the Koṣa assessment — that render
  greyed out and non-clickable rather than being hidden. Showing them is the
  point: the navigation doubles as the roadmap, and an operator can see that
  Chargeback representment is coming rather than concluding it does not exist.

  ## Permissions

  Only `:live` items are permission-gated, via `VmuCore.ASM.Authz`. A
  `:planned` item has nothing behind it to protect, so it needs no
  `RolePermission` row — see `docs/shared/Admin_Menu_Standard.md` §2.1.

  A `:live` item's `id` must also be a key in
  `VmuCore.ASM.RolePermission.modules()` and be granted to at least one role,
  or it stays invisible to everyone but ADMIN. `test/admin/menu_registry_test.exs`
  guards that; it exists because the General Ledger screen once shipped fully
  built and completely unreachable.
  """

  # ---------------------------------------------------------------------------
  # Level 1 — the module dock
  #
  # `accent` keys into the palette in priv/static/assets/admin.css
  # (`[data-accent="..."]`). Unlike the Tailwind-based reference implementation,
  # which must spell out every literal class because its scanner cannot see
  # interpolated names, plain CSS custom properties let one rule serve every
  # accent — so adding a colour here is a three-line CSS change, not a
  # five-class block.
  # ---------------------------------------------------------------------------
  @nav_modules [
    %{id: "overview", label: "Overview", short_label: "Overview",
      icon: "home", accent: "indigo", order: 10,
      description: "Portfolio dashboards, KPIs and alerts"},

    %{id: "party", label: "Customer & Party", short_label: "Customer",
      icon: "users", accent: "violet", order: 20,
      description: "Customer master, onboarding, KYC and arrangements"},

    %{id: "cards_accounts", label: "Cards & Accounts", short_label: "Cards",
      icon: "credit-card", accent: "sky", order: 30,
      description: "Account master, card products and card lifecycle"},

    %{id: "authorization", label: "Authorization & Switching", short_label: "Auth",
      icon: "bolt", accent: "emerald", order: 40,
      description: "Real-time authorization, stand-in, card security"},

    %{id: "transactions", label: "Transactions & Clearing", short_label: "Txns",
      icon: "arrows-right-left", accent: "teal", order: 50,
      description: "Transaction lifecycle, clearing, settlement, reconciliation"},

    %{id: "billing", label: "Billing & Statements", short_label: "Billing",
      icon: "document-text", accent: "amber", order: 60,
      description: "Cycles, statements, interest, fees, payments"},

    %{id: "collections", label: "Collections & Recovery", short_label: "Collections",
      icon: "phone", accent: "orange", order: 70,
      description: "Delinquency servicing, treatment and recovery"},

    %{id: "disputes", label: "Disputes & Chargebacks", short_label: "Disputes",
      icon: "scale", accent: "rose", order: 80,
      description: "Cardholder disputes and network chargeback recovery"},

    %{id: "risk", label: "Risk, Fraud & Compliance", short_label: "Risk",
      icon: "shield-exclamation", accent: "fuchsia", order: 90,
      description: "Fraud operations, screening, credit risk and exposure"},

    %{id: "finance", label: "Finance & General Ledger", short_label: "Finance",
      icon: "book-open", accent: "blue", order: 100,
      description: "Ledger, accounting periods, financial reporting"},

    %{id: "loyalty", label: "Loyalty & Rewards", short_label: "Loyalty",
      icon: "gift", accent: "cyan", order: 110,
      description: "Points programmes, redemption and campaigns"},

    %{id: "platform_config", label: "Platform Configuration", short_label: "Config",
      icon: "cog", accent: "purple", order: 120,
      description: "Parameter hierarchy, products, reference data"},

    %{id: "security", label: "Security & Access", short_label: "Security",
      icon: "lock-closed", accent: "slate", order: 130,
      description: "Operators, approvals, audit and access control"}
  ]

  # ---------------------------------------------------------------------------
  # Levels 2 and 3 — sidebar groups and their items
  #
  # `group_order` positions the group within its module; `order` positions the
  # item within its group. Both are spaced by 10s so anything can be inserted
  # without renumbering its neighbours.
  #
  # A `:live` item's `id` is also its permission key and its render-branch key
  # in AdminLive — the three must agree.
  # ---------------------------------------------------------------------------
  @items [
    # ── Overview ────────────────────────────────────────────────────────────
    %{id: "portfolio_dashboard", label: "Portfolio Dashboard", icon: "chart-pie",
      nav_module: "overview", group: "Dashboards", group_order: 10, order: 10, status: :live},
    %{id: "issuing_kpis", label: "Issuing KPIs", icon: "chart-bar",
      nav_module: "overview", group: "Dashboards", group_order: 10, order: 20, status: :planned},
    %{id: "alerts", label: "Alerts & Notifications", icon: "bell",
      nav_module: "overview", group: "Dashboards", group_order: 10, order: 30, status: :planned},

    # ── Customer & Party ────────────────────────────────────────────────────
    %{id: "customer", label: "Customers (CIF)", icon: "users",
      nav_module: "party", group: "Customer Management", group_order: 10, order: 10, status: :live},
    %{id: "party_360", label: "Party 360", icon: "identification",
      nav_module: "party", group: "Customer Management", group_order: 10, order: 20, status: :planned},
    %{id: "relationships", label: "Relationships & Hierarchy", icon: "share",
      nav_module: "party", group: "Customer Management", group_order: 10, order: 30, status: :planned},

    %{id: "kyc_methods", label: "KYC Methods", icon: "document-check",
      nav_module: "party", group: "Onboarding & KYC", group_order: 20, order: 10, status: :live},
    %{id: "kyc_requests", label: "KYC Requests", icon: "clipboard",
      nav_module: "party", group: "Onboarding & KYC", group_order: 20, order: 20, status: :live},
    %{id: "onboarding_applications", label: "Applications", icon: "inbox",
      nav_module: "party", group: "Onboarding & KYC", group_order: 20, order: 30, status: :planned},
    %{id: "document_vault", label: "Document Vault", icon: "archive-box",
      nav_module: "party", group: "Onboarding & KYC", group_order: 20, order: 40, status: :planned},

    %{id: "customer_arrangements", label: "Arrangements", icon: "rectangle-stack",
      nav_module: "party", group: "Contracts", group_order: 30, order: 10, status: :planned},
    %{id: "contract_terms", label: "Terms & Conditions", icon: "document-text",
      nav_module: "party", group: "Contracts", group_order: 30, order: 20, status: :planned},

    %{id: "contact_management", label: "Contact Management", icon: "chat",
      nav_module: "party", group: "Servicing", group_order: 40, order: 10, status: :planned},
    %{id: "consent_preferences", label: "Consent & Preferences", icon: "check-circle",
      nav_module: "party", group: "Servicing", group_order: 40, order: 20, status: :planned},

    # ── Cards & Accounts ────────────────────────────────────────────────────
    %{id: "account", label: "Accounts (CMS)", icon: "rectangle-stack",
      nav_module: "cards_accounts", group: "Accounts", group_order: 10, order: 10, status: :live},
    %{id: "balance_buckets", label: "Balance Buckets", icon: "squares",
      nav_module: "cards_accounts", group: "Accounts", group_order: 10, order: 20, status: :planned},
    %{id: "account_hierarchy", label: "Account Hierarchy", icon: "share",
      nav_module: "cards_accounts", group: "Accounts", group_order: 10, order: 30, status: :planned},

    %{id: "debit", label: "Debit Cards", icon: "credit-card",
      nav_module: "cards_accounts", group: "Card Products", group_order: 20, order: 10, status: :live},
    %{id: "prepaid", label: "Prepaid Cards", icon: "credit-card",
      nav_module: "cards_accounts", group: "Card Products", group_order: 20, order: 20, status: :live},
    %{id: "hcs", label: "Corporate Cards (HCS)", icon: "building-office",
      nav_module: "cards_accounts", group: "Card Products", group_order: 20, order: 30, status: :live},
    %{id: "wallet", label: "Digital Wallet", icon: "wallet",
      nav_module: "cards_accounts", group: "Card Products", group_order: 20, order: 40, status: :live},

    %{id: "card_issuance", label: "Card Issuance", icon: "sparkles",
      nav_module: "cards_accounts", group: "Card Lifecycle", group_order: 30, order: 10, status: :planned},
    %{id: "embossing", label: "Embossing & Fulfilment", icon: "printer",
      nav_module: "cards_accounts", group: "Card Lifecycle", group_order: 30, order: 20, status: :planned},
    %{id: "card_renewal", label: "Activation & Renewal", icon: "arrow-path",
      nav_module: "cards_accounts", group: "Card Lifecycle", group_order: 30, order: 30, status: :planned},
    %{id: "card_replacement", label: "Replacement & Reissue", icon: "arrow-uturn-left",
      nav_module: "cards_accounts", group: "Card Lifecycle", group_order: 30, order: 40, status: :planned},

    %{id: "pin_management", label: "PIN Management", icon: "key",
      nav_module: "cards_accounts", group: "Card Services", group_order: 40, order: 10, status: :planned},
    %{id: "card_blocks", label: "Card Blocks & Status", icon: "lock-closed",
      nav_module: "cards_accounts", group: "Card Services", group_order: 40, order: 20, status: :planned},
    %{id: "tokenization", label: "Tokenization (NTS)", icon: "cpu-chip",
      nav_module: "cards_accounts", group: "Card Services", group_order: 40, order: 30, status: :planned},

    # ── Authorization & Switching ───────────────────────────────────────────
    %{id: "exceptions", label: "Exception Queue", icon: "exclamation-triangle",
      nav_module: "authorization", group: "Live Authorization", group_order: 10, order: 10, status: :live},
    %{id: "auth_history", label: "Auth History", icon: "clock",
      nav_module: "authorization", group: "Live Authorization", group_order: 10, order: 20, status: :live},
    %{id: "auth_monitor", label: "Live Monitor", icon: "signal",
      nav_module: "authorization", group: "Live Authorization", group_order: 10, order: 30, status: :planned},

    %{id: "stip_thresholds", label: "STIP Thresholds", icon: "adjustments",
      nav_module: "authorization", group: "Stand-In & Rules", group_order: 20, order: 10, status: :planned},
    %{id: "auth_rules", label: "Authorization Rules", icon: "bolt",
      nav_module: "authorization", group: "Stand-In & Rules", group_order: 20, order: 20, status: :planned},
    %{id: "velocity_limits", label: "Velocity & Limits", icon: "gauge",
      nav_module: "authorization", group: "Stand-In & Rules", group_order: 20, order: 30, status: :planned},

    %{id: "hot_cards", label: "Hot Card List", icon: "fire",
      nav_module: "authorization", group: "Card Security", group_order: 30, order: 10, status: :planned},
    %{id: "hsm_keys", label: "HSM & Key Management", icon: "key",
      nav_module: "authorization", group: "Card Security", group_order: 30, order: 20, status: :planned},
    %{id: "emv_parameters", label: "EMV Parameters", icon: "cpu-chip",
      nav_module: "authorization", group: "Card Security", group_order: 30, order: 30, status: :planned},

    %{id: "bin_routing", label: "BIN Routing", icon: "map-pin",
      nav_module: "authorization", group: "Switching", group_order: 40, order: 10, status: :planned},
    %{id: "network_interfaces", label: "Network Interfaces", icon: "globe",
      nav_module: "authorization", group: "Switching", group_order: 40, order: 20, status: :planned},

    # ── Transactions & Clearing ─────────────────────────────────────────────
    %{id: "tram_inquiry", label: "TRAM Inquiry", icon: "magnifying-glass",
      nav_module: "transactions", group: "Inquiry", group_order: 10, order: 10, status: :live},
    %{id: "transaction_search", label: "Transaction Search", icon: "table-cells",
      nav_module: "transactions", group: "Inquiry", group_order: 10, order: 20, status: :planned},

    %{id: "clearing_batches", label: "Clearing Batches", icon: "folder-open",
      nav_module: "transactions", group: "Clearing", group_order: 20, order: 10, status: :planned},
    %{id: "clearing_files", label: "Incoming & Outgoing Files", icon: "document-arrow-down",
      nav_module: "transactions", group: "Clearing", group_order: 20, order: 20, status: :planned},
    %{id: "mastercard_ipm", label: "Mastercard IPM", icon: "globe",
      nav_module: "transactions", group: "Clearing", group_order: 20, order: 30, status: :planned},
    %{id: "visa_base_ii", label: "Visa Base II", icon: "globe",
      nav_module: "transactions", group: "Clearing", group_order: 20, order: 40, status: :planned},

    %{id: "settlement_runs", label: "Settlement Runs", icon: "banknotes",
      nav_module: "transactions", group: "Settlement", group_order: 30, order: 10, status: :planned},
    %{id: "net_positions", label: "Net Positions", icon: "scale",
      nav_module: "transactions", group: "Settlement", group_order: 30, order: 20, status: :planned},
    %{id: "nostro_recon", label: "Nostro Reconciliation", icon: "building-library",
      nav_module: "transactions", group: "Settlement", group_order: 30, order: 30, status: :planned},

    %{id: "reconciliation_3way", label: "Three-Way Reconciliation", icon: "arrows-right-left",
      nav_module: "transactions", group: "Reconciliation", group_order: 40, order: 10, status: :planned},
    %{id: "recon_breaks", label: "Exception Breaks", icon: "exclamation-triangle",
      nav_module: "transactions", group: "Reconciliation", group_order: 40, order: 20, status: :planned},

    %{id: "interchange_rates", label: "Interchange Rates", icon: "receipt-percent",
      nav_module: "transactions", group: "Interchange & Fees", group_order: 50, order: 10, status: :planned},
    %{id: "scheme_fees", label: "Scheme Fees", icon: "currency",
      nav_module: "transactions", group: "Interchange & Fees", group_order: 50, order: 20, status: :planned},

    # ── Billing & Statements ────────────────────────────────────────────────
    %{id: "billing_cycles", label: "Billing Cycles", icon: "calendar",
      nav_module: "billing", group: "Cycle Processing", group_order: 10, order: 10, status: :planned},
    %{id: "cms_eod", label: "EOD Job Status", icon: "moon",
      nav_module: "billing", group: "Cycle Processing", group_order: 10, order: 20, status: :live},
    %{id: "cms_resegmentation", label: "Cycle Resegmentation", icon: "arrow-path",
      nav_module: "billing", group: "Cycle Processing", group_order: 10, order: 30, status: :live},

    %{id: "statement_generation", label: "Statement Generation", icon: "document-text",
      nav_module: "billing", group: "Statements", group_order: 20, order: 10, status: :planned},
    %{id: "statement_archive", label: "Statement Archive", icon: "archive-box",
      nav_module: "billing", group: "Statements", group_order: 20, order: 20, status: :planned},

    %{id: "interest_plans", label: "Interest Plans", icon: "receipt-percent",
      nav_module: "billing", group: "Interest & Fees", group_order: 30, order: 10, status: :planned},
    %{id: "fee_catalog", label: "Fee Catalog", icon: "tag",
      nav_module: "billing", group: "Interest & Fees", group_order: 30, order: 20, status: :planned},
    %{id: "fee_waivers", label: "Waivers & Adjustments", icon: "hand-raised",
      nav_module: "billing", group: "Interest & Fees", group_order: 30, order: 30, status: :planned},

    %{id: "payment_posting", label: "Payment Posting", icon: "banknotes",
      nav_module: "billing", group: "Payments", group_order: 40, order: 10, status: :planned},
    %{id: "autopay", label: "Autopay Mandates", icon: "arrow-path",
      nav_module: "billing", group: "Payments", group_order: 40, order: 20, status: :planned},
    %{id: "payment_allocation", label: "Payment Allocation", icon: "adjustments",
      nav_module: "billing", group: "Payments", group_order: 40, order: 30, status: :planned},

    %{id: "emi_plans", label: "EMI Plans", icon: "calculator",
      nav_module: "billing", group: "Instalments", group_order: 50, order: 10, status: :planned},
    %{id: "instalment_conversion", label: "Instalment Conversion", icon: "arrows-right-left",
      nav_module: "billing", group: "Instalments", group_order: 50, order: 20, status: :planned},

    # ── Collections & Recovery ──────────────────────────────────────────────
    %{id: "col", label: "Collections & Recovery", icon: "phone",
      nav_module: "collections", group: "Servicing", group_order: 10, order: 10, status: :live},
    %{id: "delinquency_queues", label: "Delinquency Queues", icon: "inbox",
      nav_module: "collections", group: "Servicing", group_order: 10, order: 20, status: :planned},
    %{id: "promise_to_pay", label: "Promise to Pay", icon: "hand-raised",
      nav_module: "collections", group: "Servicing", group_order: 10, order: 30, status: :planned},

    %{id: "dunning_strategies", label: "Dunning Strategies", icon: "megaphone",
      nav_module: "collections", group: "Treatment", group_order: 20, order: 10, status: :planned},
    %{id: "hardship_plans", label: "Hardship Plans", icon: "heart",
      nav_module: "collections", group: "Treatment", group_order: 20, order: 20, status: :planned},
    %{id: "settlement_offers", label: "Settlement Offers", icon: "scale",
      nav_module: "collections", group: "Treatment", group_order: 20, order: 30, status: :planned},

    %{id: "write_off", label: "Write-Off", icon: "archive-box",
      nav_module: "collections", group: "Recovery", group_order: 30, order: 10, status: :planned},
    %{id: "agency_placement", label: "Agency Placement", icon: "building-library",
      nav_module: "collections", group: "Recovery", group_order: 30, order: 20, status: :planned},
    %{id: "legal_cases", label: "Legal Cases", icon: "scale",
      nav_module: "collections", group: "Recovery", group_order: 30, order: 30, status: :planned},

    %{id: "collections_mi", label: "Collections MI", icon: "chart-bar",
      nav_module: "collections", group: "Management Information", group_order: 40, order: 10, status: :live},
    %{id: "roll_rate_analysis", label: "Roll Rate Analysis", icon: "trending-up",
      nav_module: "collections", group: "Management Information", group_order: 40, order: 20, status: :planned},

    # ── Disputes & Chargebacks ──────────────────────────────────────────────
    %{id: "dps", label: "Disputes (DPS)", icon: "scale",
      nav_module: "disputes", group: "Case Management", group_order: 10, order: 10, status: :live},
    %{id: "dispute_dashboard", label: "Dispute Dashboard", icon: "chart-pie",
      nav_module: "disputes", group: "Case Management", group_order: 10, order: 20, status: :planned},
    %{id: "case_search", label: "Case Search", icon: "magnifying-glass",
      nav_module: "disputes", group: "Case Management", group_order: 10, order: 30, status: :planned},

    %{id: "chargeback_cases", label: "Chargeback Cases", icon: "folder-open",
      nav_module: "disputes", group: "Chargebacks", group_order: 20, order: 10, status: :planned},
    %{id: "representment", label: "Representment", icon: "arrow-uturn-left",
      nav_module: "disputes", group: "Chargebacks", group_order: 20, order: 20, status: :planned},
    %{id: "arbitration", label: "Pre-Arb & Arbitration", icon: "scale",
      nav_module: "disputes", group: "Chargebacks", group_order: 20, order: 30, status: :planned},

    %{id: "reason_codes", label: "Reason Codes & SLA", icon: "tag",
      nav_module: "disputes", group: "Rules & SLA", group_order: 30, order: 10, status: :planned},
    %{id: "dispute_parameters", label: "Dispute Parameters", icon: "adjustments",
      nav_module: "disputes", group: "Rules & SLA", group_order: 30, order: 20, status: :planned},
    %{id: "dispute_automation", label: "Automation Rules", icon: "bolt",
      nav_module: "disputes", group: "Rules & SLA", group_order: 30, order: 30, status: :planned},

    %{id: "win_rate_analytics", label: "Win Rate Analytics", icon: "chart-bar",
      nav_module: "disputes", group: "Analytics", group_order: 40, order: 10, status: :planned},
    %{id: "recovery_analytics", label: "Recovery Analytics", icon: "trending-up",
      nav_module: "disputes", group: "Analytics", group_order: 40, order: 20, status: :planned},

    # ── Risk, Fraud & Compliance ────────────────────────────────────────────
    %{id: "fraud_cases", label: "Fraud Cases", icon: "flag",
      nav_module: "risk", group: "Fraud Operations", group_order: 10, order: 10, status: :planned},
    %{id: "fraud_alerts", label: "Alert Queue", icon: "bell",
      nav_module: "risk", group: "Fraud Operations", group_order: 10, order: 20, status: :planned},
    %{id: "fraud_rules", label: "Rule Engine", icon: "bolt",
      nav_module: "risk", group: "Fraud Operations", group_order: 10, order: 30, status: :planned},

    %{id: "sanctions_review", label: "Sanctions Review", icon: "eye",
      nav_module: "risk", group: "Screening", group_order: 20, order: 10, status: :planned},
    %{id: "aml_monitoring", label: "AML Monitoring", icon: "funnel",
      nav_module: "risk", group: "Screening", group_order: 20, order: 20, status: :planned},

    %{id: "application_scoring", label: "Application Scoring", icon: "calculator",
      nav_module: "risk", group: "Credit Risk", group_order: 30, order: 10, status: :planned},
    %{id: "behavioural_rescoring", label: "Behavioural Rescoring", icon: "trending-up",
      nav_module: "risk", group: "Credit Risk", group_order: 30, order: 20, status: :planned},
    %{id: "bureau_enquiries", label: "Bureau Enquiries", icon: "building-library",
      nav_module: "risk", group: "Credit Risk", group_order: 30, order: 30, status: :planned},

    %{id: "customer_exposure", label: "Customer Exposure", icon: "chart-pie",
      nav_module: "risk", group: "Exposure", group_order: 40, order: 10, status: :planned},
    %{id: "portfolio_risk", label: "Portfolio Risk", icon: "chart-bar",
      nav_module: "risk", group: "Exposure", group_order: 40, order: 20, status: :planned},

    # ── Finance & General Ledger ────────────────────────────────────────────
    %{id: "gl", label: "General Ledger", icon: "book-open",
      nav_module: "finance", group: "Ledger", group_order: 10, order: 10, status: :live},
    %{id: "journal_entries", label: "Journal Entries", icon: "list-bullet",
      nav_module: "finance", group: "Ledger", group_order: 10, order: 20, status: :planned},
    %{id: "chart_of_accounts", label: "Chart of Accounts", icon: "table-cells",
      nav_module: "finance", group: "Ledger", group_order: 10, order: 30, status: :planned},

    %{id: "accounting_periods", label: "Accounting Periods", icon: "calendar",
      nav_module: "finance", group: "Period Control", group_order: 20, order: 10, status: :planned},
    %{id: "period_close", label: "Period Close", icon: "lock-closed",
      nav_module: "finance", group: "Period Control", group_order: 20, order: 20, status: :planned},

    %{id: "trial_balance", label: "Trial Balance", icon: "scale",
      nav_module: "finance", group: "Reporting", group_order: 30, order: 10, status: :planned},
    %{id: "financial_statements", label: "Financial Statements", icon: "document-chart",
      nav_module: "finance", group: "Reporting", group_order: 30, order: 20, status: :planned},
    %{id: "gl_reconciliation", label: "GL Reconciliation", icon: "arrows-right-left",
      nav_module: "finance", group: "Reporting", group_order: 30, order: 30, status: :planned},

    %{id: "tax_configuration", label: "Tax Configuration", icon: "receipt-percent",
      nav_module: "finance", group: "Tax", group_order: 40, order: 10, status: :planned},

    # ── Loyalty & Rewards ───────────────────────────────────────────────────
    %{id: "loyalty_schemes", label: "Schemes & Plans", icon: "star",
      nav_module: "loyalty", group: "Programme", group_order: 10, order: 10, status: :planned},
    %{id: "earn_rules", label: "Earn Rules", icon: "bolt",
      nav_module: "loyalty", group: "Programme", group_order: 10, order: 20, status: :planned},
    %{id: "tier_management", label: "Tier Management", icon: "trophy",
      nav_module: "loyalty", group: "Programme", group_order: 10, order: 30, status: :planned},

    %{id: "points_ledger", label: "Points Ledger", icon: "list-bullet",
      nav_module: "loyalty", group: "Operations", group_order: 20, order: 10, status: :planned},
    %{id: "redemptions", label: "Redemptions", icon: "gift",
      nav_module: "loyalty", group: "Operations", group_order: 20, order: 20, status: :planned},
    %{id: "clawback", label: "Clawback", icon: "arrow-uturn-left",
      nav_module: "loyalty", group: "Operations", group_order: 20, order: 30, status: :planned},

    %{id: "merchant_funding", label: "Merchant Funding", icon: "building-office",
      nav_module: "loyalty", group: "Partners", group_order: 30, order: 10, status: :planned},
    %{id: "campaigns", label: "Campaigns & Offers", icon: "megaphone",
      nav_module: "loyalty", group: "Partners", group_order: 30, order: 20, status: :planned},

    # ── Platform Configuration ──────────────────────────────────────────────
    #
    # All four levels of the SYS -> BANK -> LOGO -> BLOCK cascade live together
    # here. Splitting LOGO/BLOCK out under Cards would read as "card product
    # setup", but they are two rungs of one parameter-resolution ladder, and
    # every downstream module reads them that way.
    %{id: "system", label: "System Parameters", icon: "cog",
      nav_module: "platform_config", group: "Parameter Hierarchy", group_order: 10, order: 10, status: :live},
    %{id: "organization", label: "Organizations", icon: "building-library",
      nav_module: "platform_config", group: "Parameter Hierarchy", group_order: 10, order: 20, status: :live},
    %{id: "logo", label: "Products / Logos", icon: "credit-card",
      nav_module: "platform_config", group: "Parameter Hierarchy", group_order: 10, order: 30, status: :live},
    %{id: "block", label: "Sub-Product Blocks", icon: "puzzle",
      nav_module: "platform_config", group: "Parameter Hierarchy", group_order: 10, order: 40, status: :live},

    %{id: "module_config", label: "Module Configuration", icon: "wrench",
      nav_module: "platform_config", group: "Framework", group_order: 20, order: 10, status: :live},

    %{id: "currencies_fx", label: "Currencies & FX", icon: "currency",
      nav_module: "platform_config", group: "Reference Data", group_order: 30, order: 10, status: :planned},
    %{id: "country_mcc", label: "Country & MCC", icon: "globe",
      nav_module: "platform_config", group: "Reference Data", group_order: 30, order: 20, status: :planned},
    %{id: "calendars", label: "Calendars", icon: "calendar",
      nav_module: "platform_config", group: "Reference Data", group_order: 30, order: 30, status: :planned},

    %{id: "interfaces", label: "Interfaces & Endpoints", icon: "link",
      nav_module: "platform_config", group: "Integration", group_order: 40, order: 10, status: :planned},
    %{id: "notification_templates", label: "Notification Templates", icon: "envelope",
      nav_module: "platform_config", group: "Integration", group_order: 40, order: 20, status: :planned},

    # ── Security & Access ───────────────────────────────────────────────────
    %{id: "approvals", label: "Approval Inbox", icon: "check-circle",
      nav_module: "security", group: "Approvals & Audit", group_order: 10, order: 10, status: :live},
    %{id: "audit_log", label: "Audit Trail", icon: "list-bullet",
      nav_module: "security", group: "Approvals & Audit", group_order: 10, order: 20, status: :live},

    %{id: "operators", label: "Operators", icon: "user-group",
      nav_module: "security", group: "Identity & Access", group_order: 20, order: 10, status: :live},
    %{id: "service_accounts", label: "Service Accounts", icon: "key",
      nav_module: "security", group: "Identity & Access", group_order: 20, order: 20, status: :live},
    %{id: "roles_permissions", label: "Roles & Permissions", icon: "shield-check",
      nav_module: "security", group: "Identity & Access", group_order: 20, order: 30, status: :planned},

    %{id: "password_policy", label: "Password Policy", icon: "lock-closed",
      nav_module: "security", group: "Security Policy", group_order: 30, order: 10, status: :planned},
    %{id: "sso_configuration", label: "SSO Configuration", icon: "link",
      nav_module: "security", group: "Security Policy", group_order: 30, order: 20, status: :planned}
  ]

  @nav_module_ids Enum.map(@nav_modules, & &1.id)
  @live_items Enum.filter(@items, &(&1.status == :live))
  @live_ids Enum.map(@live_items, & &1.id)

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "All nav modules, in dock order."
  def nav_modules, do: Enum.sort_by(@nav_modules, & &1.order)

  @doc "Every nav module id."
  def nav_module_ids, do: @nav_module_ids

  @doc "Fetch one nav module by id, or nil."
  def nav_module(id), do: Enum.find(@nav_modules, &(&1.id == id))

  @doc "Every navigation item, live and planned."
  def items, do: @items

  @doc "Only the items that have a screen behind them today."
  def live_items, do: @live_items

  @doc """
  The live-item registry as a map, keyed by id.

  This is the shape the permission guard test and AdminLive's breadcrumb
  expect, and the successor to the old `AdminLive.@modules` map.
  """
  def registry, do: Map.new(@live_items, &{&1.id, &1})

  @doc "Every live item's id — equivalently, every admin permission key."
  def live_ids, do: @live_ids

  @doc "True when `id` names a live screen."
  def live?(id), do: id in @live_ids

  @doc """
  True when `id` names a nav module rather than a leaf item — i.e. the dock
  landed on a module's placeholder page because it has no visible live item.
  """
  def nav_module_landing?(id), do: id in @nav_module_ids

  @doc """
  Sidebar contents for one nav module: `{group_label, items}` pairs in
  display order, with live items filtered by `visible` and planned items
  always shown.

  A group disappears entirely when the operator can see none of its live
  items and it has no planned ones — so an operator is never shown an empty
  heading.
  """
  def sidebar_groups(nav_module_id, visible) do
    @items
    |> Enum.filter(fn item ->
      item.nav_module == nav_module_id and
        (item.status == :planned or item.id in visible)
    end)
    |> Enum.sort_by(&{&1.group_order, &1.order})
    |> Enum.chunk_by(& &1.group)
    |> Enum.map(fn [%{group: group} | _] = chunk -> {group, chunk} end)
  end

  @doc """
  Where a dock tile links: the module's first visible live item, or the
  module's own id when it has none — which renders its placeholder page
  rather than a dead link.
  """
  def dock_target(nav_module_id, visible) do
    @items
    |> Enum.filter(fn item ->
      item.nav_module == nav_module_id and item.status == :live and item.id in visible
    end)
    |> Enum.sort_by(&{&1.group_order, &1.order})
    |> case do
      [first | _] -> first.id
      [] -> nav_module_id
    end
  end

  @doc """
  The nav module owning `active` — which may be a leaf item id or, when the
  dock landed on a placeholder, a nav module id already.
  """
  def nav_module_for(active) do
    case Enum.find(@items, &(&1.id == active)) do
      %{nav_module: nav_module} -> nav_module
      nil -> active
    end
  end

  @doc "Planned items of one nav module, in display order — the placeholder page's list."
  def planned_for(nav_module_id) do
    @items
    |> Enum.filter(&(&1.nav_module == nav_module_id and &1.status == :planned))
    |> Enum.sort_by(&{&1.group_order, &1.order})
  end
end
