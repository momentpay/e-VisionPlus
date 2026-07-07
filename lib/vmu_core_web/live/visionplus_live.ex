defmodule VmuCoreWeb.Live.VisionPlusLiveLegacy do
  @moduledoc """
  VisionPlus Terminal UI — Phoenix LiveView

  Implements the VisionPlus dual-mode interface:
    ⌨  Command Mode  — type transaction codes (CMS01, FAS01, DPS01 …) in the top bar
    ☰  Menu Mode     — click sidebar groups and screen links

  All 14 VisionPlus modules are accessible:
    FAS  CMS  CIF  CTA  IVR  DPS  TRAMS  COL  CDM  ASM  MBS  LMS  HCS  ITS

  Access at: /visionplus
  """

  use Phoenix.LiveView, layout: false
  import Ecto.Query
  require Logger

  alias VmuCore.Repo
  alias VmuCore.CMS.{Account, BalanceBucket}
  alias VmuCore.Shared.{Customer, ParameterEngine, ParameterWriter,
                          SysParameter, BankParameter, LogoParameter, BlockParameter}
  # CMS operator modules (referenced in new event handlers)
  alias VmuCore.CMS.{FeeWaiver, FinancialAdjustment}

  # ---------------------------------------------------------------------------
  # Screen catalogue
  # ---------------------------------------------------------------------------

  @screens %{
    # FAS
    "FAS01" => %{title: "Authorization Inquiry",  desc: "Real-time auth decision lookup by PAN or approval code", group: :fas},
    "FAS02" => %{title: "Authorization History",  desc: "Rolling 90-day auth log by account",                    group: :fas},
    # CMS
    "CMS01" => %{title: "Account Inquiry",        desc: "Full account summary — balances, status, cycle",        group: :cms},
    "CMS02" => %{title: "Account Maintenance",    desc: "Status change, limit adjustment, fee waiver",           group: :cms},
    "CMS03" => %{title: "GL Ledger Browser",      desc: "Double-entry GL entries by date / account",            group: :cms},
    "CMS04" => %{title: "Statement Viewer",       desc: "Cycle statements and minimum-payment schedules",        group: :cms},
    "CMS05" => %{title: "Card Inquiry",           desc: "Card status, expiry, emboss name, supplementary cards, block history", group: :cms},
    # CIF
    "CIF01" => %{title: "Customer Search",        desc: "Search customers by ID, name or national ID",          group: :cif},
    "CIF02" => %{title: "KYC Management",         desc: "KYC tier, ID verification, risk flag management",      group: :cif},
    # CTA
    "CTA01" => %{title: "Card Stock Management",  desc: "BIN stock levels, reorder thresholds",                 group: :cta},
    "CTA02" => %{title: "Embossing Orders",       desc: "Card personalisation queue and delivery tracking",      group: :cta},
    "CTA03" => %{title: "Card Activation / PIN",  desc: "Activate cards, reset PIN, replace card",              group: :cta},
    # IVR
    "IVR01" => %{title: "Session Monitor",        desc: "Live IVR session state and channel status",            group: :ivr},
    "IVR02" => %{title: "OTP Management",         desc: "HOTP/TOTP seed management and OTP audit",              group: :ivr},
    # DPS
    "DPS01" => %{title: "Dispute Management",     desc: "File, track and resolve cardholder disputes",          group: :dps},
    "DPS02" => %{title: "Chargeback Tracking",    desc: "Chargeback lifecycle — network deadlines and SLA",     group: :dps},
    # TRAMS
    "TRAMS01" => %{title: "Clearing Records",     desc: "IPM / Base II clearing file browser",                  group: :trams},
    "TRAMS02" => %{title: "IPM Processing Status", desc: "Broadway pipeline throughput and error rates",         group: :trams},
    # COL
    "COL01" => %{title: "Collection Cases",       desc: "Active collection queue, dunning status, promises",    group: :col},
    "COL02" => %{title: "Write-off Management",   desc: "Write-off decisions and recovery ledger",              group: :col},
    # CDM
    "CDM01" => %{title: "Application Queue",      desc: "Pending credit applications and scoring output",       group: :cdm},
    "CDM02" => %{title: "Underwriting Decisions", desc: "Bureau results, DSR, limit allocation history",        group: :cdm},
    # ASM
    "ASM01" => %{title: "Operator Management",    desc: "Create / suspend operators, assign roles",             group: :asm},
    "ASM02" => %{title: "System Parameters",      desc: "SYS→BANK→LOGO→BLOCK ETS cache viewer + refresh",      group: :asm},
    "ASM03" => %{title: "Audit Log",              desc: "Operator action audit trail",                          group: :asm},
    "ASM04" => %{title: "SYS Parameter Setup",   desc: "Create or update the root SYS control record",         group: :asm},
    "ASM05" => %{title: "BANK Parameter Setup",  desc: "Create or update a BANK control record",               group: :asm},
    "ASM06" => %{title: "Logo / Product Setup",  desc: "Create or update a LOGO card-product record",          group: :asm},
    "ASM07" => %{title: "Block Code Setup",       desc: "Create or update a BLOCK sub-product override",        group: :asm},
    "ASM08" => %{title: "STIP Threshold Setup",  desc: "Set stand-in processing limits on a LOGO record",      group: :asm},
    # MBS
    "MBS01" => %{title: "Merchant Management",    desc: "Merchant hierarchy and MDR tier assignment",           group: :mbs},
    "MBS02" => %{title: "Terminal Management",    desc: "POS terminal registration and status",                 group: :mbs},
    "MBS03" => %{title: "MDR Configuration",      desc: "Merchant discount rate and scheme fee setup",          group: :mbs},
    # LMS
    "LMS01" => %{title: "Scheme Inquiry",         desc: "Loyalty scheme, group, plan and rate tier browser",   group: :lms},
    "LMS02" => %{title: "Account Enrollment",     desc: "Enroll accounts to loyalty schemes",                  group: :lms},
    "LMS03" => %{title: "Points Inquiry",         desc: "Points balance, ledger history, expiry schedule",     group: :lms},
    "LMS04" => %{title: "Redemption Processing",  desc: "Manual redemption, history, merchant settlement",     group: :lms},
    # HCS
    "HCS01" => %{title: "Company Management",     desc: "Corporate company record, credit pool, KYC",          group: :hcs},
    "HCS02" => %{title: "Employee Cards",         desc: "Employee card list, sub-limits, cost centres",        group: :hcs},
    "HCS03" => %{title: "Spending Controls",      desc: "MCC block/allow, channel block, daily caps",          group: :hcs},
    # ITS
    "ITS01" => %{title: "Copy Requests",          desc: "Network copy / retrieval request lifecycle",          group: :its},
    "ITS02" => %{title: "Fee Claims",             desc: "Interchange income / expense per clearing record",    group: :its},
    "ITS03" => %{title: "Financial Adjustments",  desc: "FAR (Financial Adjustment Records) from Visa / MC",  group: :its},
    # PCM
    "PCM01" => %{title: "Plan Segment Setup",    desc: "Define EMI instalment plans for card products",         group: :pcm},
    "PCM02" => %{title: "Loyalty Scheme Setup",  desc: "Review and configure loyalty scheme / plan tiers",      group: :pcm},
    "PCM03" => %{title: "Fee Schedule",          desc: "Edit per-logo fee amounts (annual, late, overlimit…)",  group: :pcm}
  }

  @sidebar_groups [
    {:fas,   "⚡", "FAS",   "Authorization",     ["FAS01", "FAS02"]},
    {:cms,   "💳", "CMS",   "Card Management",   ["CMS01", "CMS02", "CMS03", "CMS04", "CMS05"]},
    {:cif,   "👤", "CIF",   "Customer",          ["CIF01", "CIF02"]},
    {:cta,   "🃏", "CTA",   "Card Admin",        ["CTA01", "CTA02", "CTA03"]},
    {:ivr,   "📞", "IVR",   "Telephony",         ["IVR01", "IVR02"]},
    {:dps,   "⚖️", "DPS",   "Disputes",          ["DPS01", "DPS02"]},
    {:trams, "🔄", "TRAMS", "Clearing",          ["TRAMS01", "TRAMS02"]},
    {:col,   "📋", "COL",   "Collections",       ["COL01", "COL02"]},
    {:cdm,   "📊", "CDM",   "Credit",            ["CDM01", "CDM02"]},
    {:asm,   "🔧", "ASM",   "System Admin",      ["ASM01", "ASM02", "ASM03", "ASM04", "ASM05", "ASM06", "ASM07", "ASM08"]},
    {:mbs,   "🏪", "MBS",   "Merchant",          ["MBS01", "MBS02", "MBS03"]},
    {:lms,   "🌟", "LMS",   "Loyalty",           ["LMS01", "LMS02", "LMS03", "LMS04"]},
    {:hcs,   "🏢", "HCS",   "Corporate",         ["HCS01", "HCS02", "HCS03"]},
    {:its,   "💰", "ITS",   "Interchange",       ["ITS01", "ITS02", "ITS03"]},
    {:pcm,   "⚙️", "PCM",   "Product Config",    ["PCM01", "PCM02", "PCM03"]}
  ]

  # ---------------------------------------------------------------------------
  # Mount
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    expanded = Map.new(@sidebar_groups, fn {key, _, _, _, _} -> {key, false} end)

    {:ok,
     assign(socket,
       screen:         nil,
       cmd_input:      "",
       cmd_error:      nil,
       sidebar_open:   expanded,
       sidebar_groups: @sidebar_groups,
       screens:        @screens,
       # shared form/result state reset per screen navigation
       query:          %{},
       results:        nil,
       action_result:  nil,
       # screen-specific sub-states
       account:        nil,
       bucket:         nil,
       block_history:  [],
       supp_cards:     [],
       page_title:     "VisionPlus",
       # console mode
       console_mode:    false,
       console_history: [],
       console_input:   ""
     )}
  end

  # ---------------------------------------------------------------------------
  # Events — command bar
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("cmd_submit", %{"cmd" => raw}, socket) do
    code = raw |> String.trim() |> String.upcase()

    if Map.has_key?(@screens, code) do
      {:noreply,
       socket
       |> assign(screen: code, cmd_input: "", cmd_error: nil,
                 query: %{}, results: nil, action_result: nil,
                 account: nil, bucket: nil, block_history: [], supp_cards: [])
       |> open_group_for(code)}
    else
      {:noreply, assign(socket, cmd_error: "Unknown screen code: #{code}  — type 'HELP' for list")}
    end
  end

  def handle_event("cmd_input", %{"value" => v}, socket) do
    {:noreply, assign(socket, cmd_input: v, cmd_error: nil)}
  end

  # Handle HELP command
  def handle_event("cmd_submit", %{"cmd" => "help"}, socket),
    do: handle_event("cmd_submit", %{"cmd" => "HELP"}, socket)

  # ---------------------------------------------------------------------------
  # Events — sidebar navigation
  # ---------------------------------------------------------------------------

  def handle_event("nav", %{"screen" => screen}, socket) do
    {:noreply,
     socket
     |> assign(screen: screen, query: %{}, results: nil, action_result: nil,
               account: nil, bucket: nil, block_history: [], supp_cards: [])
     |> open_group_for(screen)}
  end

  def handle_event("toggle_group", %{"group" => group}, socket) do
    key = String.to_existing_atom(group)
    open = Map.update!(socket.assigns.sidebar_open, key, &(!&1))
    {:noreply, assign(socket, sidebar_open: open)}
  end

  # ---------------------------------------------------------------------------
  # Events — FAS
  # ---------------------------------------------------------------------------

  def handle_event("fas_inquiry", %{"pan" => pan, "amount" => amt, "mcc" => mcc, "channel" => ch}, socket) do
    result =
      try do
        case VmuCore.FAS.Authorization.process(%{
          pan:     pan,
          amount:  Decimal.new(amt),
          channel: String.to_existing_atom(ch),
          mcc:     mcc
        }) do
          {:ok, rc, code} -> {:ok,    "APPROVED", rc, code}
          {:error, rc}    -> {:error, "DECLINED", rc, ""}
        end
      rescue
        e -> {:error, "ERROR", "96", Exception.message(e)}
      end

    {:noreply, assign(socket, results: {:fas_result, result}, action_result: nil)}
  end

  def handle_event("fas_history", %{"account_id" => aid}, socket) do
    rows = Repo.all(
      from e in "fas_auth_log",
        where: e.account_id == ^aid,
        order_by: [desc: e.inserted_at],
        limit: 30,
        select: %{
          inserted_at: e.inserted_at,
          pan_token:   e.pan_token,
          amount:      e.amount,
          rc:          e.response_code,
          channel:     e.channel,
          mcc:         e.mcc
        }
    ) |> safe_query([])

    {:noreply, assign(socket, results: {:fas_history, rows})}
  end

  # ---------------------------------------------------------------------------
  # Events — CMS
  # ---------------------------------------------------------------------------

  def handle_event("cms_account_lookup", %{"id" => id}, socket) do
    account =
      Repo.one(
        from a in Account,
          where: a.account_id == ^String.trim(id),
          preload: []
      )

    {:noreply, assign(socket, account: account, results: {:cms_account, account}, action_result: nil)}
  end

  def handle_event("cms_list_accounts", _, socket) do
    rows = Repo.all(
      from a in Account,
        order_by: [desc: a.inserted_at],
        limit: 25,
        select: %{
          account_id:     a.account_id,
          account_status: a.account_status,
          credit_limit:   a.credit_limit,
          open_to_buy:    a.open_to_buy,
          delinquency_bucket: a.delinquency_bucket
        }
    )

    {:noreply, assign(socket, results: {:cms_list, rows})}
  end

  def handle_event("cms_gl_browse", %{"account_id" => aid, "date_from" => from, "date_to" => to}, socket) do
    base = from e in "cms_ledger_entries",
             order_by: [desc: e.posting_date],
             limit: 50,
             select: %{
               posting_date:     e.posting_date,
               transaction_code: e.transaction_code,
               dr_amount:        e.dr_amount,
               cr_amount:        e.cr_amount,
               narrative:        e.narrative,
               idempotency_key:  e.idempotency_key
             }

    q =
      if String.trim(aid) != "" do
        from e in base, where: e.account_id == ^String.trim(aid)
      else
        base
      end

    q =
      if String.trim(from) != "" do
        from e in q, where: e.posting_date >= ^from
      else
        q
      end

    q =
      if String.trim(to) != "" do
        from e in q, where: e.posting_date <= ^to
      else
        q
      end

    rows = safe_query(q, [])
    {:noreply, assign(socket, results: {:cms_gl, rows})}
  end

  def handle_event("cms_action", %{"account_id" => aid, "action" => action, "value" => val, "reason" => reason}, socket) do
    op = %{name: "VisionPlus UI", id: "UI001", role: :sysadmin}
    result =
      case action do
        "block"      -> VmuCore.ASM.OperatorPortal.block_account(aid, reason, op)
        "unblock"    -> VmuCore.ASM.OperatorPortal.unblock_account(aid, reason, op)
        "close"      -> VmuCore.ASM.OperatorPortal.close_account(aid, reason, op)
        "set_limit"  ->
          try do
            VmuCore.ASM.OperatorPortal.adjust_limit(aid, Decimal.new(val), reason, op)
          rescue
            e -> {:error, Exception.message(e)}
          end
        "waive_fee"  ->
          try do
            VmuCore.ASM.OperatorPortal.waive_fee(aid, Decimal.new(val), reason, op)
          rescue
            e -> {:error, Exception.message(e)}
          end
        _ -> {:error, :unknown_action}
      end

    {:noreply, assign(socket, action_result: result)}
  end

  # ── CMS01 enhanced: fetch balance bucket breakdown ─────────────────────────
  def handle_event("cms_bucket_lookup", %{"account_id" => aid}, socket) do
    bucket =
      Repo.one(
        from b in BalanceBucket,
          where: b.account_id == ^String.trim(aid),
          order_by: [desc: b.balance_date],
          limit: 1
      )

    {:noreply, assign(socket, bucket: bucket)}
  end

  # ── CMS01 enhanced: fetch supplementary cards ──────────────────────────────
  def handle_event("cms_supp_lookup", %{"account_id" => aid}, socket) do
    rows =
      Repo.all(
        from s in "supplementary_cards",
          where: s.primary_account_id == ^String.trim(aid),
          order_by: [asc: s.inserted_at],
          select: %{
            id:                    s.id,
            supplementary_account_id: s.supplementary_account_id,
            relationship:          s.relationship,
            emboss_name:           s.emboss_name,
            status:                s.status,
            inserted_at:           s.inserted_at
          }
      ) |> safe_query([])

    {:noreply, assign(socket, supp_cards: rows)}
  end

  # ── CMS01 / CMS05: fetch block code history ────────────────────────────────
  def handle_event("cms_block_history", %{"account_id" => aid}, socket) do
    rows =
      Repo.all(
        from h in "cms_block_code_history",
          where: h.account_id == ^String.trim(aid),
          order_by: [desc: h.applied_at],
          limit: 20,
          select: %{
            block_code:    h.block_code,
            reason_code:   h.reason_code,
            narrative:     h.narrative,
            operator_id:   h.operator_id,
            operator_role: h.operator_role,
            applied_at:    h.applied_at
          }
      ) |> safe_query([])

    {:noreply, assign(socket, block_history: rows)}
  end

  # ── CMS02 enhanced: fee waiver with 4-eyes ────────────────────────────────
  def handle_event("cms_fee_waiver",
    %{"account_id" => aid, "amount" => amt, "reason" => reason,
      "operator_id" => op_id, "supervisor_id" => sup_id}, socket) do

    result =
      try do
        VmuCore.CMS.FeeWaiver.waive(%{
          account_id:    String.trim(aid),
          amount:        Decimal.new(amt),
          reason:        reason,
          operator_id:   String.trim(op_id),
          supervisor_id: String.trim(sup_id)
        })
      rescue
        e -> {:error, Exception.message(e)}
      end

    {:noreply, assign(socket, action_result: result)}
  end

  # ── CMS02 enhanced: manual financial adjustment ────────────────────────────
  def handle_event("cms_fin_adjustment",
    %{"account_id" => aid, "direction" => dir, "amount" => amt,
      "reason" => reason, "operator_id" => op_id, "supervisor_id" => sup_id}, socket) do

    result =
      try do
        params = %{
          account_id:    String.trim(aid),
          amount:        Decimal.new(amt),
          reason:        reason,
          operator_id:   String.trim(op_id),
          supervisor_id: String.trim(sup_id),
          reference_id:  "UI-#{System.system_time(:millisecond)}",
          posting_date:  Date.utc_today()
        }

        case dir do
          "credit" -> VmuCore.CMS.FinancialAdjustment.post_credit(params)
          "debit"  -> VmuCore.CMS.FinancialAdjustment.post_debit(params)
          _        -> {:error, :invalid_direction}
        end
      rescue
        e -> {:error, Exception.message(e)}
      end

    {:noreply, assign(socket, action_result: result)}
  end

  # ── CMS02: temporary credit limit (4G) ─────────────────────────────────────
  def handle_event("cms_temp_limit",
    %{"account_id" => aid, "temp_limit" => tl_str, "expiry_date" => exp_str,
      "operator_id" => op_id, "supervisor_id" => sup_id} = params, socket) do

    result =
      try do
        VmuCore.CMS.TempLimit.grant(%{
          account_id:    String.trim(aid),
          temp_limit:    Decimal.new(tl_str),
          expiry_date:   Date.from_iso8601!(exp_str),
          reason:        Map.get(params, "reason", ""),
          operator_id:   String.trim(op_id),
          supervisor_id: String.trim(sup_id)
        })
      rescue
        e -> {:error, Exception.message(e)}
      end

    {:noreply, assign(socket, action_result: result)}
  end

  # ── CMS05: card inquiry (account + supplementary + block history) ──────────
  def handle_event("cms_card_inquiry", %{"account_id" => aid}, socket) do
    acc_id = String.trim(aid)

    account =
      Repo.one(from a in Account, where: a.account_id == ^acc_id)

    supp_cards =
      Repo.all(
        from s in "supplementary_cards",
          where: s.primary_account_id == ^acc_id,
          order_by: [asc: s.inserted_at],
          select: %{
            supplementary_account_id: s.supplementary_account_id,
            relationship:             s.relationship,
            emboss_name:              s.emboss_name,
            status:                   s.status,
            inserted_at:              s.inserted_at
          }
      ) |> safe_query([])

    block_history =
      Repo.all(
        from h in "cms_block_code_history",
          where: h.account_id == ^acc_id,
          order_by: [desc: h.applied_at],
          limit: 20,
          select: %{
            block_code:    h.block_code,
            reason_code:   h.reason_code,
            narrative:     h.narrative,
            operator_id:   h.operator_id,
            operator_role: h.operator_role,
            applied_at:    h.applied_at
          }
      ) |> safe_query([])

    {:noreply, assign(socket,
      account: account,
      supp_cards: supp_cards,
      block_history: block_history,
      results: {:cms_account, account}
    )}
  end

  # ---------------------------------------------------------------------------
  # Events — CIF
  # ---------------------------------------------------------------------------

  def handle_event("cif_search", %{"q" => q}, socket) do
    term = "%#{String.trim(q)}%"
    rows = Repo.all(
      from c in Customer,
        where:
          ilike(c.full_name, ^term) or
          ilike(c.national_id, ^term) or
          ilike(c.customer_id, ^term),
        limit: 20,
        select: %{
          customer_id: c.customer_id,
          full_name:   c.full_name,
          national_id: c.national_id,
          kyc_tier:    c.kyc_tier,
          risk_flag:   c.risk_flag
        }
    ) |> safe_query([])

    {:noreply, assign(socket, results: {:cif_list, rows})}
  end

  # ---------------------------------------------------------------------------
  # Events — ASM
  # ---------------------------------------------------------------------------

  def handle_event("asm_param_refresh", _, socket) do
    try do
      ParameterEngine.refresh_all()
      {:noreply, assign(socket, action_result: {:ok, "ETS cache refreshed — all parameters reloaded from database"})}
    rescue
      e -> {:noreply, assign(socket, action_result: {:error, Exception.message(e)})}
    end
  end

  def handle_event("asm_audit_load", %{"account_id" => aid}, socket) do
    base = from a in "cms_operator_audit",
             order_by: [desc: a.performed_at],
             limit: 40,
             select: %{
               performed_at:  a.performed_at,
               operator_id:   a.operator_id,
               operator_role: a.operator_role,
               action:        a.action,
               subject:       a.subject
             }

    q =
      if String.trim(aid) != "" do
        from a in base, where: a.subject == ^String.trim(aid)
      else
        base
      end

    rows = safe_query(q, [])
    {:noreply, assign(socket, results: {:asm_audit, rows})}
  end

  # ---------------------------------------------------------------------------
  # Events — ASM04 SYS Parameter Setup
  # ---------------------------------------------------------------------------

  def handle_event("asm04_load", %{"sys_id" => sys_id}, socket) do
    rec = Repo.get(SysParameter, String.trim(sys_id))
    result = if rec, do: {:asm04_record, rec}, else: {:asm04_not_found, sys_id}
    {:noreply, assign(socket, results: result, action_result: nil)}
  end

  def handle_event("asm04_save", params, socket) do
    sys_id = String.trim(params["sys_id"] || "")
    attrs = %{
      sys_id:              sys_id,
      description:         params["description"],
      base_currency:       String.trim(params["base_currency"] || "AED"),
      batch_controls:      parse_json(params["batch_controls"]),
      cycle_controls:      parse_json(params["cycle_controls"]),
      global_status_codes: parse_csv_list(params["global_status_codes"]),
      posting_rules:       parse_json(params["posting_rules"])
    }
    result =
      case Repo.get(SysParameter, sys_id) do
        nil ->
          cs = SysParameter.changeset(%SysParameter{}, attrs)
          case Repo.insert(cs) do
            {:ok, _} ->
              ParameterEngine.refresh_all()
              {:ok, "SYS #{sys_id} created — ETS cache refreshed"}
            {:error, cs} -> {:error, changeset_errors(cs)}
          end
        existing ->
          case ParameterWriter.update_sys(existing, attrs, operator_id: "UI") do
            {:ok, _}     -> {:ok, "SYS #{sys_id} updated — ETS cache refreshed"}
            {:error, cs} -> {:error, changeset_errors(cs)}
          end
      end
    {:noreply, assign(socket, action_result: result)}
  end

  # ---------------------------------------------------------------------------
  # Events — ASM05 BANK Parameter Setup
  # ---------------------------------------------------------------------------

  def handle_event("asm05_load", %{"bank_id" => bank_id, "sys_id" => sys_id}, socket) do
    rec = Repo.get_by(BankParameter,
      bank_id: String.trim(bank_id), sys_id: String.trim(sys_id))
    result = if rec, do: {:asm05_record, rec}, else: {:asm05_not_found, bank_id}
    {:noreply, assign(socket, results: result, action_result: nil)}
  end

  def handle_event("asm05_save", params, socket) do
    bank_id = String.trim(params["bank_id"] || "")
    sys_id  = String.trim(params["sys_id"] || "")
    attrs = %{
      bank_id:             bank_id,
      sys_id:              sys_id,
      description:         params["description"],
      country_code:        String.trim(params["country_code"] || "ARE"),
      tax_rule:            parse_json(params["tax_rule"]),
      gl_mapping_profile:  params["gl_mapping_profile"],
      delinquency_rules:   parse_json(params["delinquency_rules"]),
      settlement_calendar: parse_json(params["settlement_calendar"]),
      swift_bic:           params["swift_bic"],
      base_currency:       String.trim(params["base_currency"] || "AED"),
      billing_timezone:    params["billing_timezone"],
      regulatory_regime:   params["regulatory_regime"],
      org_name:            params["org_name"]
    }
    result =
      case Repo.get_by(BankParameter, bank_id: bank_id, sys_id: sys_id) do
        nil ->
          cs = BankParameter.changeset(%BankParameter{}, attrs)
          case Repo.insert(cs) do
            {:ok, _} ->
              ParameterEngine.refresh_all()
              {:ok, "BANK #{bank_id}/#{sys_id} created — ETS cache refreshed"}
            {:error, cs} -> {:error, changeset_errors(cs)}
          end
        existing ->
          case ParameterWriter.update_bank(existing, attrs, operator_id: "UI") do
            {:ok, _}     -> {:ok, "BANK #{bank_id}/#{sys_id} updated — ETS cache refreshed"}
            {:error, cs} -> {:error, changeset_errors(cs)}
          end
      end
    {:noreply, assign(socket, action_result: result)}
  end

  # ---------------------------------------------------------------------------
  # Events — ASM06 Logo / Product Parameter Setup
  # ---------------------------------------------------------------------------

  def handle_event("asm06_load", %{"logo_id" => logo_id, "sys_id" => sys_id, "bank_id" => bank_id}, socket) do
    rec = Repo.get_by(LogoParameter,
      logo_id: String.trim(logo_id), sys_id: String.trim(sys_id), bank_id: String.trim(bank_id))
    result = if rec, do: {:asm06_record, rec}, else: {:asm06_not_found, logo_id}
    {:noreply, assign(socket, results: result, action_result: nil)}
  end

  def handle_event("asm06_save", params, socket) do
    logo_id = String.trim(params["logo_id"] || "")
    sys_id  = String.trim(params["sys_id"] || "")
    bank_id = String.trim(params["bank_id"] || "")
    attrs = %{
      logo_id:              logo_id,
      sys_id:               sys_id,
      bank_id:              bank_id,
      bin_prefix:           String.trim(params["bin_prefix"] || ""),
      description:          params["description"],
      purchase_apr:         decimal_or_nil(params["purchase_apr"]),
      cash_apr:             decimal_or_nil(params["cash_apr"]),
      penalty_apr:          decimal_or_nil(params["penalty_apr"]),
      penalty_apr_dpd_trigger: int_or_nil(params["penalty_apr_dpd_trigger"]),
      promo_apr:            decimal_or_nil(params["promo_apr"]),
      annual_fee:           decimal_or_nil(params["annual_fee"]),
      late_fee:             decimal_or_nil(params["late_fee"]),
      overlimit_fee:        decimal_or_nil(params["overlimit_fee"]),
      replacement_fee:      decimal_or_nil(params["replacement_fee"]),
      returned_payment_fee: decimal_or_nil(params["returned_payment_fee"]),
      card_replacement_fee: decimal_or_nil(params["card_replacement_fee"]),
      min_payment_pct:      decimal_or_nil(params["min_payment_pct"]),
      min_payment_floor:    decimal_or_nil(params["min_payment_floor"]),
      grace_days:           int_or_nil(params["grace_days"]),
      cash_limit_pct:       decimal_or_nil(params["cash_limit_pct"]),
      statement_cycle_days: int_or_nil(params["statement_cycle_days"]),
      ecom_enabled:         params["ecom_enabled"] == "true",
      atm_enabled:          params["atm_enabled"] == "true",
      intl_enabled:         params["intl_enabled"] == "true",
      contactless_enabled:  params["contactless_enabled"] == "true",
      credit_limit_default: decimal_or_nil(params["credit_limit_default"]),
      credit_limit_max:     decimal_or_nil(params["credit_limit_max"]),
      stip_enabled:         params["stip_enabled"] == "true",
      stip_floor_limit:     decimal_or_nil(params["stip_floor_limit"]),
      stip_max_amount:      decimal_or_nil(params["stip_max_amount"])
    }
    result =
      case Repo.get_by(LogoParameter, logo_id: logo_id, sys_id: sys_id, bank_id: bank_id) do
        nil ->
          case ParameterWriter.create_logo(attrs, operator_id: "UI") do
            {:ok, _}     -> {:ok, "LOGO #{logo_id} created — ETS cache refreshed"}
            {:error, cs} -> {:error, changeset_errors(cs)}
          end
        existing ->
          case ParameterWriter.update_logo(existing, attrs, operator_id: "UI") do
            {:ok, _}     -> {:ok, "LOGO #{logo_id} updated — ETS cache refreshed"}
            {:error, cs} -> {:error, changeset_errors(cs)}
          end
      end
    {:noreply, assign(socket, action_result: result)}
  end

  # ---------------------------------------------------------------------------
  # Events — ASM07 Block Code Setup
  # ---------------------------------------------------------------------------

  def handle_event("asm07_load", params, socket) do
    rec = Repo.get_by(BlockParameter,
      block_id: String.trim(params["block_id"] || ""),
      sys_id:   String.trim(params["sys_id"] || ""),
      bank_id:  String.trim(params["bank_id"] || ""),
      logo_id:  String.trim(params["logo_id"] || ""))
    result = if rec, do: {:asm07_record, rec}, else: {:asm07_not_found, params["block_id"]}
    {:noreply, assign(socket, results: result, action_result: nil)}
  end

  def handle_event("asm07_save", params, socket) do
    block_id = String.trim(params["block_id"] || "")
    sys_id   = String.trim(params["sys_id"] || "")
    bank_id  = String.trim(params["bank_id"] || "")
    logo_id  = String.trim(params["logo_id"] || "")
    attrs = %{
      block_id:                block_id,
      sys_id:                  sys_id,
      bank_id:                 bank_id,
      logo_id:                 logo_id,
      apr_percentage:          decimal_or_nil(params["apr_percentage"]),
      cash_apr_percentage:     decimal_or_nil(params["cash_apr_percentage"]),
      cash_advance_fee_percent: decimal_or_nil(params["cash_advance_fee_percent"]),
      credit_limit_default:    decimal_or_nil(params["credit_limit_default"])
    }
    result =
      case Repo.get_by(BlockParameter,
             block_id: block_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id) do
        nil ->
          case ParameterWriter.create_block(attrs, operator_id: "UI") do
            {:ok, _}     -> {:ok, "BLOCK #{block_id} created — ETS cache refreshed"}
            {:error, cs} -> {:error, changeset_errors(cs)}
          end
        existing ->
          case ParameterWriter.update_block(existing, attrs, operator_id: "UI") do
            {:ok, _}     -> {:ok, "BLOCK #{block_id} updated — ETS cache refreshed"}
            {:error, cs} -> {:error, changeset_errors(cs)}
          end
      end
    {:noreply, assign(socket, action_result: result)}
  end

  # ---------------------------------------------------------------------------
  # Events — ASM08 STIP Threshold Setup
  # ---------------------------------------------------------------------------

  def handle_event("asm08_load", params, socket) do
    rec = Repo.get_by(LogoParameter,
      logo_id: String.trim(params["logo_id"] || ""),
      sys_id:  String.trim(params["sys_id"] || ""),
      bank_id: String.trim(params["bank_id"] || ""))
    result = if rec, do: {:asm08_record, rec}, else: {:asm08_not_found, params["logo_id"]}
    {:noreply, assign(socket, results: result, action_result: nil)}
  end

  def handle_event("asm08_save", params, socket) do
    logo_id = String.trim(params["logo_id"] || "")
    sys_id  = String.trim(params["sys_id"] || "")
    bank_id = String.trim(params["bank_id"] || "")
    stip_attrs = %{
      stip_enabled:     params["stip_enabled"] == "true",
      stip_floor_limit: decimal_or_nil(params["stip_floor_limit"]),
      stip_max_amount:  decimal_or_nil(params["stip_max_amount"])
    }
    result =
      case Repo.get_by(LogoParameter, logo_id: logo_id, sys_id: sys_id, bank_id: bank_id) do
        nil ->
          {:error, "LOGO #{logo_id}/#{sys_id}/#{bank_id} not found — create it in ASM06 first"}
        existing ->
          case ParameterWriter.update_logo(existing, stip_attrs, operator_id: "UI") do
            {:ok, _}     -> {:ok, "STIP thresholds updated on LOGO #{logo_id} — ETS cache refreshed"}
            {:error, cs} -> {:error, changeset_errors(cs)}
          end
      end
    {:noreply, assign(socket, action_result: result)}
  end

  # ---------------------------------------------------------------------------
  # Events — PCM01 Plan Segment Setup
  # ---------------------------------------------------------------------------

  def handle_event("pcm01_list", _, socket) do
    rows = safe_query(
      from(p in "plan_segments",
        order_by: [asc: p.plan_code],
        limit: 50,
        select: %{
          id:            p.id,
          plan_code:     p.plan_code,
          logo_id:       p.logo_id,
          tenure:        p.tenure_months,
          interest_rate: p.interest_rate,
          min_amount:    p.min_transaction_amount,
          status:        p.status
        }),
      [])
    {:noreply, assign(socket, results: {:pcm01_list, rows}, action_result: nil)}
  end

  def handle_event("pcm01_save", params, socket) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    row = %{
      plan_code:              String.trim(params["plan_code"] || ""),
      logo_id:                String.trim(params["logo_id"] || ""),
      tenure_months:          int_or_nil(params["tenure_months"]) || 0,
      interest_rate:          params["interest_rate"],
      processing_fee_percent: params["processing_fee_percent"],
      min_transaction_amount: params["min_transaction_amount"],
      status:                 params["status"] || "ACTIVE",
      inserted_at:            now,
      updated_at:             now
    }
    result =
      try do
        case Repo.insert_all("plan_segments", [row], on_conflict: :nothing) do
          {1, _} -> {:ok, "Plan segment '#{row.plan_code}' created"}
          {0, _} -> {:error, "Plan code '#{row.plan_code}' already exists"}
        end
      rescue
        e -> {:error, Exception.message(e)}
      end
    {:noreply, assign(socket, action_result: result)}
  end

  # ---------------------------------------------------------------------------
  # Events — PCM02 Loyalty Scheme Setup
  # ---------------------------------------------------------------------------

  def handle_event("pcm02_list", _, socket) do
    rows = safe_query(
      from(s in "lms_schemes",
        order_by: [asc: s.scheme_code],
        limit: 50,
        select: %{
          id:          s.id,
          scheme_code: s.scheme_code,
          name:        s.name,
          status:      s.status
        }),
      [])
    {:noreply, assign(socket, results: {:pcm02_list, rows}, action_result: nil)}
  end

  # ---------------------------------------------------------------------------
  # Events — PCM03 Fee Schedule
  # ---------------------------------------------------------------------------

  def handle_event("pcm03_load", params, socket) do
    rec = Repo.get_by(LogoParameter,
      logo_id: String.trim(params["logo_id"] || ""),
      sys_id:  String.trim(params["sys_id"] || ""),
      bank_id: String.trim(params["bank_id"] || ""))
    result = if rec, do: {:pcm03_record, rec}, else: {:pcm03_not_found, params["logo_id"]}
    {:noreply, assign(socket, results: result, action_result: nil)}
  end

  def handle_event("pcm03_save", params, socket) do
    logo_id = String.trim(params["logo_id"] || "")
    sys_id  = String.trim(params["sys_id"] || "")
    bank_id = String.trim(params["bank_id"] || "")
    fee_attrs = %{
      annual_fee:           decimal_or_nil(params["annual_fee"]),
      late_fee:             decimal_or_nil(params["late_fee"]),
      overlimit_fee:        decimal_or_nil(params["overlimit_fee"]),
      replacement_fee:      decimal_or_nil(params["replacement_fee"]),
      returned_payment_fee: decimal_or_nil(params["returned_payment_fee"]),
      card_replacement_fee: decimal_or_nil(params["card_replacement_fee"])
    }
    result =
      case Repo.get_by(LogoParameter, logo_id: logo_id, sys_id: sys_id, bank_id: bank_id) do
        nil ->
          {:error, "LOGO #{logo_id}/#{sys_id}/#{bank_id} not found — create it in ASM06 first"}
        existing ->
          case ParameterWriter.update_logo(existing, fee_attrs, operator_id: "UI") do
            {:ok, _}     -> {:ok, "Fee schedule updated on LOGO #{logo_id} — ETS cache refreshed"}
            {:error, cs} -> {:error, changeset_errors(cs)}
          end
      end
    {:noreply, assign(socket, action_result: result)}
  end

  # ---------------------------------------------------------------------------
  # Events — LMS
  # ---------------------------------------------------------------------------

  def handle_event("lms_points_inquiry", %{"account_id" => aid}, socket) do
    lms_acct = Repo.one(
      from a in "lms_accounts",
        where: a.account_id == ^String.trim(aid),
        select: %{
          id:             a.id,
          account_id:     a.account_id,
          scheme_id:      a.scheme_id,
          points_balance: a.points_balance,
          open_to_redeem: a.open_to_redeem,
          lifetime_earned: a.lifetime_earned,
          status:         a.status
        }
    ) |> safe_one()

    ledger =
      if lms_acct do
        Repo.all(
          from l in "lms_points_ledger",
            where: l.lms_account_id == ^lms_acct.id,
            order_by: [desc: l.posting_date],
            limit: 20,
            select: %{
              posting_date:  l.posting_date,
              entry_type:    l.entry_type,
              points:        l.points,
              warehouse_state: l.warehouse_state,
              reference_id:  l.reference_id
            }
        ) |> safe_query([])
      else
        []
      end

    {:noreply, assign(socket, results: {:lms_points, lms_acct, ledger})}
  end

  def handle_event("lms_schemes", _, socket) do
    rows = Repo.all(
      from s in "lms_schemes",
        order_by: [asc: s.scheme_name],
        limit: 50,
        select: %{
          id:            s.id,
          scheme_code:   s.scheme_code,
          scheme_name:   s.scheme_name,
          currency:      s.currency,
          warehouse_days: s.warehouse_days,
          expiry_months: s.expiry_months,
          status:        s.status
        }
    ) |> safe_query([])

    {:noreply, assign(socket, results: {:lms_schemes, rows})}
  end

  # ---------------------------------------------------------------------------
  # Events — DPS
  # ---------------------------------------------------------------------------

  def handle_event("dps_list", %{"status" => status}, socket) do
    base = from d in "dps_disputes",
             order_by: [desc: d.inserted_at],
             limit: 30,
             select: %{
               id:          d.id,
               account_id:  d.account_id,
               dispute_type: d.dispute_type,
               amount:      d.amount,
               state:       d.state,
               network:     d.network,
               inserted_at: d.inserted_at
             }

    q = if status != "" do
          from d in base, where: d.state == ^status
        else
          base
        end

    rows = safe_query(q, [])
    {:noreply, assign(socket, results: {:dps_list, rows})}
  end

  # ---------------------------------------------------------------------------
  # Events — ITS
  # ---------------------------------------------------------------------------

  def handle_event("its_copy_requests", %{"status" => status}, socket) do
    base = from r in "its_copy_requests",
             order_by: [desc: r.inserted_at],
             limit: 30,
             select: %{
               id:           r.id,
               account_id:   r.account_id,
               request_type: r.request_type,
               status:       r.status,
               network:      r.network,
               sla_deadline: r.sla_deadline,
               inserted_at:  r.inserted_at
             }

    q = if status != "" do
          from r in base, where: r.status == ^status
        else
          base
        end

    rows = safe_query(q, [])
    {:noreply, assign(socket, results: {:its_copy_requests, rows})}
  end

  def handle_event("its_fee_claims", %{"from" => from, "to" => to}, socket) do
    base = from f in "its_fee_claims",
             order_by: [desc: f.settlement_date],
             limit: 40,
             select: %{
               id:                 f.id,
               clearing_record_id: f.clearing_record_id,
               network:            f.network,
               interchange_amount: f.interchange_amount,
               scheme_fee:         f.scheme_fee,
               net_amount:         f.net_amount,
               settlement_date:    f.settlement_date
             }

    q =
      if String.trim(from) != "" do
        from f in base, where: f.settlement_date >= ^from
      else
        base
      end

    q =
      if String.trim(to) != "" do
        from f in q, where: f.settlement_date <= ^to
      else
        q
      end

    rows = safe_query(q, [])
    {:noreply, assign(socket, results: {:its_fee_claims, rows})}
  end

  def handle_event("its_far_list", %{"status" => status}, socket) do
    base = from f in "its_financial_adjustments",
             order_by: [desc: f.received_at],
             limit: 30,
             select: %{
               id:          f.id,
               network:     f.network,
               far_type:    f.far_type,
               amount:      f.amount,
               status:      f.status,
               received_at: f.received_at,
               processed_at: f.processed_at
             }

    q = if status != "" do
          from f in base, where: f.status == ^status
        else
          base
        end

    rows = safe_query(q, [])
    {:noreply, assign(socket, results: {:its_far_list, rows})}
  end

  # ---------------------------------------------------------------------------
  # Events — HCS
  # ---------------------------------------------------------------------------

  def handle_event("hcs_company_lookup", %{"company_id" => cid}, socket) do
    row = Repo.one(
      from c in "hcs_companies",
        where: c.company_id == ^String.trim(cid),
        select: %{
          id:               c.id,
          company_id:       c.company_id,
          company_name:     c.company_name,
          credit_pool:      c.credit_pool,
          available_limit:  c.available_limit,
          liability_model:  c.liability_model,
          status:           c.status
        }
    ) |> safe_one()

    {:noreply, assign(socket, results: {:hcs_company, row})}
  end

  def handle_event("hcs_employee_list", %{"company_id" => cid}, socket) do
    rows = Repo.all(
      from e in "hcs_employee_cards",
        where: e.company_id == ^String.trim(cid),
        order_by: [asc: e.employee_name],
        limit: 50,
        select: %{
          id:                       e.id,
          employee_name:            e.employee_name,
          account_id:               e.account_id,
          individual_limit:         e.individual_limit,
          available_individual:     e.available_individual,
          cost_centre:              e.cost_centre,
          status:                   e.status
        }
    ) |> safe_query([])

    {:noreply, assign(socket, results: {:hcs_employees, rows})}
  end

  # ---------------------------------------------------------------------------
  # Events — COL
  # ---------------------------------------------------------------------------

  def handle_event("col_cases", %{"bucket" => bucket}, socket) do
    base = from c in "col_cases",
             order_by: [desc: c.inserted_at],
             limit: 30,
             select: %{
               id:          c.id,
               account_id:  c.account_id,
               dpd_bucket:  c.dpd_bucket,
               outstanding: c.outstanding_amount,
               status:      c.status,
               assigned_to: c.assigned_to,
               next_action_date: c.next_action_date
             }

    q = if bucket != "" do
          from c in base, where: c.dpd_bucket == ^String.to_integer(bucket)
        else
          base
        end

    rows = safe_query(q, [])
    {:noreply, assign(socket, results: {:col_cases, rows})}
  end

  # ---------------------------------------------------------------------------
  # Events — TRAMS
  # ---------------------------------------------------------------------------

  def handle_event("trams_clearing", %{"network" => network, "from" => from}, socket) do
    base = from t in "trams_clearing_records",
             order_by: [desc: t.clearing_date],
             limit: 30,
             select: %{
               id:            t.id,
               network:       t.network,
               pan_token:     t.pan_token,
               amount:        t.amount,
               clearing_date: t.clearing_date,
               mcc:           t.mcc,
               arn:           t.arn
             }

    q = if network != "" do
          from t in base, where: t.network == ^network
        else
          base
        end

    q = if String.trim(from) != "" do
          from t in q, where: t.clearing_date >= ^from
        else
          q
        end

    rows = safe_query(q, [])
    {:noreply, assign(socket, results: {:trams_clearing, rows})}
  end

  # ---------------------------------------------------------------------------
  # Events — CDM
  # ---------------------------------------------------------------------------

  def handle_event("cdm_applications", %{"status" => status}, socket) do
    base = from a in "cdm_applications",
             order_by: [desc: a.submitted_at],
             limit: 30,
             select: %{
               id:           a.id,
               customer_id:  a.customer_id,
               status:       a.status,
               risk_tier:    a.risk_tier,
               requested_limit: a.requested_limit,
               approved_limit:  a.approved_limit,
               submitted_at: a.submitted_at
             }

    q = if status != "" do
          from a in base, where: a.status == ^status
        else
          base
        end

    rows = safe_query(q, [])
    {:noreply, assign(socket, results: {:cdm_apps, rows})}
  end

  # ---------------------------------------------------------------------------
  # Events — MBS
  # ---------------------------------------------------------------------------

  def handle_event("mbs_merchant_lookup", %{"q" => q}, socket) do
    term = "%#{String.trim(q)}%"
    rows = Repo.all(
      from m in "mbs_merchants",
        where: ilike(m.merchant_name, ^term) or ilike(m.merchant_id, ^term),
        limit: 25,
        select: %{
          id:            m.id,
          merchant_id:   m.merchant_id,
          merchant_name: m.merchant_name,
          mcc:           m.mcc,
          mdr_rate:      m.mdr_rate,
          status:        m.status
        }
    ) |> safe_query([])

    {:noreply, assign(socket, results: {:mbs_merchants, rows})}
  end

  # ---------------------------------------------------------------------------
  # Catch-all event
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Events — console mode
  # ---------------------------------------------------------------------------

  def handle_event("toggle_mode", %{"mode" => "console"}, socket) do
    history =
      if socket.assigns.console_history == [] do
        module = console_module_for(socket.assigns.screen)
        mod_up = if module, do: module |> to_string() |> String.upcase(), else: "SYSTEM"
        [
          %{type: :info, text: "# VisionPlus #{mod_up} Console ready. Type 'help' for available commands."},
          %{type: :info, text: "# Node: #{node()}  |  Role: agent"}
        ]
      else
        socket.assigns.console_history
      end
    {:noreply, assign(socket, console_mode: true, console_history: history, console_input: "")}
  end

  def handle_event("toggle_mode", %{"mode" => "form"}, socket) do
    {:noreply, assign(socket, console_mode: false)}
  end

  def handle_event("console_input_change", %{"value" => v}, socket) do
    {:noreply, assign(socket, console_input: v)}
  end

  def handle_event("console_quick", %{"cmd" => cmd}, socket) do
    handle_event("console_cmd", %{"cmd" => cmd}, socket)
  end

  def handle_event("console_cmd", %{"cmd" => ""}, socket), do: {:noreply, socket}

  def handle_event("console_cmd", %{"cmd" => raw}, socket) do
    cmd    = String.trim(raw)
    module = console_module_for(socket.assigns.screen)

    cmd_entry = %{type: :cmd, module: module, text: cmd}

    {result_type, content} = execute_console_cmd(module, cmd, socket)

    result_entry =
      case {result_type, content} do
        {:ok,    lines} when is_list(lines) -> %{type: :ok,         lines: lines}
        {:ok,    text}                      -> %{type: :ok,         lines: [text]}
        {:error, msg}                       -> %{type: :error,      text:  msg}
        {:info,  lines}                     -> %{type: :info_block, lines: lines}
      end

    new_history =
      (socket.assigns.console_history ++ [cmd_entry, result_entry])
      |> Enum.take(-200)

    {:noreply, assign(socket, console_history: new_history, console_input: "")}
  end

  def handle_event(event, _params, socket) do
    Logger.debug("[VisionPlus] unhandled event: #{event}")
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Main render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1.0" />
      <title>VisionPlus — vMu Card Management</title>
      <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
      <style>
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: 'JetBrains Mono', 'Fira Code', 'Courier New', monospace;
               background: #0d1117; color: #e6edf3; height: 100vh; overflow: hidden; }
        ::-webkit-scrollbar { width: 6px; height: 6px; }
        ::-webkit-scrollbar-track { background: #161b22; }
        ::-webkit-scrollbar-thumb { background: #30363d; border-radius: 3px; }
        input, select, button { font-family: inherit; }
        table { border-collapse: collapse; width: 100%; }
        th { text-align: left; }
      </style>
      <%!-- Phoenix LiveView JavaScript — required for phx-submit, phx-click, phx-keyup events --%>
      <script src="/assets/phoenix.min.js"></script>
      <script src="/assets/phoenix_live_view.js"></script>
      <script>
        document.addEventListener("DOMContentLoaded", function() {
          var Hooks = {};
          // Auto-scroll console output to bottom on mount and update
          Hooks.ScrollBottom = {
            mounted()  { this.el.scrollTop = this.el.scrollHeight; },
            updated()  { this.el.scrollTop = this.el.scrollHeight; }
          };
          var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
            hooks: Hooks,
            params: { _csrf_token: document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || "" }
          });
          liveSocket.connect();
          window.liveSocket = liveSocket;
        });
      </script>
    </head>
    <body>
      <div style="display:flex; flex-direction:column; height:100vh;">
        <%= render_topbar(assigns) %>
        <div style="display:flex; flex:1; overflow:hidden;">
          <%= render_sidebar(assigns) %>
          <main style={"flex:1; overflow-y:auto; background:#0d1117; #{if @console_mode, do: "padding:0;", else: "padding:1.5rem 2rem;"}"}>
            <%= render_content(assigns) %>
          </main>
        </div>
      </div>
    </body>
    </html>
    """
  end

  # ---------------------------------------------------------------------------
  # Topbar
  # ---------------------------------------------------------------------------

  defp render_topbar(assigns) do
    ~H"""
    <header style="background:#161b22; border-bottom:1px solid #30363d;
                   padding:0 1.25rem; height:52px; display:flex; align-items:center; gap:1.5rem;
                   flex-shrink:0; z-index:100;">
      <%!-- Logo --%>
      <div style="display:flex; align-items:center; gap:0.6rem; flex-shrink:0;">
        <div style="width:32px; height:32px; background:linear-gradient(135deg,#00c875,#0075ff);
                    border-radius:6px; display:flex; align-items:center; justify-content:center;
                    font-size:1rem; font-weight:bold;">V</div>
        <div>
          <div style="font-size:0.85rem; font-weight:700; color:#e6edf3; letter-spacing:0.05em;">VisionPlus</div>
          <div style="font-size:0.62rem; color:#8b949e; letter-spacing:0.08em;">vMu CARD MANAGEMENT</div>
        </div>
      </div>

      <%!-- Command bar --%>
      <form phx-submit="cmd_submit" style="flex:1; max-width:520px;">
        <div style={"display:flex; align-items:center; background:#0d1117; border:1px solid #30363d; border-radius:6px; padding:0.4rem 0.75rem; gap:0.5rem; #{if @cmd_error, do: "border-color:#f85149;", else: ""}"}>

          <span style="color:#3fb950; font-size:0.8rem; user-select:none;">VP&gt;</span>
          <input name="cmd" value={@cmd_input} placeholder="Enter screen code (CMS01, FAS01, DPS01…)"
            autocomplete="off" spellcheck="false"
            phx-keyup="cmd_input" phx-value-value=""
            style="flex:1; background:transparent; border:none; outline:none;
                   color:#e6edf3; font-size:0.82rem; caret-color:#3fb950;" />
          <kbd style="font-size:0.65rem; color:#8b949e; border:1px solid #30363d;
                      border-radius:3px; padding:0.1rem 0.3rem;">Enter</kbd>
        </div>
        <%= if @cmd_error do %>
          <div style="color:#f85149; font-size:0.72rem; margin-top:0.3rem; padding-left:0.5rem;">
            ⚠ {@cmd_error}
          </div>
        <% end %>
      </form>

      <%!-- Screen indicator --%>
      <%= if @screen && Map.get(@screens, @screen) do %>
        <% meta = @screens[@screen] %>
        <div style="display:flex; align-items:center; gap:0.5rem;">
          <span style="background:#1f6feb; color:white; padding:0.2rem 0.55rem;
                       border-radius:4px; font-size:0.75rem; font-weight:700;">
            {@screen}
          </span>
          <span style="color:#8b949e; font-size:0.78rem;">{meta.title}</span>
        </div>
      <% end %>

      <%!-- CMD / MENU mode toggle — shown when a screen is active --%>
      <%= if @screen do %>
        <div style="display:flex; gap:0; flex-shrink:0;">
          <button phx-click="toggle_mode" phx-value-mode="console"
            style={"border:none; border-radius:4px 0 0 4px; padding:0.28rem 0.8rem; font-size:0.72rem;
                   font-weight:700; cursor:pointer; font-family:inherit; letter-spacing:0.03em;
                   #{if @console_mode, do: "background:#3fb950; color:#000;", else: "background:#21262d; color:#8b949e; border:1px solid #30363d;"}"}>
            ■ CMD
          </button>
          <button phx-click="toggle_mode" phx-value-mode="form"
            style={"border-left:none; border-radius:0 4px 4px 0; padding:0.28rem 0.8rem; font-size:0.72rem;
                   cursor:pointer; font-family:inherit; letter-spacing:0.03em;
                   #{if @console_mode, do: "background:#21262d; color:#8b949e; border:1px solid #30363d;", else: "background:#1f6feb; color:#fff; border:none; font-weight:700;"}"}>
            ≡ MENU
          </button>
        </div>
      <% end %>

      <div style="margin-left:auto; display:flex; align-items:center; gap:0.75rem;">
        <%!-- Quick help chips --%>
        <div style="display:flex; gap:0.3rem; flex-wrap:nowrap;">
          <%= for code <- ~w(CMS01 FAS01 DPS01 LMS03 HCS01 ITS01) do %>
            <button phx-click="nav" phx-value-screen={code}
              style="background:#21262d; border:1px solid #30363d; color:#8b949e;
                     padding:0.2rem 0.45rem; border-radius:4px; font-size:0.68rem;
                     cursor:pointer; white-space:nowrap;">
              {code}
            </button>
          <% end %>
        </div>
        <%!-- Dashboard link --%>
        <a href="/dashboard" target="_blank"
          style="color:#58a6ff; font-size:0.72rem; text-decoration:none;
                 border:1px solid #30363d; padding:0.25rem 0.6rem; border-radius:4px;">
          Dashboard ↗
        </a>
      </div>
    </header>
    """
  end

  # ---------------------------------------------------------------------------
  # Sidebar
  # ---------------------------------------------------------------------------

  defp render_sidebar(assigns) do
    ~H"""
    <nav style="width:220px; flex-shrink:0; background:#161b22; border-right:1px solid #30363d;
                overflow-y:auto; padding:0.75rem 0;">
      <%= for {key, icon, code, label, screens} <- @sidebar_groups do %>
        <% open = @sidebar_open[key] %>
        <div style="margin-bottom:0.15rem;">
          <%!-- Group header --%>
          <button phx-click="toggle_group" phx-value-group={key}
            style={"width:100%; text-align:left; background:transparent; border:none;
                   padding:0.45rem 1rem; cursor:pointer; display:flex; align-items:center;
                   gap:0.5rem; color:#{if open, do: "#e6edf3", else: "#8b949e"};
                   font-size:0.78rem;"}>
            <span>{icon}</span>
            <span style="font-weight:600; letter-spacing:0.03em;">{code}</span>
            <span style="color:#6e7681; font-size:0.7rem; font-weight:400;">{label}</span>
            <span style="margin-left:auto; font-size:0.65rem; color:#6e7681;">
              {if open, do: "▾", else: "▸"}
            </span>
          </button>

          <%!-- Screen links --%>
          <%= if open do %>
            <div style="padding-left:0.5rem; border-left:2px solid #21262d; margin-left:1.5rem;">
              <%= for screen_code <- screens do %>
                <% meta = @screens[screen_code] %>
                <% active = @screen == screen_code %>
                <button phx-click="nav" phx-value-screen={screen_code}
                  style={"width:100%; text-align:left; background:#{if active, do: "#1f6feb22", else: "transparent"};
                         border:none; border-left:2px solid #{if active, do: "#1f6feb", else: "transparent"};
                         padding:0.35rem 0.6rem 0.35rem 0.7rem; cursor:pointer;
                         display:block; color:#{if active, do: "#58a6ff", else: "#8b949e"};
                         font-size:0.73rem; transition:color 0.1s;"}>
                  <span style={"color:#{if active, do: "#58a6ff", else: "#6e7681"}; font-size:0.68rem;"}>{screen_code}</span>
                  <br />
                  <span style={"color:#{if active, do: "#e6edf3", else: "#8b949e"};"}>{meta.title}</span>
                </button>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </nav>
    """
  end

  # ---------------------------------------------------------------------------
  # Content dispatcher
  # ---------------------------------------------------------------------------

  defp render_content(%{screen: nil} = assigns) do
    render_home(assigns)
  end

  # Console mode — intercepts all screen-specific render functions
  defp render_content(%{console_mode: true} = assigns), do: render_console(assigns)

  defp render_content(%{screen: "FAS01"} = assigns), do: render_fas01(assigns)
  defp render_content(%{screen: "FAS02"} = assigns), do: render_fas02(assigns)
  defp render_content(%{screen: "CMS01"} = assigns), do: render_cms01(assigns)
  defp render_content(%{screen: "CMS02"} = assigns), do: render_cms02(assigns)
  defp render_content(%{screen: "CMS03"} = assigns), do: render_cms03(assigns)
  defp render_content(%{screen: "CMS04"} = assigns), do: render_cms04(assigns)
  defp render_content(%{screen: "CMS05"} = assigns), do: render_cms05(assigns)
  defp render_content(%{screen: "CIF01"} = assigns), do: render_cif01(assigns)
  defp render_content(%{screen: "CIF02"} = assigns), do: render_cif02(assigns)
  defp render_content(%{screen: "CTA01"} = assigns), do: render_cta01(assigns)
  defp render_content(%{screen: "CTA02"} = assigns), do: render_cta02(assigns)
  defp render_content(%{screen: "CTA03"} = assigns), do: render_cta03(assigns)
  defp render_content(%{screen: "IVR01"} = assigns), do: render_ivr01(assigns)
  defp render_content(%{screen: "IVR02"} = assigns), do: render_ivr02(assigns)
  defp render_content(%{screen: "DPS01"} = assigns), do: render_dps01(assigns)
  defp render_content(%{screen: "DPS02"} = assigns), do: render_dps02(assigns)
  defp render_content(%{screen: "TRAMS01"} = assigns), do: render_trams01(assigns)
  defp render_content(%{screen: "TRAMS02"} = assigns), do: render_trams02(assigns)
  defp render_content(%{screen: "COL01"} = assigns), do: render_col01(assigns)
  defp render_content(%{screen: "COL02"} = assigns), do: render_col02(assigns)
  defp render_content(%{screen: "CDM01"} = assigns), do: render_cdm01(assigns)
  defp render_content(%{screen: "CDM02"} = assigns), do: render_cdm02(assigns)
  defp render_content(%{screen: "ASM01"} = assigns), do: render_asm01(assigns)
  defp render_content(%{screen: "ASM02"} = assigns), do: render_asm02(assigns)
  defp render_content(%{screen: "ASM03"} = assigns), do: render_asm03(assigns)
  defp render_content(%{screen: "ASM04"} = assigns), do: render_asm04(assigns)
  defp render_content(%{screen: "ASM05"} = assigns), do: render_asm05(assigns)
  defp render_content(%{screen: "ASM06"} = assigns), do: render_asm06(assigns)
  defp render_content(%{screen: "ASM07"} = assigns), do: render_asm07(assigns)
  defp render_content(%{screen: "ASM08"} = assigns), do: render_asm08(assigns)
  defp render_content(%{screen: "PCM01"} = assigns), do: render_pcm01(assigns)
  defp render_content(%{screen: "PCM02"} = assigns), do: render_pcm02(assigns)
  defp render_content(%{screen: "PCM03"} = assigns), do: render_pcm03(assigns)
  defp render_content(%{screen: "MBS01"} = assigns), do: render_mbs01(assigns)
  defp render_content(%{screen: "MBS02"} = assigns), do: render_mbs02(assigns)
  defp render_content(%{screen: "MBS03"} = assigns), do: render_mbs03(assigns)
  defp render_content(%{screen: "LMS01"} = assigns), do: render_lms01(assigns)
  defp render_content(%{screen: "LMS02"} = assigns), do: render_lms02(assigns)
  defp render_content(%{screen: "LMS03"} = assigns), do: render_lms03(assigns)
  defp render_content(%{screen: "LMS04"} = assigns), do: render_lms04(assigns)
  defp render_content(%{screen: "HCS01"} = assigns), do: render_hcs01(assigns)
  defp render_content(%{screen: "HCS02"} = assigns), do: render_hcs02(assigns)
  defp render_content(%{screen: "HCS03"} = assigns), do: render_hcs03(assigns)
  defp render_content(%{screen: "ITS01"} = assigns), do: render_its01(assigns)
  defp render_content(%{screen: "ITS02"} = assigns), do: render_its02(assigns)
  defp render_content(%{screen: "ITS03"} = assigns), do: render_its03(assigns)
  defp render_content(assigns), do: render_home(assigns)

  # ---------------------------------------------------------------------------
  # Home screen
  # ---------------------------------------------------------------------------

  defp render_home(assigns) do
    ~H"""
    <div style="max-width:900px; margin:2rem auto;">
      <div style="text-align:center; margin-bottom:3rem;">
        <div style="font-size:2.5rem; font-weight:700; background:linear-gradient(90deg,#3fb950,#58a6ff);
                    -webkit-background-clip:text; -webkit-text-fill-color:transparent; margin-bottom:0.5rem;">
          VisionPlus
        </div>
        <div style="color:#8b949e; font-size:0.85rem;">
          vMu Elixir/Phoenix Card Management Platform · 14 Modules
        </div>
      </div>

      <%!-- Module grid --%>
      <div style="display:grid; grid-template-columns:repeat(auto-fill,minmax(240px,1fr)); gap:1rem;">
        <%= for {_key, icon, code, label, screens} <- @sidebar_groups do %>
          <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem;">
            <div style="display:flex; align-items:center; gap:0.5rem; margin-bottom:0.75rem;">
              <span style="font-size:1.2rem;">{icon}</span>
              <span style="font-weight:700; color:#e6edf3; font-size:0.9rem;">{code}</span>
              <span style="color:#8b949e; font-size:0.75rem;">{label}</span>
            </div>
            <div style="display:flex; flex-direction:column; gap:0.3rem;">
              <%= for sc <- screens do %>
                <% meta = @screens[sc] %>
                <button phx-click="nav" phx-value-screen={sc}
                  style="text-align:left; background:#0d1117; border:1px solid #21262d;
                         border-radius:5px; padding:0.4rem 0.6rem; cursor:pointer;
                         display:flex; gap:0.5rem; align-items:baseline;">
                  <code style="color:#3fb950; font-size:0.68rem; flex-shrink:0;">{sc}</code>
                  <span style="color:#c9d1d9; font-size:0.73rem;">{meta.title}</span>
                </button>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <div style="margin-top:2rem; padding:1rem; background:#161b22; border:1px solid #30363d;
                  border-radius:8px; font-size:0.78rem; color:#8b949e;">
        <span style="color:#3fb950;">Tip:</span>
        Type a screen code in the command bar above and press <kbd style="color:#e6edf3;">Enter</kbd>
        to navigate directly. All 14 VisionPlus modules are available.
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # FAS01 — Authorization Inquiry
  # ---------------------------------------------------------------------------

  defp render_fas01(assigns) do
    ~H"""
    <%= screen_header("FAS01", "Authorization Inquiry", "Run a live authorization test through the full FAS chain", assigns) %>
    <div style="max-width:700px;">
      <form phx-submit="fas_inquiry" style={form_style()}>
        <div style={form_row()}>
          <%= field_label("PAN (raw)") %>
          <input name="pan" placeholder="4072001234560001" required style={inp()} autocomplete="off" />
        </div>
        <div style={form_row()}>
          <%= field_label("Amount (AED)") %>
          <input name="amount" value="100.00" required style={inp()} />
          <%= field_label("MCC") %>
          <input name="mcc" value="5411" style="#{inp()} width:80px;" />
        </div>
        <div style={form_row()}>
          <%= field_label("Channel") %>
          <select name="channel" style={inp()}>
            <option value="pos">POS</option>
            <option value="atm">ATM</option>
            <option value="ecom">ECOM</option>
            <option value="contactless">Contactless</option>
          </select>
        </div>
        <button type="submit" style={btn_green()}>▶ Run Authorization</button>
      </form>

      <%= case @results do %>
        <% {:fas_result, {:ok, verdict, rc, code}} -> %>
          <div style="margin-top:1.5rem; padding:1.25rem; background:#0f2419; border:1px solid #3fb950;
                      border-radius:8px; font-size:0.85rem;">
            <div style="font-size:1.1rem; font-weight:700; color:#3fb950; margin-bottom:0.5rem;">✅ {verdict}</div>
            <div style={kv_row()}><span style={kl()}>Response Code</span><code style="color:#e6edf3;">{rc}</code></div>
            <div style={kv_row()}><span style={kl()}>Approval Code</span><code style="color:#3fb950;">{code}</code></div>
          </div>
        <% {:fas_result, {:error, verdict, rc, msg}} -> %>
          <div style="margin-top:1.5rem; padding:1.25rem; background:#1c0a0a; border:1px solid #f85149;
                      border-radius:8px; font-size:0.85rem;">
            <div style="font-size:1.1rem; font-weight:700; color:#f85149; margin-bottom:0.5rem;">❌ {verdict}</div>
            <div style={kv_row()}><span style={kl()}>Response Code</span><code style="color:#f85149;">{rc}</code></div>
            <%= if msg != "" do %>
              <div style={kv_row()}><span style={kl()}>Detail</span><span style="color:#ffa198;">{msg}</span></div>
            <% end %>
          </div>
        <% _ -> %>
          <div style="margin-top:1rem; padding:0.75rem; background:#161b22; border-radius:6px;
                      color:#8b949e; font-size:0.8rem;">
            Enter a PAN and click Run Authorization to test the FAS decision chain.
          </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # FAS02 — Authorization History
  # ---------------------------------------------------------------------------

  defp render_fas02(assigns) do
    ~H"""
    <%= screen_header("FAS02", "Authorization History", "90-day authorization log by account", assigns) %>
    <div style="max-width:700px;">
      <form phx-submit="fas_history" style={form_row()}>
        <input name="account_id" placeholder="Account UUID" style={inp()} autocomplete="off" />
        <button type="submit" style={btn_blue()}>Search</button>
      </form>
      <%= case @results do %>
        <% {:fas_history, []} -> %>
          <%= empty_state("No authorization records found") %>
        <% {:fas_history, rows} -> %>
          <%= data_table(["Time (UTC)", "PAN Token", "Amount", "RC", "Channel", "MCC"],
              Enum.map(rows, fn r -> [
                r.inserted_at, r.pan_token, r.amount, r.rc, r.channel, r.mcc
              ] end)) %>
        <% _ -> %>
          <%= hint("Enter an account UUID to view authorization history.") %>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # CMS01 — Account Inquiry
  # ---------------------------------------------------------------------------

  defp render_cms01(assigns) do
    ~H"""
    <%= screen_header("CMS01", "Account Inquiry", "Full account record — balances, status, block code, supplementary cards", assigns) %>
    <div style="max-width:900px;">
      <%!-- Search bar --%>
      <div style="display:flex; gap:0.5rem; margin-bottom:1rem;">
        <form phx-submit="cms_account_lookup" style="flex:1; display:flex; gap:0.5rem;">
          <input name="id" placeholder="Account UUID" style={inp()} autocomplete="off" />
          <button type="submit" style={btn_blue()}>Look Up</button>
        </form>
        <button phx-click="cms_list_accounts" style={btn_secondary()}>List Recent (25)</button>
      </div>

      <%= case @results do %>
        <% {:cms_account, nil} -> %>
          <%= error_box("Account not found") %>

        <% {:cms_account, a} -> %>
          <%!-- Account header grid --%>
          <div style="background:#161b22; border:1px solid #30363d; border-radius:8px;
                      padding:1.25rem; display:grid; grid-template-columns:1fr 1fr 1fr; gap:0.5rem 1.5rem;
                      margin-bottom:1rem;">
            <%= kv("Account ID",      a.account_id) %>
            <%= kv("Status",          a.account_status) %>
            <%= kv("Block Code",      a.block_code || "—") %>
            <%= kv("Credit Limit",    "#{a.credit_limit} AED") %>
            <%= kv("Open-to-Buy",     "#{a.open_to_buy} AED") %>
            <%= kv("Cash OTB",        "#{a.cash_open_to_buy} AED") %>
            <%= kv("DPD Bucket",      "#{a.delinquency_bucket} days") %>
            <%= kv("Cycle Code",      "#{a.cycle_code}") %>
            <%= kv("Emboss Name",     a.emboss_name || "—") %>
            <%= kv("PAN Token",       a.pan_token) %>
            <%= kv("Next Stmt Date",  a.next_statement_date) %>
            <%= kv("Open Date",       a.open_date) %>
          </div>

          <%!-- Balance bucket breakdown (lazy: loaded via separate button) --%>
          <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem; margin-bottom:1rem;">
            <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:0.75rem;">
              <div style="font-size:0.8rem; font-weight:600; color:#c9d1d9; letter-spacing:0.04em;">
                💰 Balance Bucket Breakdown
              </div>
              <button phx-click="cms_bucket_lookup" phx-value-account_id={a.account_id}
                style={btn_secondary()}>Load Balances</button>
            </div>
            <%= if @bucket do %>
              <div style="display:grid; grid-template-columns:repeat(4,1fr); gap:0.5rem 1rem;">
                <%= bucket_kv("Retail",   @bucket.retail_balance) %>
                <%= bucket_kv("Cash Adv", @bucket.cash_balance) %>
                <%= bucket_kv("BT",       Map.get(@bucket, :bt_balance, 0)) %>
                <%= bucket_kv("EMI",      Map.get(@bucket, :emi_balance, 0)) %>
                <%= bucket_kv("Interest", @bucket.accrued_interest) %>
                <%= bucket_kv("Fees",     @bucket.unpaid_fees) %>
                <%= bucket_kv("Disputed", @bucket.disputed_amount) %>
                <%= bucket_kv("Stmt Bal", @bucket.statement_balance) %>
                <%= bucket_kv("Min Pay",  @bucket.minimum_payment) %>
              </div>
            <% else %>
              <div style="color:#8b949e; font-size:0.78rem;">Click "Load Balances" to view bucket breakdown.</div>
            <% end %>
          </div>

          <%!-- Block code history (lazy) --%>
          <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem; margin-bottom:1rem;">
            <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:0.75rem;">
              <div style="font-size:0.8rem; font-weight:600; color:#c9d1d9; letter-spacing:0.04em;">
                🔒 Block Code History
              </div>
              <button phx-click="cms_block_history" phx-value-account_id={a.account_id}
                style={btn_secondary()}>Load History</button>
            </div>
            <%= if @block_history == [] do %>
              <div style="color:#8b949e; font-size:0.78rem;">Click "Load History" to view block code audit trail.</div>
            <% else %>
              <%= data_table(
                ["Block Code", "Reason", "Narrative", "Operator", "Role", "Applied At"],
                Enum.map(@block_history, fn h ->
                  [h.block_code, h.reason_code, h.narrative, h.operator_id, h.operator_role, h.applied_at]
                end)
              ) %>
            <% end %>
          </div>

          <%!-- Supplementary cards (lazy) --%>
          <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem;">
            <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:0.75rem;">
              <div style="font-size:0.8rem; font-weight:600; color:#c9d1d9; letter-spacing:0.04em;">
                🪪 Supplementary Cards
              </div>
              <button phx-click="cms_supp_lookup" phx-value-account_id={a.account_id}
                style={btn_secondary()}>Load Supps</button>
            </div>
            <%= if @supp_cards == [] do %>
              <div style="color:#8b949e; font-size:0.78rem;">Click "Load Supps" to view supplementary card holders.</div>
            <% else %>
              <%= data_table(
                ["Supp Account", "Relationship", "Emboss Name", "Status", "Since"],
                Enum.map(@supp_cards, fn s ->
                  [s.supplementary_account_id, s.relationship, s.emboss_name, s.status, s.inserted_at]
                end)
              ) %>
            <% end %>
          </div>

        <% {:cms_list, rows} -> %>
          <%= data_table(
              ["Account ID", "Status", "Limit (AED)", "OTB (AED)", "DPD"],
              Enum.map(rows, fn r -> [r.account_id, r.account_status, r.credit_limit, r.open_to_buy, r.delinquency_bucket] end)
          ) %>
        <% _ -> %>
          <%= hint("Enter an account UUID or click 'List Recent' to browse accounts.") %>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # CMS02 — Account Maintenance
  # ---------------------------------------------------------------------------

  defp render_cms02(assigns) do
    ~H"""
    <%= screen_header("CMS02", "Account Maintenance", "Block/unblock, limit changes, fee waivers, financial adjustments — all 4-eyes protected", assigns) %>
    <div style="max-width:780px; display:flex; flex-direction:column; gap:1.25rem;">

      <%!-- ── Section 1: Block / Unblock with reason code ── --%>
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem;">
        <div style="font-size:0.8rem; font-weight:600; color:#c9d1d9; letter-spacing:0.04em; margin-bottom:1rem;">
          🔒 Block / Unblock Account
        </div>
        <form phx-submit="cms_action" style={form_style()}>
          <input type="hidden" name="action_group" value="block_mgmt" />
          <div style="display:grid; grid-template-columns:1fr 1fr; gap:0.75rem;">
            <div style={form_row()}>
              <%= field_label("Account UUID") %>
              <input name="account_id" placeholder="Account UUID" required style={inp()} autocomplete="off" />
            </div>
            <div style={form_row()}>
              <%= field_label("Action") %>
              <select name="action" style={inp()}>
                <option value="block">Block Account</option>
                <option value="unblock">Unblock / Reactivate</option>
                <option value="close">Close Account (irreversible)</option>
              </select>
            </div>
            <div style={form_row()}>
              <%= field_label("Block Code") %>
              <select name="block_code" style={inp()}>
                <option value="">— None (for unblock) —</option>
                <option value="L">L — Lost</option>
                <option value="S">S — Stolen</option>
                <option value="F">F — Fraud</option>
                <option value="C">C — Credit Risk</option>
                <option value="O">O — Other / Operational</option>
              </select>
            </div>
            <div style={form_row()}>
              <%= field_label("Reason Code") %>
              <input name="reason" placeholder="e.g. CUST_REQUEST" required style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Operator ID") %>
              <input name="operator_id" placeholder="Your employee ID" required style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Supervisor ID") %>
              <input name="supervisor_id" placeholder="Approving supervisor ID" required style={inp()} />
            </div>
          </div>
          <button type="submit" style={btn_amber()}>⚠ Execute Block/Unblock</button>
        </form>
      </div>

      <%!-- ── Section 2: Credit Limit Change ── --%>
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem;">
        <div style="font-size:0.8rem; font-weight:600; color:#c9d1d9; letter-spacing:0.04em; margin-bottom:1rem;">
          💳 Credit Limit Adjustment
        </div>
        <form phx-submit="cms_action" style={form_style()}>
          <input type="hidden" name="action" value="set_limit" />
          <div style="display:grid; grid-template-columns:1fr 1fr; gap:0.75rem;">
            <div style={form_row()}>
              <%= field_label("Account UUID") %>
              <input name="account_id" placeholder="Account UUID" required style={inp()} autocomplete="off" />
            </div>
            <div style={form_row()}>
              <%= field_label("New Credit Limit (AED)") %>
              <input name="value" placeholder="e.g. 20000.00" required style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Operator ID") %>
              <input name="operator_id" placeholder="Your employee ID" required style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Supervisor ID") %>
              <input name="supervisor_id" placeholder="Approving supervisor ID" required style={inp()} />
            </div>
          </div>
          <button type="submit" style={btn_blue()}>Set Limit</button>
        </form>
      </div>

      <%!-- ── Section 3: Fee Waiver (4-eyes) ── --%>
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem;">
        <div style="font-size:0.8rem; font-weight:600; color:#c9d1d9; letter-spacing:0.04em; margin-bottom:1rem;">
          🏷 Fee Waiver <span style="font-weight:400; color:#8b949e; font-size:0.75rem;">(requires 4-eyes: operator ≠ supervisor)</span>
        </div>
        <form phx-submit="cms_fee_waiver" style={form_style()}>
          <div style="display:grid; grid-template-columns:1fr 1fr; gap:0.75rem;">
            <div style={form_row()}>
              <%= field_label("Account UUID") %>
              <input name="account_id" placeholder="Account UUID" required style={inp()} autocomplete="off" />
            </div>
            <div style={form_row()}>
              <%= field_label("Fee Entry ID (ledger entry_id to waive)") %>
              <input name="entry_id" placeholder="Ledger entry UUID" required style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Waive Amount (AED) — leave blank for full amount") %>
              <input name="amount" placeholder="Leave blank = full fee" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Reason") %>
              <input name="reason" placeholder="e.g. GOODWILL" required style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Operator ID") %>
              <input name="operator_id" placeholder="Your employee ID" required style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Supervisor ID") %>
              <input name="supervisor_id" placeholder="Approving supervisor ID" required style={inp()} />
            </div>
          </div>
          <button type="submit" style={btn_green()}>✓ Post Fee Waiver</button>
        </form>
      </div>

      <%!-- ── Section 4: Financial Adjustment (4-eyes) ── --%>
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem;">
        <div style="font-size:0.8rem; font-weight:600; color:#c9d1d9; letter-spacing:0.04em; margin-bottom:1rem;">
          ⚖ Financial Adjustment — Manual Credit / Debit <span style="font-weight:400; color:#8b949e; font-size:0.75rem;">(4-eyes required)</span>
        </div>
        <form phx-submit="cms_fin_adjustment" style={form_style()}>
          <div style="display:grid; grid-template-columns:1fr 1fr; gap:0.75rem;">
            <div style={form_row()}>
              <%= field_label("Account UUID") %>
              <input name="account_id" placeholder="Account UUID" required style={inp()} autocomplete="off" />
            </div>
            <div style={form_row()}>
              <%= field_label("Direction") %>
              <select name="direction" style={inp()}>
                <option value="credit">Credit (reduce balance)</option>
                <option value="debit">Debit (increase balance)</option>
              </select>
            </div>
            <div style={form_row()}>
              <%= field_label("Amount (AED)") %>
              <input name="amount" placeholder="e.g. 250.00" required style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Narrative") %>
              <input name="narrative" placeholder="e.g. GOODWILL_CREDIT" required style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Operator ID") %>
              <input name="operator_id" placeholder="Your employee ID" required style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Supervisor ID") %>
              <input name="supervisor_id" placeholder="Approving supervisor ID" required style={inp()} />
            </div>
          </div>
          <button type="submit" style={btn_amber()}>⚠ Post Adjustment</button>
        </form>
      </div>

      <%!-- ── Section 5: Temporary Credit Limit (4G) ── --%>
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem;">
        <div style="font-size:0.8rem; font-weight:600; color:#c9d1d9; letter-spacing:0.04em; margin-bottom:1rem;">
          ⏱ Temporary Credit Limit <span style="font-weight:400; color:#8b949e; font-size:0.75rem;">(auto-reinstated on expiry — 4-eyes required)</span>
        </div>
        <form phx-submit="cms_temp_limit" style={form_style()}>
          <div style="display:grid; grid-template-columns:1fr 1fr; gap:0.75rem;">
            <div style={form_row()}>
              <%= field_label("Account UUID") %>
              <input name="account_id" placeholder="Account UUID" required style={inp()} autocomplete="off" />
            </div>
            <div style={form_row()}>
              <%= field_label("Temporary Limit (AED)") %>
              <input name="temp_limit" placeholder="e.g. 25000.00" required style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Expiry Date (YYYY-MM-DD)") %>
              <input name="expiry_date" placeholder="e.g. 2026-08-31" required style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Reason") %>
              <input name="reason" placeholder="e.g. HOLIDAY_PROMO" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Operator ID") %>
              <input name="operator_id" placeholder="Your employee ID" required style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Supervisor ID") %>
              <input name="supervisor_id" placeholder="Approving supervisor ID" required style={inp()} />
            </div>
          </div>
          <button type="submit" style={btn_blue()}>Set Temp Limit</button>
        </form>
      </div>

      <%= render_action_result(assigns) %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # CMS03 — GL Ledger Browser
  # ---------------------------------------------------------------------------

  defp render_cms03(assigns) do
    ~H"""
    <%= screen_header("CMS03", "GL Ledger Browser", "Double-entry GL entries — filter by account, date range", assigns) %>
    <form phx-submit="cms_gl_browse" style="display:flex; gap:0.5rem; margin-bottom:1rem; flex-wrap:wrap;">
      <input name="account_id" placeholder="Account UUID (optional)" style="#{inp()} flex:2;" autocomplete="off" />
      <input name="date_from"  placeholder="From date (YYYY-MM-DD)"  style="#{inp()} width:160px;" />
      <input name="date_to"    placeholder="To date   (YYYY-MM-DD)"  style="#{inp()} width:160px;" />
      <button type="submit" style={btn_blue()}>Browse GL</button>
    </form>
    <%= case @results do %>
      <% {:cms_gl, []} -> %>
        <%= empty_state("No GL entries found for the selected filter") %>
      <% {:cms_gl, rows} -> %>
        <%= data_table(
            ["Date", "Code", "DR (AED)", "CR (AED)", "Narrative", "Idempotency Key"],
            Enum.map(rows, fn r -> [r.posting_date, r.transaction_code, r.dr_amount, r.cr_amount, r.narrative, r.idempotency_key] end)
        ) %>
      <% _ -> %>
        <%= hint("Filter by account UUID and/or date range, then click Browse GL.") %>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # CMS04 — Statement Viewer
  # ---------------------------------------------------------------------------

  defp render_cms04(assigns) do
    ~H"""
    <%= screen_header("CMS04", "Statement Viewer", "Cycle statements — closing balance, minimum payment, due date", assigns) %>
    <%= hint("Enter an account UUID to browse cycle statements. Statement data is in cms_statements generated by the EOD pipeline.") %>
    <form phx-submit="cms_account_lookup" style="display:flex; gap:0.5rem; margin-top:0.75rem;">
      <input name="id" placeholder="Account UUID" style={inp()} autocomplete="off" />
      <button type="submit" style={btn_blue()}>Load Statements</button>
    </form>
    <%= case @results do %>
      <% {:cms_account, a} when not is_nil(a) -> %>
        <div style="margin-top:1rem; background:#161b22; border:1px solid #30363d;
                    border-radius:8px; padding:1rem; font-size:0.82rem; color:#8b949e;">
          Account <code style="color:#58a6ff;">{a.account_id}</code> found.
          Statement detail is generated by <code>CMS.EOD.StatementGeneratorJob</code> each billing cycle.
          Query the <code>cms_statements</code> table for cycle closing balances, minimum payments, and due dates.
        </div>
      <% _ -> %>
        <div />
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # CMS05 — Card Inquiry
  # ---------------------------------------------------------------------------

  defp render_cms05(assigns) do
    ~H"""
    <%= screen_header("CMS05", "Card Inquiry", "Card status, expiry, emboss name, supplementary cards and block history", assigns) %>
    <div style="max-width:900px;">
      <%!-- Search bar --%>
      <div style="display:flex; gap:0.5rem; margin-bottom:1rem;">
        <form phx-submit="cms_card_inquiry" style="flex:1; display:flex; gap:0.5rem;">
          <input name="account_id" placeholder="Primary Account UUID" style={inp()} autocomplete="off" />
          <button type="submit" style={btn_blue()}>Inquire</button>
        </form>
      </div>

      <%= case @results do %>
        <% {:cms_account, nil} -> %>
          <%= error_box("Account not found") %>

        <% {:cms_account, a} -> %>
          <%!-- Card header --%>
          <div style="background:#161b22; border:1px solid #30363d; border-radius:8px;
                      padding:1.25rem; display:grid; grid-template-columns:repeat(3,1fr); gap:0.5rem 1.5rem;
                      margin-bottom:1rem;">
            <%= kv("Account ID",    a.account_id) %>
            <%= kv("Account Status", a.account_status) %>
            <%= kv("Block Code",    a.block_code || "—") %>
            <%= kv("Emboss Name",   a.emboss_name || "—") %>
            <%= kv("PAN Token",     a.pan_token) %>
            <%= kv("Cycle Code",    "#{a.cycle_code}") %>
            <%= kv("Credit Limit",  "#{a.credit_limit} AED") %>
            <%= kv("Open-to-Buy",   "#{a.open_to_buy} AED") %>
            <%= kv("Open Date",     a.open_date) %>
          </div>

          <%!-- Supplementary cards --%>
          <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem; margin-bottom:1rem;">
            <div style="font-size:0.8rem; font-weight:600; color:#c9d1d9; letter-spacing:0.04em; margin-bottom:0.75rem;">
              🪪 Supplementary Cards
            </div>
            <%= if @supp_cards == [] do %>
              <div style="color:#8b949e; font-size:0.78rem;">No supplementary cards on this account.</div>
            <% else %>
              <%= data_table(
                ["Supp Account", "Relationship", "Emboss Name", "Status", "Since"],
                Enum.map(@supp_cards, fn s ->
                  [s.supplementary_account_id, s.relationship, s.emboss_name, s.status, s.inserted_at]
                end)
              ) %>
            <% end %>
          </div>

          <%!-- Block code history --%>
          <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem;">
            <div style="font-size:0.8rem; font-weight:600; color:#c9d1d9; letter-spacing:0.04em; margin-bottom:0.75rem;">
              🔒 Block Code History (last 20)
            </div>
            <%= if @block_history == [] do %>
              <div style="color:#8b949e; font-size:0.78rem;">No block code history recorded.</div>
            <% else %>
              <%= data_table(
                ["Block Code", "Reason", "Narrative", "Operator", "Role", "Applied At"],
                Enum.map(@block_history, fn h ->
                  [h.block_code, h.reason_code, h.narrative, h.operator_id, h.operator_role, h.applied_at]
                end)
              ) %>
            <% end %>
          </div>

        <% _ -> %>
          <%= hint("Enter a primary account UUID to view full card details, supplementary cards, and block history.") %>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # CIF01 — Customer Search
  # ---------------------------------------------------------------------------

  defp render_cif01(assigns) do
    ~H"""
    <%= screen_header("CIF01", "Customer Search", "Search by name, national ID or customer UUID", assigns) %>
    <div style="max-width:700px;">
      <form phx-submit="cif_search" style="display:flex; gap:0.5rem; margin-bottom:1rem;">
        <input name="q" placeholder="Name, National ID or Customer UUID" style="#{inp()} flex:1;" autocomplete="off" />
        <button type="submit" style={btn_blue()}>Search</button>
      </form>
      <%= case @results do %>
        <% {:cif_list, []} -> %>
          <%= empty_state("No customers found") %>
        <% {:cif_list, rows} -> %>
          <%= data_table(
              ["Customer ID", "Full Name", "National ID", "KYC Tier", "Risk Flag"],
              Enum.map(rows, fn r -> [r.customer_id, r.full_name, r.national_id, r.kyc_tier, r.risk_flag] end)
          ) %>
        <% _ -> %>
          <%= hint("Search by partial name, national ID, or exact customer UUID.") %>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # CIF02 — KYC Management
  # ---------------------------------------------------------------------------

  defp render_cif02(assigns) do
    ~H"""
    <%= screen_header("CIF02", "KYC Management", "KYC tier, ID verification, and risk flag management", assigns) %>
    <%= hint("KYC data is managed via the CIF.Customer schema. Use CIF01 to search, then navigate to the customer record for KYC updates.") %>
    <div style="margin-top:1rem; background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem;">
      <div style="font-size:0.82rem; color:#c9d1d9; margin-bottom:0.75rem; font-weight:600;">KYC Tier Reference</div>
      <%= data_table(
          ["Tier", "Label", "ID Required", "Max Credit Limit"],
          [
            ["1", "Basic (Unverified)",  "None",                         "AED 5,000"],
            ["2", "Standard (Verified)", "Emirates ID / Passport",       "AED 50,000"],
            ["3", "Enhanced",            "Emirates ID + Proof of Income", "AED 200,000"],
            ["4", "Premium",             "Full KYC Pack",                 "No cap"]
          ]
      ) %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # CTA01 — Card Stock Management
  # ---------------------------------------------------------------------------

  defp render_cta01(assigns) do
    ~H"""
    <%= screen_header("CTA01", "Card Stock Management", "BIN stock levels, reorder thresholds, stock alerts", assigns) %>
    <%= hint("Card stock data is managed via the CTA.CardStock schema. Query the cta_card_stock table for current stock levels by BIN range.") %>
    <div style="margin-top:1rem; background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem;">
      <div style="font-size:0.82rem; color:#8b949e;">
        Card personalisation is a three-step process in VisionPlus:
        <ol style="margin:0.5rem 0 0 1.25rem; display:flex; flex-direction:column; gap:0.3rem;">
          <li><code style="color:#3fb950;">CTA01</code> — Reserve card stock from BIN pool</li>
          <li><code style="color:#3fb950;">CTA02</code> — Submit embossing order to personalisation bureau</li>
          <li><code style="color:#3fb950;">CTA03</code> — Activate on first use or via IVR PIN set</li>
        </ol>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # CTA02 — Embossing Orders
  # ---------------------------------------------------------------------------

  defp render_cta02(assigns) do
    ~H"""
    <%= screen_header("CTA02", "Embossing Orders", "Card personalisation queue and delivery tracking", assigns) %>
    <%= hint("Embossing orders are queued in cta_embossing_orders. The personalisation bureau picks up orders daily and returns confirmed delivery status.") %>
    <div style="margin-top:1rem; background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem; font-size:0.82rem; color:#8b949e;">
      Order states: <code>PENDING → DISPATCHED_TO_BUREAU → PRINTED → DISPATCHED_TO_CARDHOLDER → DELIVERED</code>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # CTA03 — Card Activation / PIN
  # ---------------------------------------------------------------------------

  defp render_cta03(assigns) do
    ~H"""
    <%= screen_header("CTA03", "Card Activation / PIN", "Activate card, reset PIN, replace card", assigns) %>
    <div style="max-width:600px; background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem;">
      <div style="font-size:0.82rem; color:#c9d1d9; margin-bottom:1rem; font-weight:600;">Available Actions</div>
      <%= data_table(
          ["Action", "Module", "Description"],
          [
            ["Activate Card",   "CTA.CardActivation",   "First-use or OTP-verified activation"],
            ["Reset PIN",       "IVR.OtpEngine",        "Verify via HOTP then allow PIN change"],
            ["Replace Card",    "CTA.CardReplace",      "Reissue — old PAN expired, new PAN + embossing order"],
            ["Block Card",      "CMS.AccountMaint",     "Immediate block — transactions declined RC=62"]
          ]
      ) %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # IVR01 — Session Monitor
  # ---------------------------------------------------------------------------

  defp render_ivr01(assigns) do
    ~H"""
    <%= screen_header("IVR01", "Session Monitor", "Live IVR session state — active calls and OTP channel status", assigns) %>
    <div style="max-width:700px;">
      <%= hint("IVR sessions are managed by VmuCore.IVR.IvrSession (Horde-registered GenServer, 5-min idle timeout, 3 PIN attempts).") %>
      <div style="margin-top:1rem; background:#161b22; border:1px solid #30363d;
                  border-radius:8px; padding:1rem; font-size:0.82rem;">
        <div style="color:#c9d1d9; font-weight:600; margin-bottom:0.75rem;">Session State Machine</div>
        <div style="display:flex; align-items:center; gap:0.5rem; flex-wrap:wrap; color:#8b949e;">
          <%= for {state, color} <- [{"IDLE","#8b949e"}, {"→","#30363d"}, {"GREETING","#3fb950"},
                {"→","#30363d"}, {"MENU","#58a6ff"}, {"→","#30363d"},
                {"OTP_CHALLENGE","#d29922"}, {"→","#30363d"}, {"AUTHENTICATED","#3fb950"},
                {"→","#30363d"}, {"TERMINATED","#6e7681"}] do %>
            <code style={"color:#{color}; font-size:0.75rem;"}>{state}</code>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # IVR02 — OTP Management
  # ---------------------------------------------------------------------------

  defp render_ivr02(assigns) do
    ~H"""
    <%= screen_header("IVR02", "OTP Management", "HOTP (RFC 4226) and TOTP (RFC 6238) seed management", assigns) %>
    <div style="max-width:700px;">
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem;">
        <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:0.75rem;">OTP Configuration</div>
        <%= data_table(
            ["Algorithm", "Standard", "Window", "Digits", "Use Case"],
            [
              ["HOTP", "RFC 4226", "Counter-based ±1", "6", "IVR PIN verification"],
              ["TOTP", "RFC 6238", "30s window ±1 step", "6", "Mobile banking OTP"]
            ]
        ) %>
        <div style="margin-top:1rem; font-size:0.78rem; color:#8b949e;">
          OTP seeds are stored in <code>ivr_otp_seeds</code>.
          Managed by <code>VmuCore.IVR.OtpEngine</code>.
          SHA-256 HMAC — no TOTP seeds stored in plaintext.
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # DPS01 — Dispute Management
  # ---------------------------------------------------------------------------

  defp render_dps01(assigns) do
    ~H"""
    <%= screen_header("DPS01", "Dispute Management", "File, track and resolve cardholder disputes", assigns) %>
    <form phx-submit="dps_list" style="display:flex; gap:0.5rem; margin-bottom:1rem;">
      <select name="status" style={inp()}>
        <option value="">All States</option>
        <option>FILED</option>
        <option>CHARGEBACK_FILED</option>
        <option>PRE_ARB</option>
        <option>CLOSED_WON</option>
        <option>CLOSED_LOST</option>
      </select>
      <button type="submit" style={btn_blue()}>Filter</button>
    </form>
    <%= case @results do %>
      <% {:dps_list, []} -> %>
        <%= empty_state("No disputes found") %>
      <% {:dps_list, rows} -> %>
        <%= data_table(
            ["ID", "Account", "Type", "Amount", "State", "Network", "Filed"],
            Enum.map(rows, fn r -> [r.id, r.account_id, r.dispute_type, r.amount, r.state, r.network, r.inserted_at] end)
        ) %>
      <% _ -> %>
        <%= hint("Filter by state to browse disputes. All disputes go through: FILED → CHARGEBACK_FILED → PRE_ARB → CLOSED.") %>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # DPS02 — Chargeback Tracking
  # ---------------------------------------------------------------------------

  defp render_dps02(assigns) do
    ~H"""
    <%= screen_header("DPS02", "Chargeback Tracking", "Network SLA deadlines and chargeback lifecycle", assigns) %>
    <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem; max-width:700px;">
      <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:0.75rem;">Network Chargeback Deadlines</div>
      <%= data_table(
          ["Network", "Chargeback Window", "Pre-Arb Window", "Copy Request SLA", "Notes"],
          [
            ["Mastercard", "120 days from txn date", "45 days from CB", "30 days", "MC chargeback reason codes 4xxx"],
            ["Visa",       "120 days from txn date", "30 days from CB", "30 days", "Visa dispute reason codes 1xxx/2xxx/3xxx"]
          ]
      ) %>
      <div style="margin-top:1rem; font-size:0.78rem; color:#8b949e;">
        Deadlines enforced by <code>VmuCore.DPS.DeadlineJob</code> (daily Oban).
        Copy requests flow through <code>VmuCore.ITS.CopyRequestManager</code>.
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # TRAMS01 — Clearing Records
  # ---------------------------------------------------------------------------

  defp render_trams01(assigns) do
    ~H"""
    <%= screen_header("TRAMS01", "Clearing Records", "IPM / Base II clearing file browser", assigns) %>
    <form phx-submit="trams_clearing" style="display:flex; gap:0.5rem; margin-bottom:1rem; flex-wrap:wrap;">
      <select name="network" style={inp()}>
        <option value="">All Networks</option>
        <option value="MASTERCARD">Mastercard</option>
        <option value="VISA">Visa</option>
      </select>
      <input name="from" placeholder="From date (YYYY-MM-DD)" style="#{inp()} width:175px;" />
      <button type="submit" style={btn_blue()}>Browse</button>
    </form>
    <%= case @results do %>
      <% {:trams_clearing, []} -> %>
        <%= empty_state("No clearing records found") %>
      <% {:trams_clearing, rows} -> %>
        <%= data_table(
            ["Network", "PAN Token", "Amount", "Date", "MCC", "ARN"],
            Enum.map(rows, fn r -> [r.network, r.pan_token, r.amount, r.clearing_date, r.mcc, r.arn] end)
        ) %>
      <% _ -> %>
        <%= hint("Filter by network and/or date. Records are ingested by the Broadway IpmPipeline from Mastercard IPM and Visa Base II files.") %>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # TRAMS02 — IPM Processing Status
  # ---------------------------------------------------------------------------

  defp render_trams02(assigns) do
    ~H"""
    <%= screen_header("TRAMS02", "IPM Processing Status", "Broadway pipeline throughput and batch file status", assigns) %>
    <div style="max-width:700px;">
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem; margin-bottom:1rem;">
        <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:0.75rem;">Broadway Pipeline Architecture</div>
        <%= data_table(
            ["Stage", "Module", "Concurrency", "Notes"],
            [
              ["Producer",    "TRAMS.IpmPipeline",   "1",  "Reads IPM/Base2 file from disk or S3"],
              ["Processors",  "TRAMS.IpmPipeline",   "10", "Parse + validate + GL post each record"],
              ["GL Batcher",  "TRAMS.IpmPipeline",   "1",  "Batches GL writes, 100 records per batch"],
              ["ITS Wiring",  "ITS.FeeClaimProcessor","—", "Called after each clearing record insert"]
            ]
        ) %>
      </div>
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem;">
        <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:0.75rem;">Clearing Batch Schedule</div>
        <%= data_table(
            ["Job", "Time", "Description"],
            [
              ["TRAMS Clearing",   "21:30",  "Process IPM/Base2 files received during the day"],
              ["ITS1BatchJob",     "21:00",  "Extract PENDING copy requests + CHARGEBACK_FILED disputes"],
              ["CMS EOD",          "23:00",  "Lock cycles → Accrue interest → Age DPD → Statements → Flush GL"],
              ["ITS2BatchJob",     "02:00",  "Receive scheme responses: COPY_RESPONSE + FAR records"]
            ]
        ) %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # COL01 — Collection Cases
  # ---------------------------------------------------------------------------

  defp render_col01(assigns) do
    ~H"""
    <%= screen_header("COL01", "Collection Cases", "Active collection queue with DPD bucket and dunning status", assigns) %>
    <form phx-submit="col_cases" style="display:flex; gap:0.5rem; margin-bottom:1rem;">
      <select name="bucket" style={inp()}>
        <option value="">All DPD Buckets</option>
        <option value="30">30 DPD</option>
        <option value="60">60 DPD</option>
        <option value="90">90 DPD</option>
        <option value="120">120+ DPD</option>
      </select>
      <button type="submit" style={btn_blue()}>Load Cases</button>
    </form>
    <%= case @results do %>
      <% {:col_cases, []} -> %>
        <%= empty_state("No collection cases in selected bucket") %>
      <% {:col_cases, rows} -> %>
        <%= data_table(
            ["Account", "DPD", "Outstanding (AED)", "Status", "Assigned To", "Next Action"],
            Enum.map(rows, fn r -> [r.account_id, r.dpd_bucket, r.outstanding, r.status, r.assigned_to, r.next_action_date] end)
        ) %>
      <% _ -> %>
        <%= hint("Select a DPD bucket to load collection cases. Cases route to collectors via the dunning strategy configured in ParameterEngine.") %>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # COL02 — Write-off Management
  # ---------------------------------------------------------------------------

  defp render_col02(assigns) do
    ~H"""
    <%= screen_header("COL02", "Write-off Management", "Write-off decisions and recovery ledger", assigns) %>
    <div style="max-width:700px;">
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem;">
        <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:0.75rem;">Write-off Process</div>
        <%= data_table(
            ["Step", "Action", "GL Entry", "Status Change"],
            [
              ["1", "Manager approves write-off",     "—",                         "CASE: PENDING_WRITEOFF"],
              ["2", "COL.WriteoffService posts GL",   "DR col_writeoff / CR cms_loan_receivable", "CASE: WRITTEN_OFF"],
              ["3", "Metro2 export",                  "—",                         "Metro 2 code = '97'"],
              ["4", "Recovery payment received",      "DR cms_loan_receivable / CR col_recovery", "CASE: RECOVERED"]
            ]
        ) %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # CDM01 — Application Queue
  # ---------------------------------------------------------------------------

  defp render_cdm01(assigns) do
    ~H"""
    <%= screen_header("CDM01", "Application Queue", "Pending credit applications with scoring output", assigns) %>
    <form phx-submit="cdm_applications" style="display:flex; gap:0.5rem; margin-bottom:1rem;">
      <select name="status" style={inp()}>
        <option value="">All Statuses</option>
        <option value="PENDING">Pending</option>
        <option value="APPROVED">Approved</option>
        <option value="DECLINED">Declined</option>
        <option value="REFERRED">Referred</option>
      </select>
      <button type="submit" style={btn_blue()}>Load Applications</button>
    </form>
    <%= case @results do %>
      <% {:cdm_apps, []} -> %>
        <%= empty_state("No applications found") %>
      <% {:cdm_apps, rows} -> %>
        <%= data_table(
            ["Customer", "Status", "Risk Tier", "Requested (AED)", "Approved (AED)", "Submitted"],
            Enum.map(rows, fn r -> [r.customer_id, r.status, r.risk_tier, r.requested_limit, r.approved_limit, r.submitted_at] end)
        ) %>
      <% _ -> %>
        <%= hint("CDM applications are scored by ApplicationScorer → LimitAllocator. DSR cap enforced at 50% (UAE Central Bank).") %>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # CDM02 — Underwriting Decisions
  # ---------------------------------------------------------------------------

  defp render_cdm02(assigns) do
    ~H"""
    <%= screen_header("CDM02", "Underwriting Decisions", "Bureau results, DSR calculation, limit allocation", assigns) %>
    <div style="max-width:700px;">
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem; margin-bottom:1rem;">
        <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:0.75rem;">Scoring Tiers</div>
        <%= data_table(
            ["Tier", "Label", "Bureau Score Range", "Limit Multiplier", "Interest Rate"],
            [
              ["PRIME",       "Prime",      "720+",    "4.0x income", "Standard"],
              ["NEAR_PRIME",  "Near Prime", "620–719", "2.5x income", "Standard + 2%"],
              ["SUBPRIME",    "Sub-prime",  "580–619", "1.0x income", "Standard + 5%"],
              ["DECLINE",     "Declined",   "<580",    "—",           "—"]
            ]
        ) %>
      </div>
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem;">
        <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:0.5rem;">DSR Cap (UAE Central Bank)</div>
        <div style="font-size:0.78rem; color:#8b949e;">
          Debt-service ratio must not exceed <strong style="color:#d29922;">50%</strong> of declared monthly income.
          Enforced in <code>CDM.LimitAllocator.calculate/6</code>.
          DSR = (total_monthly_obligations + new_min_payment) / monthly_income.
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # ASM01 — Operator Management
  # ---------------------------------------------------------------------------

  defp render_asm01(assigns) do
    ~H"""
    <%= screen_header("ASM01", "Operator Management", "Operator roles, permissions, and session management", assigns) %>
    <div style="max-width:700px;">
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem;">
        <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:0.75rem;">Role Hierarchy</div>
        <%= data_table(
            ["Role", "Permissions"],
            [
              ["agent",       "View accounts, run auth test, view audit log"],
              ["supervisor",  "Agent + fee waivers, block/unblock accounts"],
              ["manager",     "Supervisor + credit limit change, account closure"],
              ["sysadmin",    "Manager + parameter refresh, operator management"]
            ]
        ) %>
        <div style="margin-top:1rem; font-size:0.78rem; color:#8b949e;">
          All operator actions are logged to <code>cms_operator_audit</code>.
          View the audit trail in <code>ASM03</code>.
          Production access requires FAPI 2.0 mTLS + RS256 JWT (G1 — <code>VmuCoreWeb.Plugs.FapiValidationPlug</code>).
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # ASM02 — System Parameters
  # ---------------------------------------------------------------------------

  defp render_asm02(assigns) do
    ~H"""
    <%= screen_header("ASM02", "System Parameters", "SYS→BANK→LOGO→BLOCK ETS parameter cache", assigns) %>
    <div style="max-width:700px;">
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem; margin-bottom:1rem;">
        <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:0.75rem;">Parameter Cascade</div>
        <div style="font-size:0.8rem; color:#8b949e; display:flex; align-items:center; gap:0.5rem; flex-wrap:wrap;">
          <%= for {level, color} <- [{"SYS","#6e7681"}, {"→","#30363d"}, {"BANK","#3fb950"},
                {"→","#30363d"}, {"LOGO","#58a6ff"}, {"→","#30363d"}, {"BLOCK","#d29922"}] do %>
            <code style={"color:#{color}; font-size:0.8rem;"}>{level}</code>
          <% end %>
        </div>
        <div style="margin-top:0.5rem; font-size:0.75rem; color:#8b949e;">
          Each level overrides the one above. Lookup: BLOCK → LOGO → BANK → SYS → default.
          Stored in ETS table <code>:parameter_engine</code>. Refreshed without restart.
        </div>
      </div>
      <button phx-click="asm_param_refresh"
        style={"#{btn_blue()} margin-bottom:1rem;"}>
        ↺ Refresh ETS Cache from Database
      </button>
      <%= render_action_result(assigns) %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # ASM03 — Audit Log
  # ---------------------------------------------------------------------------

  defp render_asm03(assigns) do
    ~H"""
    <%= screen_header("ASM03", "Audit Log", "Operator action trail — all role-gated operations", assigns) %>
    <form phx-submit="asm_audit_load" style="display:flex; gap:0.5rem; margin-bottom:1rem;">
      <input name="account_id" placeholder="Account UUID (leave blank for recent 40 entries)"
        style="#{inp()} flex:1;" autocomplete="off" />
      <button type="submit" style={btn_blue()}>Load</button>
    </form>
    <%= case @results do %>
      <% {:asm_audit, []} -> %>
        <%= empty_state("No audit records found") %>
      <% {:asm_audit, rows} -> %>
        <%= data_table(
            ["Time (UTC)", "Operator", "Role", "Action", "Subject"],
            Enum.map(rows, fn r -> [r.performed_at, r.operator_id, r.operator_role, r.action, r.subject] end)
        ) %>
      <% _ -> %>
        <%= hint("Enter an account UUID to filter, or leave blank to see the 40 most-recent entries.") %>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # ASM04 — SYS Parameter Setup
  # ---------------------------------------------------------------------------

  defp render_asm04(assigns) do
    ~H"""
    <%= screen_header("ASM04", "SYS Parameter Setup", "Root processor control record — SYS → BANK → LOGO → BLOCK", assigns) %>
    <div style="max-width:700px;">
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem; margin-bottom:1.25rem;">
        <div style="font-size:0.75rem; color:#8b949e; margin-bottom:0.5rem; font-weight:600;">Load existing SYS record</div>
        <form phx-submit="asm04_load" style="display:flex; gap:0.5rem;">
          <input name="sys_id" placeholder="SYS ID (4 chars)" maxlength="4"
            style={"#{inp()} max-width:160px; font-family:monospace;"} autocomplete="off" />
          <button type="submit" style={btn_blue()}>Load</button>
        </form>
        <%= case @results do %>
          <% {:asm04_record, r} -> %>
            <%= data_table(
                ["Field", "Current Value"],
                [
                  ["sys_id",              r.sys_id],
                  ["description",         r.description],
                  ["base_currency",       r.base_currency],
                  ["batch_controls",      Jason.encode!(r.batch_controls || %{})],
                  ["cycle_controls",      Jason.encode!(r.cycle_controls || %{})],
                  ["global_status_codes", Enum.join(r.global_status_codes || [], ", ")],
                  ["posting_rules",       Jason.encode!(r.posting_rules || %{})]
                ]
            ) %>
          <% {:asm04_not_found, id} -> %>
            <%= hint("No SYS record found for '#{id}' — fill the form below to create it.") %>
          <% _ -> %><% end %>
      </div>

      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem;">
        <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:1rem;">Create / Update SYS Record</div>
        <form phx-submit="asm04_save" style={form_style()}>
          <div style={form_row()}>
            <%= field_label("SYS ID (exactly 4 chars) *") %>
            <input name="sys_id" placeholder="e.g. SYS1" maxlength="4" required
              style={"#{inp()} font-family:monospace; max-width:160px;"} autocomplete="off" />
          </div>
          <div style={form_row()}>
            <%= field_label("Description *") %>
            <input name="description" placeholder="e.g. UAE Processor System" required style={inp()} />
          </div>
          <div style={form_row()}>
            <%= field_label("Base Currency (ISO 4217, 3 chars)") %>
            <input name="base_currency" placeholder="AED" maxlength="3" value="AED"
              style={"#{inp()} max-width:120px; font-family:monospace;"} />
          </div>
          <div style={form_row()}>
            <%= field_label("Global Status Codes (comma-separated)") %>
            <input name="global_status_codes" placeholder="ACTIVE, BLOCKED, CLOSED, DORMANT"
              style={inp()} />
          </div>
          <div style={form_row()}>
            <%= field_label("Batch Controls (JSON — optional)") %>
            <textarea name="batch_controls" rows="4"
              placeholder={"{\n  \"eod_window_start\": \"22:00\",\n  \"eod_window_end\": \"04:00\",\n  \"max_job_retries\": 3\n}"}
              style={"#{inp()} font-family:monospace; resize:vertical;"}></textarea>
          </div>
          <div style={form_row()}>
            <%= field_label("Cycle Controls (JSON — optional)") %>
            <textarea name="cycle_controls" rows="3"
              placeholder={"{\n  \"default_cycle_day\": 1,\n  \"cycle_length_days\": 30\n}"}
              style={"#{inp()} font-family:monospace; resize:vertical;"}></textarea>
          </div>
          <div style={form_row()}>
            <%= field_label("Posting Rules (JSON — optional)") %>
            <textarea name="posting_rules" rows="3"
              placeholder={"{\n  \"posting_cutoff_time\": \"23:59\",\n  \"max_backdate_days\": 3\n}"}
              style={"#{inp()} font-family:monospace; resize:vertical;"}></textarea>
          </div>
          <button type="submit" style={btn_green()}>💾 Save SYS Record</button>
        </form>
      </div>
      <%= render_action_result(assigns) %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # ASM05 — BANK Parameter Setup
  # ---------------------------------------------------------------------------

  defp render_asm05(assigns) do
    ~H"""
    <%= screen_header("ASM05", "BANK Parameter Setup", "Institution-level control record — sits below SYS, above LOGO", assigns) %>
    <div style="max-width:700px;">
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem; margin-bottom:1.25rem;">
        <div style="font-size:0.75rem; color:#8b949e; margin-bottom:0.5rem; font-weight:600;">Load existing BANK record</div>
        <form phx-submit="asm05_load" style="display:flex; gap:0.5rem; flex-wrap:wrap;">
          <input name="bank_id" placeholder="BANK ID (4 chars)" maxlength="4"
            style={"#{inp()} max-width:160px; font-family:monospace;"} autocomplete="off" />
          <input name="sys_id" placeholder="SYS ID (4 chars)" maxlength="4"
            style={"#{inp()} max-width:160px; font-family:monospace;"} autocomplete="off" />
          <button type="submit" style={btn_blue()}>Load</button>
        </form>
        <%= case @results do %>
          <% {:asm05_record, r} -> %>
            <%= data_table(
                ["Field", "Current Value"],
                [
                  ["bank_id",            r.bank_id],
                  ["sys_id",             r.sys_id],
                  ["description",        r.description],
                  ["org_name",           r.org_name],
                  ["country_code",       r.country_code],
                  ["base_currency",      r.base_currency],
                  ["billing_timezone",   r.billing_timezone],
                  ["regulatory_regime",  r.regulatory_regime],
                  ["swift_bic",          r.swift_bic],
                  ["gl_mapping_profile", r.gl_mapping_profile],
                  ["tax_rule",           Jason.encode!(r.tax_rule || %{})],
                  ["delinquency_rules",  Jason.encode!(r.delinquency_rules || %{})]
                ]
            ) %>
          <% {:asm05_not_found, id} -> %>
            <%= hint("No BANK record found for '#{id}' — fill the form below to create it.") %>
          <% _ -> %><% end %>
      </div>

      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem;">
        <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:1rem;">Create / Update BANK Record</div>
        <form phx-submit="asm05_save" style={form_style()}>
          <div style="display:flex; gap:0.75rem; flex-wrap:wrap;">
            <div style={"#{form_row()} flex:1; min-width:140px;"}>
              <%= field_label("BANK ID (4 chars) *") %>
              <input name="bank_id" placeholder="e.g. BNK1" maxlength="4" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
            <div style={"#{form_row()} flex:1; min-width:140px;"}>
              <%= field_label("SYS ID (4 chars) *") %>
              <input name="sys_id" placeholder="e.g. SYS1" maxlength="4" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
          </div>
          <div style={form_row()}>
            <%= field_label("Description *") %>
            <input name="description" placeholder="e.g. First National Bank UAE" required style={inp()} />
          </div>
          <div style={form_row()}>
            <%= field_label("Organisation Name") %>
            <input name="org_name" placeholder="e.g. First National Bank" style={inp()} />
          </div>
          <div style="display:flex; gap:0.75rem; flex-wrap:wrap;">
            <div style={"#{form_row()} flex:1; min-width:120px;"}>
              <%= field_label("Country Code (ISO alpha-3)") %>
              <input name="country_code" placeholder="ARE" maxlength="3" value="ARE"
                style={"#{inp()} font-family:monospace;"} />
            </div>
            <div style={"#{form_row()} flex:1; min-width:120px;"}>
              <%= field_label("Base Currency") %>
              <input name="base_currency" placeholder="AED" maxlength="3" value="AED"
                style={"#{inp()} font-family:monospace;"} />
            </div>
          </div>
          <div style="display:flex; gap:0.75rem; flex-wrap:wrap;">
            <div style={"#{form_row()} flex:1; min-width:180px;"}>
              <%= field_label("Billing Timezone (IANA)") %>
              <input name="billing_timezone" placeholder="Asia/Dubai" value="Asia/Dubai" style={inp()} />
            </div>
            <div style={"#{form_row()} flex:1; min-width:150px;"}>
              <%= field_label("Regulatory Regime") %>
              <input name="regulatory_regime" placeholder="CBUAE" value="CBUAE" style={inp()} />
            </div>
          </div>
          <div style="display:flex; gap:0.75rem; flex-wrap:wrap;">
            <div style={"#{form_row()} flex:1; min-width:150px;"}>
              <%= field_label("SWIFT BIC") %>
              <input name="swift_bic" placeholder="FNBAUAED" maxlength="11"
                style={"#{inp()} font-family:monospace;"} />
            </div>
            <div style={"#{form_row()} flex:1; min-width:150px;"}>
              <%= field_label("GL Mapping Profile") %>
              <input name="gl_mapping_profile" placeholder="UAE_STD" maxlength="20" style={inp()} />
            </div>
          </div>
          <div style={form_row()}>
            <%= field_label("Tax Rule (JSON — optional)") %>
            <textarea name="tax_rule" rows="4"
              placeholder={"{\n  \"vat_rate\": \"0.05\",\n  \"tax_code\": \"AE-VAT\",\n  \"tax_on_fees\": true\n}"}
              style={"#{inp()} font-family:monospace; resize:vertical;"}></textarea>
          </div>
          <div style={form_row()}>
            <%= field_label("Delinquency Rules (JSON — optional)") %>
            <textarea name="delinquency_rules" rows="4"
              placeholder={"{\n  \"col_handoff_dpd\": 120,\n  \"write_off_dpd\": 180,\n  \"suspend_at_dpd\": 60\n}"}
              style={"#{inp()} font-family:monospace; resize:vertical;"}></textarea>
          </div>
          <div style={form_row()}>
            <%= field_label("Settlement Calendar (JSON — optional)") %>
            <textarea name="settlement_calendar" rows="3"
              placeholder={"{\n  \"cutoff_time\": \"23:00\",\n  \"settlement_days\": [\"MON\",\"TUE\",\"WED\",\"THU\"]\n}"}
              style={"#{inp()} font-family:monospace; resize:vertical;"}></textarea>
          </div>
          <button type="submit" style={btn_green()}>💾 Save BANK Record</button>
        </form>
      </div>
      <%= render_action_result(assigns) %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # ASM06 — Logo / Product Parameter Setup
  # ---------------------------------------------------------------------------

  defp render_asm06(assigns) do
    ~H"""
    <%= screen_header("ASM06", "Logo / Product Setup", "Card product template — APRs, fees, billing, auth flags, limits", assigns) %>
    <div style="max-width:760px;">

      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem; margin-bottom:1.25rem;">
        <div style="font-size:0.75rem; color:#8b949e; margin-bottom:0.5rem; font-weight:600;">Load existing LOGO record</div>
        <form phx-submit="asm06_load" style="display:flex; gap:0.5rem; flex-wrap:wrap;">
          <input name="logo_id" placeholder="LOGO (4)" maxlength="4"
            style={"#{inp()} max-width:120px; font-family:monospace;"} autocomplete="off" />
          <input name="sys_id"  placeholder="SYS (4)"  maxlength="4"
            style={"#{inp()} max-width:120px; font-family:monospace;"} autocomplete="off" />
          <input name="bank_id" placeholder="BANK (4)" maxlength="4"
            style={"#{inp()} max-width:120px; font-family:monospace;"} autocomplete="off" />
          <button type="submit" style={btn_blue()}>Load</button>
        </form>
        <%= case @results do %>
          <% {:asm06_record, r} -> %>
            <%= data_table(
                ["Field", "Value", "Field", "Value"],
                [
                  ["logo_id",        r.logo_id,      "bin_prefix",       r.bin_prefix],
                  ["purchase_apr",   r.purchase_apr,  "cash_apr",         r.cash_apr],
                  ["penalty_apr",    r.penalty_apr,   "promo_apr",        r.promo_apr],
                  ["annual_fee",     r.annual_fee,    "late_fee",         r.late_fee],
                  ["overlimit_fee",  r.overlimit_fee, "replacement_fee",  r.replacement_fee],
                  ["ecom_enabled",   r.ecom_enabled,  "atm_enabled",      r.atm_enabled],
                  ["intl_enabled",   r.intl_enabled,  "contactless",      r.contactless_enabled],
                  ["credit_limit_default", r.credit_limit_default, "credit_limit_max", r.credit_limit_max],
                  ["stip_enabled",   r.stip_enabled,  "stip_max_amount",  r.stip_max_amount]
                ]
            ) %>
          <% {:asm06_not_found, id} -> %>
            <%= hint("No LOGO record found for '#{id}' — fill the form below to create it.") %>
          <% _ -> %><% end %>
      </div>

      <form phx-submit="asm06_save">
        <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem; margin-bottom:1rem;">
          <div style="font-size:0.8rem; color:#58a6ff; font-weight:700; margin-bottom:0.75rem;">🔑 Identity</div>
          <div style="display:flex; gap:0.75rem; flex-wrap:wrap;">
            <div style={"#{form_row()} flex:1; min-width:100px;"}>
              <%= field_label("LOGO ID (4) *") %>
              <input name="logo_id" placeholder="LOG1" maxlength="4" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
            <div style={"#{form_row()} flex:1; min-width:100px;"}>
              <%= field_label("SYS ID (4) *") %>
              <input name="sys_id" placeholder="SYS1" maxlength="4" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
            <div style={"#{form_row()} flex:1; min-width:100px;"}>
              <%= field_label("BANK ID (4) *") %>
              <input name="bank_id" placeholder="BNK1" maxlength="4" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
            <div style={"#{form_row()} flex:1; min-width:130px;"}>
              <%= field_label("BIN Prefix (6 digits) *") %>
              <input name="bin_prefix" placeholder="400000" maxlength="6" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
          </div>
          <div style={"#{form_row()} margin-top:0.75rem;"}>
            <%= field_label("Description *") %>
            <input name="description" placeholder="e.g. Classic Visa Credit Card" required style={inp()} />
          </div>
        </div>

        <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem; margin-bottom:1rem;">
          <div style="font-size:0.8rem; color:#d29922; font-weight:700; margin-bottom:0.75rem;">📈 Interest Rates (%)</div>
          <div style="display:grid; grid-template-columns:repeat(auto-fill,minmax(160px,1fr)); gap:0.75rem;">
            <div style={form_row()}>
              <%= field_label("Purchase APR") %>
              <input name="purchase_apr" placeholder="24.00" value="24.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Cash APR") %>
              <input name="cash_apr" placeholder="27.00" value="27.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Penalty APR") %>
              <input name="penalty_apr" placeholder="30.00" value="30.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Penalty DPD Trigger") %>
              <input name="penalty_apr_dpd_trigger" placeholder="60" value="60" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Promo APR (0% = no promo)") %>
              <input name="promo_apr" placeholder="0.00" value="0.00" style={inp()} />
            </div>
          </div>
        </div>

        <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem; margin-bottom:1rem;">
          <div style="font-size:0.8rem; color:#3fb950; font-weight:700; margin-bottom:0.75rem;">💸 Fees (base currency)</div>
          <div style="display:grid; grid-template-columns:repeat(auto-fill,minmax(160px,1fr)); gap:0.75rem;">
            <div style={form_row()}>
              <%= field_label("Annual Fee") %>
              <input name="annual_fee" placeholder="0.00" value="0.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Late Fee") %>
              <input name="late_fee" placeholder="100.00" value="100.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Overlimit Fee") %>
              <input name="overlimit_fee" placeholder="50.00" value="50.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Replacement Fee") %>
              <input name="replacement_fee" placeholder="50.00" value="50.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Returned Payment Fee") %>
              <input name="returned_payment_fee" placeholder="100.00" value="100.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Card Replacement Fee") %>
              <input name="card_replacement_fee" placeholder="50.00" value="50.00" style={inp()} />
            </div>
          </div>
        </div>

        <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem; margin-bottom:1rem;">
          <div style="font-size:0.8rem; color:#bc8cff; font-weight:700; margin-bottom:0.75rem;">📅 Billing Behaviour</div>
          <div style="display:grid; grid-template-columns:repeat(auto-fill,minmax(160px,1fr)); gap:0.75rem;">
            <div style={form_row()}>
              <%= field_label("Min Payment %") %>
              <input name="min_payment_pct" placeholder="5.0" value="5.0" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Min Payment Floor") %>
              <input name="min_payment_floor" placeholder="25.00" value="25.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Grace Days") %>
              <input name="grace_days" placeholder="25" value="25" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Cash Limit %") %>
              <input name="cash_limit_pct" placeholder="30.0" value="30.0" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Statement Cycle Days") %>
              <input name="statement_cycle_days" placeholder="30" value="30" style={inp()} />
            </div>
          </div>
        </div>

        <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem; margin-bottom:1rem;">
          <div style="font-size:0.8rem; color:#f78166; font-weight:700; margin-bottom:0.75rem;">🔐 Auth Flags</div>
          <div style="display:grid; grid-template-columns:repeat(auto-fill,minmax(200px,1fr)); gap:0.5rem;">
            <%= for {fname, label, default} <- [
                  {"ecom_enabled", "E-Commerce", "true"},
                  {"atm_enabled",  "ATM / Cash", "true"},
                  {"intl_enabled", "International", "false"},
                  {"contactless_enabled", "Contactless", "true"}
                ] do %>
              <div style="display:flex; align-items:center; gap:0.5rem; padding:0.4rem 0;">
                <select name={fname}
                  style="background:#0d1117; border:1px solid #30363d; border-radius:5px; color:#e6edf3; padding:0.35rem 0.5rem; font-size:0.8rem; min-width:80px;">
                  <option value="true" selected={default == "true"}>Enabled</option>
                  <option value="false" selected={default == "false"}>Disabled</option>
                </select>
                <span style="font-size:0.8rem; color:#c9d1d9;">{label}</span>
              </div>
            <% end %>
          </div>
        </div>

        <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem; margin-bottom:1rem;">
          <div style="font-size:0.8rem; color:#79c0ff; font-weight:700; margin-bottom:0.75rem;">💳 Credit Limits & STIP</div>
          <div style="display:grid; grid-template-columns:repeat(auto-fill,minmax(160px,1fr)); gap:0.75rem;">
            <div style={form_row()}>
              <%= field_label("Default Credit Limit") %>
              <input name="credit_limit_default" placeholder="5000.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Max Credit Limit") %>
              <input name="credit_limit_max" placeholder="50000.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("STIP Enabled") %>
              <select name="stip_enabled"
                style="background:#0d1117; border:1px solid #30363d; border-radius:5px; color:#e6edf3; padding:0.45rem 0.5rem; font-size:0.82rem; width:100%;">
                <option value="false" selected>Disabled</option>
                <option value="true">Enabled</option>
              </select>
            </div>
            <div style={form_row()}>
              <%= field_label("STIP Floor Limit") %>
              <input name="stip_floor_limit" placeholder="50.00" value="50.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("STIP Max Amount") %>
              <input name="stip_max_amount" placeholder="500.00" value="500.00" style={inp()} />
            </div>
          </div>
        </div>

        <button type="submit" style={"#{btn_green()} margin-top:0.5rem;"}>💾 Save LOGO / Product Record</button>
      </form>
      <%= render_action_result(assigns) %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # ASM07 — Block Code Setup
  # ---------------------------------------------------------------------------

  defp render_asm07(assigns) do
    ~H"""
    <%= screen_header("ASM07", "Block Code Setup", "Sub-product APR / limit overrides at BLOCK level", assigns) %>
    <div style="max-width:700px;">
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem; margin-bottom:1.25rem;">
        <div style="font-size:0.75rem; color:#8b949e; margin-bottom:0.5rem; font-weight:600;">Load existing BLOCK record</div>
        <form phx-submit="asm07_load" style="display:flex; gap:0.5rem; flex-wrap:wrap;">
          <input name="block_id" placeholder="BLOCK (4)" maxlength="4"
            style={"#{inp()} max-width:120px; font-family:monospace;"} autocomplete="off" />
          <input name="sys_id"   placeholder="SYS (4)"   maxlength="4"
            style={"#{inp()} max-width:120px; font-family:monospace;"} autocomplete="off" />
          <input name="bank_id"  placeholder="BANK (4)"  maxlength="4"
            style={"#{inp()} max-width:120px; font-family:monospace;"} autocomplete="off" />
          <input name="logo_id"  placeholder="LOGO (4)"  maxlength="4"
            style={"#{inp()} max-width:120px; font-family:monospace;"} autocomplete="off" />
          <button type="submit" style={btn_blue()}>Load</button>
        </form>
        <%= case @results do %>
          <% {:asm07_record, r} -> %>
            <%= data_table(
                ["Field", "Value"],
                [
                  ["block_id",                r.block_id],
                  ["sys_id / bank_id / logo_id", "#{r.sys_id} / #{r.bank_id} / #{r.logo_id}"],
                  ["apr_percentage",           to_string(r.apr_percentage)],
                  ["cash_apr_percentage",      to_string(r.cash_apr_percentage)],
                  ["cash_advance_fee_percent", to_string(r.cash_advance_fee_percent)],
                  ["credit_limit_default",     to_string(r.credit_limit_default)]
                ]
            ) %>
          <% {:asm07_not_found, id} -> %>
            <%= hint("No BLOCK record found for '#{id}' — fill the form below to create it.") %>
          <% _ -> %><% end %>
      </div>

      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem;">
        <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:1rem;">Create / Update BLOCK Record</div>
        <%= hint("Leave decimal fields blank to inherit the LOGO-level default (nil = fall back).") %>
        <form phx-submit="asm07_save" style={"#{form_style()} margin-top:1rem;"}>
          <div style="display:grid; grid-template-columns:repeat(auto-fill,minmax(120px,1fr)); gap:0.75rem;">
            <div style={form_row()}>
              <%= field_label("BLOCK ID (4) *") %>
              <input name="block_id" placeholder="BLK1" maxlength="4" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
            <div style={form_row()}>
              <%= field_label("SYS ID (4) *") %>
              <input name="sys_id" placeholder="SYS1" maxlength="4" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
            <div style={form_row()}>
              <%= field_label("BANK ID (4) *") %>
              <input name="bank_id" placeholder="BNK1" maxlength="4" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
            <div style={form_row()}>
              <%= field_label("LOGO ID (4) *") %>
              <input name="logo_id" placeholder="LOG1" maxlength="4" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
          </div>
          <div style="display:grid; grid-template-columns:repeat(auto-fill,minmax(160px,1fr)); gap:0.75rem; margin-top:0.75rem;">
            <div style={form_row()}>
              <%= field_label("Purchase APR Override") %>
              <input name="apr_percentage" placeholder="(inherit from LOGO)" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Cash APR Override") %>
              <input name="cash_apr_percentage" placeholder="(inherit from LOGO)" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Cash Advance Fee %") %>
              <input name="cash_advance_fee_percent" placeholder="(inherit from LOGO)" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Default Credit Limit") %>
              <input name="credit_limit_default" placeholder="(inherit from LOGO)" style={inp()} />
            </div>
          </div>
          <button type="submit" style={"#{btn_green()} margin-top:0.5rem;"}>💾 Save BLOCK Record</button>
        </form>
      </div>
      <%= render_action_result(assigns) %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # ASM08 — STIP Threshold Setup
  # ---------------------------------------------------------------------------

  defp render_asm08(assigns) do
    ~H"""
    <%= screen_header("ASM08", "STIP Threshold Setup", "Stand-in processing (offline approval) limits per LOGO", assigns) %>
    <div style="max-width:600px;">
      <%= hint("STIP allows the network to approve low-value transactions when the host is unreachable. Set floor (always approve below) and maximum (never approve above) per product.") %>

      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem; margin-top:1rem; margin-bottom:1.25rem;">
        <div style="font-size:0.75rem; color:#8b949e; margin-bottom:0.5rem; font-weight:600;">Load LOGO record</div>
        <form phx-submit="asm08_load" style="display:flex; gap:0.5rem; flex-wrap:wrap;">
          <input name="logo_id" placeholder="LOGO (4)" maxlength="4"
            style={"#{inp()} max-width:120px; font-family:monospace;"} autocomplete="off" />
          <input name="sys_id"  placeholder="SYS (4)"  maxlength="4"
            style={"#{inp()} max-width:120px; font-family:monospace;"} autocomplete="off" />
          <input name="bank_id" placeholder="BANK (4)" maxlength="4"
            style={"#{inp()} max-width:120px; font-family:monospace;"} autocomplete="off" />
          <button type="submit" style={btn_blue()}>Load</button>
        </form>
        <%= case @results do %>
          <% {:asm08_record, r} -> %>
            <%= data_table(
                ["Field", "Current Value"],
                [
                  ["logo_id",         r.logo_id],
                  ["stip_enabled",    to_string(r.stip_enabled)],
                  ["stip_floor_limit", to_string(r.stip_floor_limit)],
                  ["stip_max_amount", to_string(r.stip_max_amount)]
                ]
            ) %>
          <% {:asm08_not_found, id} -> %>
            <%= hint("LOGO '#{id}' not found. Create it in ASM06 first.") %>
          <% _ -> %><% end %>
      </div>

      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem;">
        <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:1rem;">Update STIP Thresholds</div>
        <form phx-submit="asm08_save" style={form_style()}>
          <div style="display:grid; grid-template-columns:repeat(3,1fr); gap:0.75rem;">
            <div style={form_row()}>
              <%= field_label("LOGO ID (4) *") %>
              <input name="logo_id" placeholder="LOG1" maxlength="4" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
            <div style={form_row()}>
              <%= field_label("SYS ID (4) *") %>
              <input name="sys_id"  placeholder="SYS1" maxlength="4" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
            <div style={form_row()}>
              <%= field_label("BANK ID (4) *") %>
              <input name="bank_id" placeholder="BNK1" maxlength="4" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
          </div>
          <div style={form_row()}>
            <%= field_label("STIP Enabled") %>
            <select name="stip_enabled"
              style="background:#0d1117; border:1px solid #30363d; border-radius:5px; color:#e6edf3; padding:0.45rem 0.5rem; font-size:0.82rem; max-width:200px;">
              <option value="false" selected>Disabled</option>
              <option value="true">Enabled</option>
            </select>
          </div>
          <div style={form_row()}>
            <%= field_label("Floor Limit (always approve below this amount)") %>
            <input name="stip_floor_limit" placeholder="50.00" value="50.00" style={"#{inp()} max-width:200px;"} />
          </div>
          <div style={form_row()}>
            <%= field_label("Max Amount (never approve above this)") %>
            <input name="stip_max_amount" placeholder="500.00" value="500.00" style={"#{inp()} max-width:200px;"} />
          </div>
          <button type="submit" style={btn_amber()}>💾 Update STIP Thresholds</button>
        </form>
      </div>
      <%= render_action_result(assigns) %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # PCM01 — Plan Segment Setup
  # ---------------------------------------------------------------------------

  defp render_pcm01(assigns) do
    ~H"""
    <%= screen_header("PCM01", "Plan Segment Setup", "Define EMI instalment plans linked to card products", assigns) %>
    <div style="max-width:760px;">
      <div style="display:flex; gap:0.75rem; margin-bottom:1rem;">
        <button phx-click="pcm01_list" style={btn_blue()}>📋 List All Plan Segments</button>
      </div>
      <%= case @results do %>
        <% {:pcm01_list, []} -> %>
          <%= empty_state("No plan segments found in plan_segments table") %>
        <% {:pcm01_list, rows} -> %>
          <%= data_table(
              ["Plan Code", "LOGO ID", "Tenure (months)", "Interest Rate", "Min Amount", "Status"],
              Enum.map(rows, fn r ->
                [r.plan_code, r.logo_id, r.tenure, r.interest_rate, r.min_amount, r.status]
              end)
          ) %>
        <% _ -> %><% end %>

      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem; margin-top:1.25rem;">
        <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:1rem;">Create Plan Segment</div>
        <form phx-submit="pcm01_save" style={form_style()}>
          <div style="display:grid; grid-template-columns:repeat(auto-fill,minmax(160px,1fr)); gap:0.75rem;">
            <div style={form_row()}>
              <%= field_label("Plan Code *") %>
              <input name="plan_code" placeholder="EMI03" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
            <div style={form_row()}>
              <%= field_label("LOGO ID *") %>
              <input name="logo_id" placeholder="LOG1" maxlength="4" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
            <div style={form_row()}>
              <%= field_label("Tenure (months)") %>
              <input name="tenure_months" placeholder="3" value="3" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Interest Rate %") %>
              <input name="interest_rate" placeholder="0.00" value="0.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Processing Fee %") %>
              <input name="processing_fee_percent" placeholder="0.00" value="0.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Min Transaction Amount") %>
              <input name="min_transaction_amount" placeholder="500.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Status") %>
              <select name="status"
                style="background:#0d1117; border:1px solid #30363d; border-radius:5px; color:#e6edf3; padding:0.45rem 0.5rem; font-size:0.82rem; width:100%;">
                <option value="ACTIVE" selected>ACTIVE</option>
                <option value="INACTIVE">INACTIVE</option>
                <option value="DRAFT">DRAFT</option>
              </select>
            </div>
          </div>
          <button type="submit" style={"#{btn_green()} margin-top:0.5rem;"}>➕ Create Plan Segment</button>
        </form>
      </div>
      <%= render_action_result(assigns) %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # PCM02 — Loyalty Scheme Setup
  # ---------------------------------------------------------------------------

  defp render_pcm02(assigns) do
    ~H"""
    <%= screen_header("PCM02", "Loyalty Scheme Setup", "Loyalty scheme, plan tier, and merchant group configuration", assigns) %>
    <div style="max-width:760px;">
      <div style="display:flex; gap:0.75rem; margin-bottom:1rem;">
        <button phx-click="pcm02_list" style={btn_blue()}>📋 List Loyalty Schemes</button>
      </div>
      <%= case @results do %>
        <% {:pcm02_list, []} -> %>
          <%= empty_state("No loyalty schemes configured — use LMS01 to browse once schemes are seeded") %>
        <% {:pcm02_list, rows} -> %>
          <%= data_table(
              ["Scheme Code", "Name", "Status"],
              Enum.map(rows, fn r -> [r.scheme_code, r.name, r.status] end)
          ) %>
        <% _ -> %>
          <%= hint("Click 'List Loyalty Schemes' to view active schemes. Scheme setup includes tiers (lms_rate_tiers), plans (lms_plans), and merchant groups (lms_merchant_groups). New schemes are typically seeded via seeds.exs or the LMS01 enrollment screen.") %>
      <% end %>

      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem; margin-top:1.25rem;">
        <div style="font-size:0.8rem; color:#8b949e; font-weight:600; margin-bottom:0.5rem;">Loyalty Table Reference</div>
        <%= data_table(
            ["Table", "Purpose"],
            [
              ["lms_schemes",          "Root scheme definition (code, name, currency)"],
              ["lms_plans",            "Plans under a scheme (spend threshold, earn rate)"],
              ["lms_rate_tiers",       "Earn rate tiers per plan (e.g. 1pt / AED 1)"],
              ["lms_merchant_groups",  "Bonus earn merchant category groups"],
              ["lms_accounts",         "Account enrollment (enroll via LMS02)"],
              ["lms_point_ledger",     "Individual point earn/burn entries"]
            ]
        ) %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # PCM03 — Fee Schedule
  # ---------------------------------------------------------------------------

  defp render_pcm03(assigns) do
    ~H"""
    <%= screen_header("PCM03", "Fee Schedule", "Edit per-logo fee amounts without touching seeds.exs", assigns) %>
    <div style="max-width:700px;">
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem; margin-bottom:1.25rem;">
        <div style="font-size:0.75rem; color:#8b949e; margin-bottom:0.5rem; font-weight:600;">Load LOGO fee schedule</div>
        <form phx-submit="pcm03_load" style="display:flex; gap:0.5rem; flex-wrap:wrap;">
          <input name="logo_id" placeholder="LOGO (4)" maxlength="4"
            style={"#{inp()} max-width:120px; font-family:monospace;"} autocomplete="off" />
          <input name="sys_id"  placeholder="SYS (4)"  maxlength="4"
            style={"#{inp()} max-width:120px; font-family:monospace;"} autocomplete="off" />
          <input name="bank_id" placeholder="BANK (4)" maxlength="4"
            style={"#{inp()} max-width:120px; font-family:monospace;"} autocomplete="off" />
          <button type="submit" style={btn_blue()}>Load</button>
        </form>
        <%= case @results do %>
          <% {:pcm03_record, r} -> %>
            <%= data_table(
                ["Fee", "Current Amount (#{r.description})"],
                [
                  ["Annual Fee",             to_string(r.annual_fee)],
                  ["Late Payment Fee",       to_string(r.late_fee)],
                  ["Overlimit Fee",          to_string(r.overlimit_fee)],
                  ["Replacement Fee",        to_string(r.replacement_fee)],
                  ["Returned Payment Fee",   to_string(r.returned_payment_fee)],
                  ["Card Replacement Fee",   to_string(r.card_replacement_fee)]
                ]
            ) %>
          <% {:pcm03_not_found, id} -> %>
            <%= hint("LOGO '#{id}' not found. Create it in ASM06 first.") %>
          <% _ -> %><% end %>
      </div>

      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem;">
        <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:1rem;">Update Fee Schedule</div>
        <form phx-submit="pcm03_save" style={form_style()}>
          <div style="display:grid; grid-template-columns:repeat(3,1fr); gap:0.75rem; margin-bottom:0.75rem;">
            <div style={form_row()}>
              <%= field_label("LOGO ID (4) *") %>
              <input name="logo_id" placeholder="LOG1" maxlength="4" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
            <div style={form_row()}>
              <%= field_label("SYS ID (4) *") %>
              <input name="sys_id"  placeholder="SYS1" maxlength="4" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
            <div style={form_row()}>
              <%= field_label("BANK ID (4) *") %>
              <input name="bank_id" placeholder="BNK1" maxlength="4" required
                style={"#{inp()} font-family:monospace;"} />
            </div>
          </div>
          <div style="display:grid; grid-template-columns:repeat(auto-fill,minmax(160px,1fr)); gap:0.75rem;">
            <div style={form_row()}>
              <%= field_label("Annual Fee") %>
              <input name="annual_fee" placeholder="0.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Late Payment Fee") %>
              <input name="late_fee" placeholder="100.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Overlimit Fee") %>
              <input name="overlimit_fee" placeholder="50.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Replacement Fee") %>
              <input name="replacement_fee" placeholder="50.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Returned Payment Fee") %>
              <input name="returned_payment_fee" placeholder="100.00" style={inp()} />
            </div>
            <div style={form_row()}>
              <%= field_label("Card Replacement Fee") %>
              <input name="card_replacement_fee" placeholder="50.00" style={inp()} />
            </div>
          </div>
          <button type="submit" style={"#{btn_green()} margin-top:0.5rem;"}>💾 Update Fee Schedule</button>
        </form>
      </div>
      <%= render_action_result(assigns) %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # MBS01 — Merchant Management
  # ---------------------------------------------------------------------------

  defp render_mbs01(assigns) do
    ~H"""
    <%= screen_header("MBS01", "Merchant Management", "Merchant hierarchy, MDR tier, scheme fee assignment", assigns) %>
    <div style="max-width:700px;">
      <form phx-submit="mbs_merchant_lookup" style="display:flex; gap:0.5rem; margin-bottom:1rem;">
        <input name="q" placeholder="Merchant name or ID" style="#{inp()} flex:1;" autocomplete="off" />
        <button type="submit" style={btn_blue()}>Search</button>
      </form>
      <%= case @results do %>
        <% {:mbs_merchants, []} -> %>
          <%= empty_state("No merchants found") %>
        <% {:mbs_merchants, rows} -> %>
          <%= data_table(
              ["Merchant ID", "Name", "MCC", "MDR Rate", "Status"],
              Enum.map(rows, fn r -> [r.merchant_id, r.merchant_name, r.mcc, r.mdr_rate, r.status] end)
          ) %>
        <% _ -> %>
          <%= hint("Search by merchant name or ID. MDR rates are resolved via ParameterEngine by MCC and merchant tier.") %>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # MBS02 — Terminal Management
  # ---------------------------------------------------------------------------

  defp render_mbs02(assigns) do
    ~H"""
    <%= screen_header("MBS02", "Terminal Management", "POS terminal registration and operational status", assigns) %>
    <%= hint("Terminals are registered in mbs_terminals and linked to their parent merchant via merchant_id. Each terminal has an independent status (ACTIVE / INACTIVE / TAMPERED).") %>
    <div style="margin-top:1rem; background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem; font-size:0.82rem; color:#8b949e;">
      Terminal schema: <code>id · terminal_id · merchant_id · terminal_type · status · last_heartbeat · firmware_version</code>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # MBS03 — MDR Configuration
  # ---------------------------------------------------------------------------

  defp render_mbs03(assigns) do
    ~H"""
    <%= screen_header("MBS03", "MDR Configuration", "Merchant discount rate and scheme fee lookup", assigns) %>
    <div style="max-width:700px;">
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem;">
        <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:0.75rem;">MDR Calculation</div>
        <div style="font-size:0.78rem; color:#8b949e; display:flex; flex-direction:column; gap:0.4rem;">
          <div><code style="color:#3fb950;">mdr_rate</code> = resolved from ParameterEngine (MCC → merchant tier → LOGO default)</div>
          <div><code style="color:#3fb950;">scheme_fee_rate</code> = Mastercard / Visa interchange schedule from ParameterEngine</div>
          <div><code style="color:#3fb950;">net_settlement</code> = gross_amount × (1 − mdr_rate) − scheme_fee</div>
          <div><code style="color:#3fb950;">issuer_interchange</code> = gross_amount × interchange_rate</div>
        </div>
        <div style="margin-top:1rem; font-size:0.78rem; color:#8b949e;">
          Implemented in <code>VmuCore.MBS.MdrEngine</code>. Rates stored in <code>cms_parameters</code>
          at LOGO level, overridable per merchant in <code>mbs_merchants.mdr_rate</code>.
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # LMS01 — Scheme Inquiry
  # ---------------------------------------------------------------------------

  defp render_lms01(assigns) do
    ~H"""
    <%= screen_header("LMS01", "Scheme Inquiry", "Loyalty scheme browser — groups, plans, rate tiers", assigns) %>
    <div style="display:flex; gap:0.5rem; margin-bottom:1rem;">
      <button phx-click="lms_schemes" style={btn_blue()}>Load Schemes</button>
    </div>
    <%= case @results do %>
      <% {:lms_schemes, []} -> %>
        <%= empty_state("No loyalty schemes configured") %>
      <% {:lms_schemes, rows} -> %>
        <%= data_table(
            ["Code", "Name", "Currency", "Warehouse Days", "Expiry (months)", "Status"],
            Enum.map(rows, fn r -> [r.scheme_code, r.scheme_name, r.currency, r.warehouse_days, r.expiry_months, r.status] end)
        ) %>
        <div style="margin-top:0.75rem; font-size:0.78rem; color:#8b949e;">
          Each scheme has Groups (Default / Bonus) → Plans (Base / Supplementary / Override) → Rate Tiers.
          Use LMS03 to view account balances.
        </div>
      <% _ -> %>
        <%= hint("Click 'Load Schemes' to browse configured loyalty schemes.") %>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # LMS02 — Account Enrollment
  # ---------------------------------------------------------------------------

  defp render_lms02(assigns) do
    ~H"""
    <%= screen_header("LMS02", "Account Enrollment", "Enroll CMS accounts to loyalty schemes", assigns) %>
    <div style="max-width:640px;">
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem; margin-bottom:1rem;">
        <div style="font-size:0.82rem; color:#8b949e;">
          Enrollment is automatically triggered by <code>VmuCore.LMS.Enrollment</code>
          when an account is approved in CDM (<code>on_conflict: :nothing</code> idempotency).
          Manual enrollment can be performed via <code>LMS.Enrollment.enroll/2</code>.
        </div>
      </div>
      <div style={form_style()}>
        <div style={form_row()}>
          <%= field_label("Account UUID") %>
          <input placeholder="Account UUID" style={inp()} autocomplete="off" />
        </div>
        <div style={form_row()}>
          <%= field_label("Scheme Code") %>
          <input placeholder="e.g. MILES_BASIC" style={inp()} />
        </div>
        <button style={btn_green()}>Enroll Account</button>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # LMS03 — Points Inquiry
  # ---------------------------------------------------------------------------

  defp render_lms03(assigns) do
    ~H"""
    <%= screen_header("LMS03", "Points Inquiry", "Points balance, ledger history, warehouse state and expiry", assigns) %>
    <div style="max-width:780px;">
      <form phx-submit="lms_points_inquiry" style="display:flex; gap:0.5rem; margin-bottom:1rem;">
        <input name="account_id" placeholder="Account UUID" style="#{inp()} flex:1;" autocomplete="off" />
        <button type="submit" style={btn_blue()}>Inquiry</button>
      </form>
      <%= case @results do %>
        <% {:lms_points, nil, _} -> %>
          <%= error_box("No LMS account found for this UUID") %>
        <% {:lms_points, acct, ledger} -> %>
          <div style="background:#161b22; border:1px solid #30363d; border-radius:8px;
                      padding:1.25rem; margin-bottom:1rem;
                      display:grid; grid-template-columns:1fr 1fr 1fr; gap:1rem; text-align:center;">
            <div>
              <div style="font-size:1.8rem; font-weight:700; color:#3fb950;">{acct.points_balance}</div>
              <div style="font-size:0.72rem; color:#8b949e; margin-top:0.2rem;">Points Balance</div>
            </div>
            <div>
              <div style="font-size:1.8rem; font-weight:700; color:#58a6ff;">{acct.open_to_redeem}</div>
              <div style="font-size:0.72rem; color:#8b949e; margin-top:0.2rem;">Open to Redeem</div>
            </div>
            <div>
              <div style="font-size:1.8rem; font-weight:700; color:#d29922;">{acct.lifetime_earned}</div>
              <div style="font-size:0.72rem; color:#8b949e; margin-top:0.2rem;">Lifetime Earned</div>
            </div>
          </div>
          <div style="font-size:0.78rem; color:#8b949e; margin-bottom:0.5rem;">
            Status: <span style={"color:#{if acct.status == "ACTIVE", do: "#3fb950", else: "#f85149"}"}>{acct.status}</span>
          </div>
          <%= if ledger != [] do %>
            <%= data_table(
                ["Date", "Type", "Points", "Warehouse State", "Reference"],
                Enum.map(ledger, fn l -> [l.posting_date, l.entry_type, l.points, l.warehouse_state, l.reference_id] end)
            ) %>
          <% else %>
            <%= empty_state("No ledger entries yet") %>
          <% end %>
        <% _ -> %>
          <%= hint("Enter the account UUID to view points balance and ledger history.") %>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # LMS04 — Redemption Processing
  # ---------------------------------------------------------------------------

  defp render_lms04(assigns) do
    ~H"""
    <%= screen_header("LMS04", "Redemption Processing", "Manual redemption, FIFO history, merchant settlement", assigns) %>
    <div style="max-width:700px;">
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem; margin-bottom:1rem;">
        <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:0.5rem;">Redemption Rules</div>
        <div style="font-size:0.78rem; color:#8b949e; display:flex; flex-direction:column; gap:0.3rem;">
          <div>• Only points in <code>ACTIVE</code> warehouse state (open_to_redeem &gt; 0) can be redeemed</div>
          <div>• FIFO order — oldest earned points consumed first</div>
          <div>• BLOCKED accounts cannot redeem</div>
          <div>• GL: DR 7003 lms_redemption_liability / CR 7004 lms_points_redeemed</div>
          <div>• Auto-disbursement: when open_to_redeem ≥ packet_threshold (configured per scheme)</div>
        </div>
      </div>
      <div style={form_style()}>
        <div style={form_row()}>
          <%= field_label("Account UUID") %>
          <input placeholder="Account UUID" style={inp()} autocomplete="off" />
        </div>
        <div style={form_row()}>
          <%= field_label("Points to Redeem") %>
          <input placeholder="e.g. 500" style={inp()} />
        </div>
        <div style={form_row()}>
          <%= field_label("Redemption Type") %>
          <select style={inp()}>
            <option>CASH_BACK</option>
            <option>STATEMENT_CREDIT</option>
            <option>MERCHANDISE</option>
            <option>AIR_MILES</option>
          </select>
        </div>
        <button style={btn_green()}>Process Redemption</button>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # HCS01 — Company Management
  # ---------------------------------------------------------------------------

  defp render_hcs01(assigns) do
    ~H"""
    <%= screen_header("HCS01", "Company Management", "Corporate company record, credit pool, liability model", assigns) %>
    <div style="max-width:700px;">
      <form phx-submit="hcs_company_lookup" style="display:flex; gap:0.5rem; margin-bottom:1rem;">
        <input name="company_id" placeholder="Company ID" style="#{inp()} flex:1;" autocomplete="off" />
        <button type="submit" style={btn_blue()}>Look Up</button>
      </form>
      <%= case @results do %>
        <% {:hcs_company, nil} -> %>
          <%= error_box("Company not found") %>
        <% {:hcs_company, c} -> %>
          <div style="background:#161b22; border:1px solid #30363d; border-radius:8px;
                      padding:1.25rem; display:grid; grid-template-columns:1fr 1fr; gap:0.5rem 2rem;">
            <%= kv("Company ID",        c.company_id) %>
            <%= kv("Company Name",      c.company_name) %>
            <%= kv("Credit Pool (AED)", c.credit_pool) %>
            <%= kv("Available (AED)",   c.available_limit) %>
            <%= kv("Liability Model",   c.liability_model) %>
            <%= kv("Status",            c.status) %>
          </div>
          <div style="margin-top:0.75rem; font-size:0.78rem; color:#8b949e;">
            <strong style="color:#c9d1d9;">Liability Model:</strong>
            CENTRAL = company settles all balances (nightly sweep at 22:00) ·
            INDIVIDUAL = each employee settles their own balance.
          </div>
        <% _ -> %>
          <%= hint("Enter a Company ID to view the corporate account record.") %>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # HCS02 — Employee Cards
  # ---------------------------------------------------------------------------

  defp render_hcs02(assigns) do
    ~H"""
    <%= screen_header("HCS02", "Employee Cards", "Employee card list, individual sub-limits, cost centres", assigns) %>
    <div style="max-width:780px;">
      <form phx-submit="hcs_employee_list" style="display:flex; gap:0.5rem; margin-bottom:1rem;">
        <input name="company_id" placeholder="Company ID" style="#{inp()} flex:1;" autocomplete="off" />
        <button type="submit" style={btn_blue()}>Load Cards</button>
      </form>
      <%= case @results do %>
        <% {:hcs_employees, []} -> %>
          <%= empty_state("No employee cards found for this company") %>
        <% {:hcs_employees, rows} -> %>
          <%= data_table(
              ["Employee", "Account", "Sub-Limit (AED)", "Available (AED)", "Cost Centre", "Status"],
              Enum.map(rows, fn r -> [r.employee_name, r.account_id, r.individual_limit, r.available_individual, r.cost_centre, r.status] end)
          ) %>
        <% _ -> %>
          <%= hint("Enter a Company ID to list employee cards with their individual sub-limits.") %>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # HCS03 — Spending Controls
  # ---------------------------------------------------------------------------

  defp render_hcs03(assigns) do
    ~H"""
    <%= screen_header("HCS03", "Spending Controls", "MCC block/allow, channel block, per-txn and daily caps", assigns) %>
    <div style="max-width:700px;">
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1.25rem; margin-bottom:1rem;">
        <div style="font-size:0.82rem; color:#c9d1d9; font-weight:600; margin-bottom:0.75rem;">Control Types</div>
        <%= data_table(
            ["Control Type", "Scope", "Example", "Evaluation"],
            [
              ["MCC_BLOCK",     "Company or Employee", "Block MCC 7995 (gambling)",       "Immediate decline RC=57"],
              ["MCC_ALLOW",     "Company or Employee", "Whitelist MCCs 5411,5812 only",    "All other MCCs blocked"],
              ["CHANNEL_BLOCK", "Employee",            "Block ATM withdrawals",             "Decline if channel=atm"],
              ["TXN_CAP",       "Employee",            "Max AED 500 per transaction",       "Decline if amount > cap"],
              ["DAILY_CAP",     "Employee",            "Max AED 2000 per day",              "Decline if daily_spend > cap"]
            ]
        ) %>
      </div>
      <div style="background:#161b22; border:1px solid #30363d; border-radius:8px; padding:1rem; font-size:0.78rem; color:#8b949e;">
        Controls are evaluated in <code>HCS.LimitController.check_hcs_limits/4</code>,
        called from <code>CMS.AccountStateCoordinator.do_authorize/4</code>
        after the standard OTB check.
        Company-level controls apply to all employee cards; employee-level controls are per-card.
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # ITS01 — Copy Requests
  # ---------------------------------------------------------------------------

  defp render_its01(assigns) do
    ~H"""
    <%= screen_header("ITS01", "Copy Requests", "Network copy and retrieval request lifecycle", assigns) %>
    <form phx-submit="its_copy_requests" style="display:flex; gap:0.5rem; margin-bottom:1rem;">
      <select name="status" style={inp()}>
        <option value="">All Statuses</option>
        <option value="PENDING">Pending</option>
        <option value="SENT">Sent (ITS1)</option>
        <option value="FULFILLED">Fulfilled</option>
        <option value="DECLINED">Declined</option>
        <option value="EXPIRED">Expired</option>
      </select>
      <button type="submit" style={btn_blue()}>Load</button>
    </form>
    <%= case @results do %>
      <% {:its_copy_requests, []} -> %>
        <%= empty_state("No copy requests found") %>
      <% {:its_copy_requests, rows} -> %>
        <%= data_table(
            ["ID", "Account", "Type", "Status", "Network", "SLA Deadline", "Raised"],
            Enum.map(rows, fn r -> [r.id, r.account_id, r.request_type, r.status, r.network, r.sla_deadline, r.inserted_at] end)
        ) %>
      <% _ -> %>
        <%= hint("Copy requests are raised by ITS.CopyRequestManager when DPS files a dispute. ITS1 batch (21:00) submits PENDING requests to the network.") %>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # ITS02 — Fee Claims
  # ---------------------------------------------------------------------------

  defp render_its02(assigns) do
    ~H"""
    <%= screen_header("ITS02", "Fee Claims", "Interchange income/expense per clearing record", assigns) %>
    <form phx-submit="its_fee_claims" style="display:flex; gap:0.5rem; margin-bottom:1rem; flex-wrap:wrap;">
      <input name="from" placeholder="From (YYYY-MM-DD)" style="#{inp()} width:170px;" />
      <input name="to"   placeholder="To   (YYYY-MM-DD)" style="#{inp()} width:170px;" />
      <button type="submit" style={btn_blue()}>Browse</button>
    </form>
    <%= case @results do %>
      <% {:its_fee_claims, []} -> %>
        <%= empty_state("No fee claims found") %>
      <% {:its_fee_claims, rows} -> %>
        <%= data_table(
            ["Network", "Interchange (AED)", "Scheme Fee (AED)", "Net (AED)", "Settlement Date"],
            Enum.map(rows, fn r -> [r.network, r.interchange_amount, r.scheme_fee, r.net_amount, r.settlement_date] end)
        ) %>
      <% _ -> %>
        <%= hint("Fee claims are created by ITS.FeeClaimProcessor after each clearing record is processed by TRAMS.") %>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # ITS03 — Financial Adjustments
  # ---------------------------------------------------------------------------

  defp render_its03(assigns) do
    ~H"""
    <%= screen_header("ITS03", "Financial Adjustments", "FAR (Financial Adjustment Records) from Visa / Mastercard", assigns) %>
    <form phx-submit="its_far_list" style="display:flex; gap:0.5rem; margin-bottom:1rem;">
      <select name="status" style={inp()}>
        <option value="">All Statuses</option>
        <option value="PENDING">Pending</option>
        <option value="AUTO_ACCEPTED">Auto-Accepted (&lt; AED 1000)</option>
        <option value="ACCEPTED">Accepted</option>
        <option value="DISPUTED">Disputed</option>
      </select>
      <button type="submit" style={btn_blue()}>Load FARs</button>
    </form>
    <%= case @results do %>
      <% {:its_far_list, []} -> %>
        <%= empty_state("No financial adjustment records found") %>
      <% {:its_far_list, rows} -> %>
        <%= data_table(
            ["Network", "FAR Type", "Amount (AED)", "Status", "Received", "Processed"],
            Enum.map(rows, fn r -> [r.network, r.far_type, r.amount, r.status, r.received_at, r.processed_at] end)
        ) %>
      <% _ -> %>
        <%= hint("FARs are received from schemes via ITS2 batch (02:00). FARs ≤ AED 1000 are auto-accepted and posted to GL.") %>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # Shared component helpers
  # ---------------------------------------------------------------------------

  defp screen_header(code, title, desc, assigns) do
    assigns = assign(assigns, sc_code: code, sc_title: title, sc_desc: desc)

    ~H"""
    <div style="margin-bottom:1.5rem; padding-bottom:1rem; border-bottom:1px solid #21262d;">
      <div style="display:flex; align-items:baseline; gap:0.75rem; margin-bottom:0.4rem;">
        <span style="background:#1f6feb; color:white; padding:0.2rem 0.6rem;
                     border-radius:4px; font-size:0.75rem; font-weight:700; flex-shrink:0;">
          {@sc_code}
        </span>
        <h1 style="font-size:1.1rem; font-weight:700; color:#e6edf3;">{@sc_title}</h1>
      </div>
      <p style="color:#8b949e; font-size:0.8rem;">{@sc_desc}</p>
    </div>
    """
  end

  defp render_action_result(%{action_result: nil} = assigns) do
    assigns = assign(assigns, :_unused, nil)
    ~H"<div />"
  end

  defp render_action_result(%{action_result: :ok} = assigns) do
    ~H"""
    <div style="margin-top:1rem; padding:0.75rem 1rem; background:#0f2419; border:1px solid #3fb950;
                border-radius:6px; color:#3fb950; font-size:0.85rem;">✅ Action completed successfully</div>
    """
  end

  defp render_action_result(%{action_result: {:ok, msg}} = assigns) do
    assigns = assign(assigns, msg: msg)
    ~H"""
    <div style="margin-top:1rem; padding:0.75rem 1rem; background:#0f2419; border:1px solid #3fb950;
                border-radius:6px; color:#3fb950; font-size:0.85rem;">✅ {@msg}</div>
    """
  end

  defp render_action_result(%{action_result: {:error, reason}} = assigns) do
    assigns = assign(assigns, reason: inspect(reason))
    ~H"""
    <div style="margin-top:1rem; padding:0.75rem 1rem; background:#1c0a0a; border:1px solid #f85149;
                border-radius:6px; color:#f85149; font-size:0.85rem;">❌ {@reason}</div>
    """
  end

  defp render_action_result(assigns) do
    ~H"<div />"
  end

  # ---------------------------------------------------------------------------
  # HTML component helpers (non-HEEx — used inside ~H blocks)
  # ---------------------------------------------------------------------------

  defp data_table(headers, rows) do
    Phoenix.HTML.raw("""
    <div style="overflow-x:auto; margin-top:0.5rem;">
      <table style="width:100%; border-collapse:collapse; font-size:0.8rem;">
        <thead>
          <tr style="background:#161b22; border-bottom:1px solid #30363d;">
            #{Enum.map_join(headers, "", fn h -> "<th style='padding:0.5rem 0.75rem; text-align:left; color:#8b949e; font-weight:600; white-space:nowrap;'>#{h}</th>" end)}
          </tr>
        </thead>
        <tbody>
          #{Enum.map_join(rows, "", fn row ->
            "<tr style='border-bottom:1px solid #21262d;'>" <>
            Enum.map_join(row, "", fn cell ->
              "<td style='padding:0.45rem 0.75rem; color:#c9d1d9; white-space:nowrap; max-width:280px; overflow:hidden; text-overflow:ellipsis;'>#{cell}</td>"
            end) <>
            "</tr>"
          end)}
        </tbody>
      </table>
    </div>
    """)
  end

  defp empty_state(msg) do
    Phoenix.HTML.raw("""
    <div style="padding:2rem; text-align:center; color:#6e7681; font-size:0.82rem;
                background:#161b22; border:1px dashed #30363d; border-radius:8px; margin-top:0.5rem;">
      #{msg}
    </div>
    """)
  end

  defp error_box(msg) do
    Phoenix.HTML.raw("""
    <div style="padding:0.75rem 1rem; background:#1c0a0a; border:1px solid #f85149;
                border-radius:6px; color:#f85149; font-size:0.85rem; margin-top:0.5rem;">❌ #{msg}</div>
    """)
  end

  defp hint(msg) do
    Phoenix.HTML.raw("""
    <div style="padding:0.75rem 1rem; background:#161b22; border-radius:6px;
                color:#8b949e; font-size:0.8rem; margin-top:0.5rem;">ℹ #{msg}</div>
    """)
  end

  defp kv(label, value) do
    Phoenix.HTML.raw("""
    <div style="padding:0.3rem 0;">
      <div style="font-size:0.68rem; color:#6e7681; text-transform:uppercase; letter-spacing:0.06em;">#{label}</div>
      <div style="color:#e6edf3; font-size:0.83rem; margin-top:0.15rem;">#{value}</div>
    </div>
    """)
  end

  # Balance bucket key-value — shows decimal value right-aligned in green
  defp bucket_kv(label, value) do
    val_str = case value do
      nil -> "0.00"
      v when is_struct(v, Decimal) -> Decimal.to_string(v)
      v -> to_string(v)
    end
    Phoenix.HTML.raw("""
    <div style="padding:0.3rem 0.5rem; background:#0d1117; border-radius:5px; border:1px solid #21262d;">
      <div style="font-size:0.65rem; color:#6e7681; text-transform:uppercase; letter-spacing:0.06em; margin-bottom:0.15rem;">#{label}</div>
      <div style="color:#3fb950; font-size:0.85rem; font-variant-numeric:tabular-nums; text-align:right;">#{val_str}</div>
    </div>
    """)
  end

  defp field_label(text) do
    Phoenix.HTML.raw("""
    <label style="font-size:0.75rem; color:#8b949e; display:block; margin-bottom:0.3rem;">#{text}</label>
    """)
  end

  # ---------------------------------------------------------------------------
  # Style constants
  # ---------------------------------------------------------------------------

  defp form_style, do: "display:flex; flex-direction:column; gap:0.85rem; max-width:560px;"
  defp form_row,   do: "display:flex; flex-direction:column; gap:0.25rem;"
  defp kv_row,     do: "display:flex; gap:1rem; align-items:baseline; padding:0.2rem 0;"
  defp kl,         do: "color:#8b949e; font-size:0.8rem; min-width:130px; flex-shrink:0;"

  defp inp do
    "background:#0d1117; border:1px solid #30363d; border-radius:5px; color:#e6edf3; " <>
    "padding:0.45rem 0.7rem; font-family:inherit; font-size:0.82rem; width:100%; outline:none;"
  end

  defp btn_blue do
    "background:#1f6feb; color:white; border:none; border-radius:5px; padding:0.5rem 1.1rem; " <>
    "cursor:pointer; font-family:inherit; font-size:0.82rem; font-weight:600; white-space:nowrap; flex-shrink:0;"
  end

  defp btn_green do
    "background:#238636; color:white; border:none; border-radius:5px; padding:0.5rem 1.1rem; " <>
    "cursor:pointer; font-family:inherit; font-size:0.82rem; font-weight:600; white-space:nowrap;"
  end

  defp btn_amber do
    "background:#9e6a03; color:white; border:none; border-radius:5px; padding:0.5rem 1.1rem; " <>
    "cursor:pointer; font-family:inherit; font-size:0.82rem; font-weight:600; white-space:nowrap;"
  end

  defp btn_secondary do
    "background:#21262d; color:#c9d1d9; border:1px solid #30363d; border-radius:5px; " <>
    "padding:0.5rem 1rem; cursor:pointer; font-family:inherit; font-size:0.82rem; white-space:nowrap; flex-shrink:0;"
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp parse_json(nil), do: nil
  defp parse_json(""), do: nil
  defp parse_json(str) do
    case Jason.decode(str) do
      {:ok, map} -> map
      _          -> nil
    end
  end

  defp parse_csv_list(nil), do: []
  defp parse_csv_list(""), do: []
  defp parse_csv_list(str) do
    str |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp decimal_or_nil(nil), do: nil
  defp decimal_or_nil(""), do: nil
  defp decimal_or_nil(str) do
    try do
      Decimal.new(str)
    rescue
      _ -> nil
    end
  end

  defp int_or_nil(nil), do: nil
  defp int_or_nil(""), do: nil
  defp int_or_nil(str) do
    case Integer.parse(str) do
      {i, _} -> i
      :error  -> nil
    end
  end

  defp changeset_errors(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
    |> Enum.join("; ")
  end

  defp open_group_for(socket, screen_code) do
    group =
      @sidebar_groups
      |> Enum.find(fn {_, _, _, _, screens} -> screen_code in screens end)
      |> case do
        {key, _, _, _, _} -> key
        nil -> nil
      end

    if group do
      assign(socket, sidebar_open: Map.put(socket.assigns.sidebar_open, group, true))
    else
      socket
    end
  end

  # Safe wrappers for Repo queries that may fail in dev (table not yet migrated)
  defp safe_query(queryable, default) do
    Repo.all(queryable)
  rescue
    _ -> default
  end

  defp safe_one(value), do: value

  @screens @screens
  defp screens, do: @screens

  # ===========================================================================
  # CONSOLE MODE — Render
  # ===========================================================================

  defp render_console(assigns) do
    ~H"""
    <div style="display:flex; flex-direction:column; height:calc(100vh - 52px);
                background:#0d1117; font-family:'JetBrains Mono','Fira Code','Courier New',monospace;">
      <%!-- Console sub-header: module badge + CMD/MENU tabs --%>
      <div style="display:flex; align-items:center; gap:1rem; padding:0.55rem 1.25rem;
                  background:#161b22; border-bottom:1px solid #30363d; flex-shrink:0;">
        <% cmod    = console_module_for(@screen) %>
        <% cmod_up = if cmod, do: cmod |> to_string() |> String.upcase(), else: "SYSTEM" %>
        <div style="display:flex; align-items:center; gap:0.6rem;">
          <span style="background:linear-gradient(135deg,#00c875,#0075ff); color:#000; font-weight:800;
                       font-size:0.72rem; padding:0.18rem 0.55rem; border-radius:3px; letter-spacing:0.06em;">
            {cmod_up}
          </span>
          <span style="color:#3fb950; font-weight:700; font-size:0.82rem; letter-spacing:0.02em;">Console</span>
        </div>
        <span style="color:#6e7681; font-size:0.7rem;">{node()}</span>
        <span style="color:#6e7681; font-size:0.68rem; background:#21262d;
                     padding:0.1rem 0.4rem; border-radius:3px; border:1px solid #30363d;">AGENT</span>
      </div>

      <%!-- Output area — phx-hook auto-scrolls to bottom on update --%>
      <div id="console-output" phx-hook="ScrollBottom"
        style="flex:1; overflow-y:auto; padding:0.75rem 1.5rem 0.25rem; line-height:1.75; font-size:0.81rem;">
        <%= for {entry, idx} <- Enum.with_index(@console_history) do %>
          <div id={"ce-#{idx}"}>
            <%= case entry do %>
              <% %{type: :info, text: t} -> %>
                <div style="color:#6e7681;">{t}</div>
              <% %{type: :info_block, lines: lines} -> %>
                <%= for {ln, li} <- Enum.with_index(lines) do %>
                  <div id={"ce-#{idx}-#{li}"} style="color:#8b949e;">{ln}</div>
                <% end %>
              <% %{type: :cmd, module: mod, text: t} -> %>
                <div style="margin-top:0.6rem; color:#e6edf3;">
                  <span style="color:#1f6feb; user-select:none;">
                    vmu[<%= if mod, do: to_string(mod), else: "sys" %>]&gt;
                  </span>
                  &nbsp;<strong>{t}</strong>
                </div>
              <% %{type: :ok, lines: lines} -> %>
                <%= for {ln, li} <- Enum.with_index(lines) do %>
                  <div id={"ce-#{idx}-#{li}"}
                    style={"#{if String.starts_with?(ln, "#"), do: "color:#6e7681;", else: "color:#3fb950;"} padding-left:1.5rem;"}>
                    {ln}
                  </div>
                <% end %>
              <% %{type: :error, text: t} -> %>
                <div style="color:#f85149; padding-left:1.5rem;">✗ &nbsp;{t}</div>
              <% _ -> %>
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- Command input bar --%>
      <div style="border-top:1px solid #30363d; padding:0.55rem 1.5rem 0.45rem;
                  flex-shrink:0; background:#0d1117;">
        <% cmod2 = console_module_for(@screen) %>
        <form phx-submit="console_cmd" style="display:flex; align-items:center; gap:0.5rem;">
          <span style="color:#1f6feb; user-select:none; flex-shrink:0; font-size:0.82rem;">
            vmu[<%= if cmod2, do: to_string(cmod2), else: "sys" %>]&gt;
          </span>
          <input name="cmd" value={@console_input}
            autocomplete="off" spellcheck="false" autofocus
            phx-keyup="console_input_change" phx-value-value=""
            style="flex:1; background:transparent; border:none; outline:none;
                   color:#e6edf3; font-size:0.82rem; caret-color:#3fb950; font-family:inherit;" />
        </form>
        <%!-- Quick command chips --%>
        <div style="display:flex; gap:0.35rem; margin-top:0.4rem; flex-wrap:wrap; align-items:center;">
          <span style="color:#6e7681; font-size:0.67rem; flex-shrink:0;">Quick:</span>
          <%= for qcmd <- console_quick_cmds(console_module_for(@screen)) do %>
            <button phx-click="console_quick" phx-value-cmd={qcmd}
              style="background:#161b22; border:1px solid #30363d; color:#8b949e;
                     padding:0.12rem 0.5rem; border-radius:3px; font-size:0.67rem;
                     cursor:pointer; font-family:inherit; white-space:nowrap;">
              {qcmd}
            </button>
          <% end %>
          <span style="color:#6e7681; font-size:0.67rem; margin-left:0.25rem;">· type help for full list</span>
        </div>
      </div>
    </div>
    """
  end

  # ===========================================================================
  # CONSOLE — Module helpers
  # ===========================================================================

  defp console_module_for(screen) when is_binary(screen) do
    case Map.get(@screens, screen) do
      %{group: g} -> g
      _           -> :sys
    end
  end
  defp console_module_for(_), do: :sys

  defp console_quick_cmds(:fas),   do: ["help", "auth <pan> <amount>", "history <account_id>", "status"]
  defp console_quick_cmds(:cms),   do: ["help", "list", "account <uuid>", "search <term>", "gl <account_id>"]
  defp console_quick_cmds(:cif),   do: ["help", "search <term>", "list", "kyc <customer_id>"]
  defp console_quick_cmds(:cta),   do: ["help", "stock", "orders", "card <card_id>"]
  defp console_quick_cmds(:ivr),   do: ["help", "sessions", "otp <account_id>", "status"]
  defp console_quick_cmds(:dps),   do: ["help", "list open", "list resolved", "view <id>", "chargebacks"]
  defp console_quick_cmds(:trams), do: ["help", "clearing", "status", "search <pan_token>"]
  defp console_quick_cmds(:col),   do: ["help", "cases open", "cases all", "writeoffs"]
  defp console_quick_cmds(:cdm),   do: ["help", "queue", "decisions"]
  defp console_quick_cmds(:asm),   do: ["help", "operators", "params", "audit"]
  defp console_quick_cmds(:mbs),   do: ["help", "merchants", "terminals <merchant_id>", "mdr <merchant_id>"]
  defp console_quick_cmds(:lms),   do: ["help", "schemes", "points <account_id>", "enrollments <account_id>"]
  defp console_quick_cmds(:hcs),   do: ["help", "companies", "employees <company_id>", "controls <company_id>"]
  defp console_quick_cmds(:its),   do: ["help", "copies", "fees", "adjustments"]
  defp console_quick_cmds(_),      do: ["help"]

  # ===========================================================================
  # CONSOLE — Help text (per module)
  # ===========================================================================

  defp console_help(:fas) do
    ["Commands available for FAS (Authorization):", "",
     "  help                               — this message",
     "  auth <pan_token> <amount>          — live authorization test    [agent+]",
     "  auth <pan_token> <amount> <mcc> <channel>",
     "                                       channel: pos | ecom | atm | ivr",
     "  history <account_id>               — last 30 auth records       [agent+]",
     "  status                             — FAS engine status"]
  end

  defp console_help(:cms) do
    ["Commands available for CMS (Card Management):", "",
     "  help                               — this message",
     "  list [limit]                       — recent accounts (default 10) [agent+]",
     "  account <uuid>                     — account summary               [agent+]",
     "  search <term>                      — search by status/account      [agent+]",
     "  gl <account_id>                    — GL ledger (last 20)           [supervisor+]",
     "  statement <account_id>             — cycle statements              [agent+]"]
  end

  defp console_help(:cif) do
    ["Commands available for CIF (Customer Information):", "",
     "  help                               — this message",
     "  list                               — 20 most-recent customers      [agent+]",
     "  search <term>                      — search by name / ID / NID     [agent+]",
     "  kyc <customer_id>                  — KYC tier and verification     [agent+]"]
  end

  defp console_help(:cta) do
    ["Commands available for CTA (Card Administration):", "",
     "  help                               — this message",
     "  stock                              — card stock levels by BIN       [supervisor+]",
     "  orders                             — embossing queue (last 20)      [agent+]",
     "  card <card_id>                     — card detail and status         [agent+]"]
  end

  defp console_help(:ivr) do
    ["Commands available for IVR (Telephony):", "",
     "  help                               — this message",
     "  sessions                           — live IVR session list          [supervisor+]",
     "  otp <account_id>                   — OTP seed info for account      [supervisor+]",
     "  status                             — IVR channel status             [agent+]"]
  end

  defp console_help(:dps) do
    ["Commands available for DPS (Disputes):", "",
     "  help                               — this message",
     "  list [open|resolved|all]           — dispute queue (default: open)  [agent+]",
     "  view <dispute_id>                  — dispute detail                 [agent+]",
     "  chargebacks                        — chargeback tracker             [supervisor+]"]
  end

  defp console_help(:trams) do
    ["Commands available for TRAMS (Clearing):", "",
     "  help                               — this message",
     "  clearing [date]                    — clearing records (YYYY-MM-DD)  [supervisor+]",
     "  status                             — IPM pipeline throughput        [supervisor+]",
     "  search <pan_token>                 — find clearing by PAN token     [agent+]"]
  end

  defp console_help(:col) do
    ["Commands available for COL (Collections):", "",
     "  help                               — this message",
     "  cases [open|all|promised]          — collection queue               [agent+]",
     "  writeoffs                          — write-off register             [supervisor+]"]
  end

  defp console_help(:cdm) do
    ["Commands available for CDM (Credit):", "",
     "  help                               — this message",
     "  queue                              — pending application queue      [supervisor+]",
     "  decisions                          — recent underwriting decisions  [supervisor+]"]
  end

  defp console_help(:asm) do
    ["Commands available for ASM (System Admin):", "",
     "  help                               — this message",
     "  operators                          — operator list                  [manager+]",
     "  params                             — all system parameters          [sysadmin]",
     "  param <key>                        — specific parameter value       [sysadmin]",
     "  audit [operator]                   — operator audit trail           [manager+]"]
  end

  defp console_help(:mbs) do
    ["Commands available for MBS (Merchant):", "",
     "  help                               — this message",
     "  merchants [limit]                  — merchant list (default 10)     [agent+]",
     "  terminals <merchant_id>            — POS terminals for merchant     [agent+]",
     "  mdr <merchant_id>                  — MDR and fee configuration      [supervisor+]"]
  end

  defp console_help(:lms) do
    ["Commands available for LMS (Loyalty):", "",
     "  help                               — this message",
     "  schemes                            — loyalty scheme list            [agent+]",
     "  points <account_id>                — points balance and ledger      [agent+]",
     "  enrollments <account_id>           — scheme enrollments             [agent+]"]
  end

  defp console_help(:hcs) do
    ["Commands available for HCS (Corporate):", "",
     "  help                               — this message",
     "  companies                          — corporate company list         [agent+]",
     "  employees <company_id>             — employee cards for company     [agent+]",
     "  controls <company_id>              — spending controls              [supervisor+]"]
  end

  defp console_help(:its) do
    ["Commands available for ITS (Interchange):", "",
     "  help                               — this message",
     "  copies [status]                    — copy/retrieval requests        [supervisor+]",
     "  fees [date]                        — fee claims by date             [supervisor+]",
     "  adjustments                        — financial adjustment records   [supervisor+]"]
  end

  defp console_help(_) do
    ["Commands:", "", "  help     — this message",
     "", "Navigate to a module screen first (e.g. CMS01, FAS01) for module-specific commands."]
  end

  # ===========================================================================
  # CONSOLE — Command dispatch entry point
  # ===========================================================================

  defp execute_console_cmd(module, cmd_str, socket) do
    parts = String.split(String.trim(cmd_str), ~r/\s+/, trim: true)
    case parts do
      ["help"]       -> {:info,  console_help(module)}
      ["status"]     -> console_cmd_status()
      [cmd | args]   -> dispatch_console(module, String.downcase(cmd), args, socket)
    end
  end

  # ─── FAS ──────────────────────────────────────────────────────────────────

  defp dispatch_console(:fas, "auth", [pan, amt | rest], _socket) do
    mcc     = Enum.at(rest, 0, "5411")
    channel = Enum.at(rest, 1, "pos")
    result =
      try do
        VmuCore.FAS.Authorization.process(%{
          pan:     pan,
          amount:  Decimal.new(amt),
          channel: String.to_existing_atom(channel),
          mcc:     mcc
        })
      rescue
        e -> {:error_raw, Exception.message(e)}
      end
    case result do
      {:ok,       rc, code}  -> {:ok, ["✅ APPROVED",
                                       "   Response code : #{rc}",
                                       "   Approval code : #{code}",
                                       "   Amount        : #{amt}",
                                       "   MCC / Channel : #{mcc} / #{channel}"]}
      {:error,    rc}        -> {:ok, ["❌ DECLINED", "   Response code : #{rc}"]}
      {:error_raw, msg}      -> {:error, msg}
    end
  end

  defp dispatch_console(:fas, "auth", _, _socket),
    do: {:error, "Usage: auth <pan_token> <amount> [mcc] [channel]"}

  defp dispatch_console(:fas, "history", [account_id | _], _socket) do
    rows = safe_query(
      from(e in "fas_auth_log",
        where: e.account_id == ^account_id,
        order_by: [desc: e.inserted_at], limit: 30,
        select: %{ts: e.inserted_at, rc: e.response_code, amount: e.amount}),
      [])
    if rows == [] do
      {:ok, ["(no auth records for account #{account_id})"]}
    else
      {:ok, ["#{length(rows)} authorizations:" |
             Enum.map(rows, fn r -> "  #{r.ts}  rc=#{r.rc}  #{r.amount}" end)]}
    end
  end

  defp dispatch_console(:fas, "history", _, _socket),
    do: {:error, "Usage: history <account_id>"}

  # ─── CMS ──────────────────────────────────────────────────────────────────

  defp dispatch_console(:cms, "list", args, _socket) do
    limit = args |> Enum.at(0, "10") |> Integer.parse() |> then(fn {n, _} -> min(n, 50) end)
    rows  = safe_query(
      from(a in Account, order_by: [desc: a.inserted_at], limit: ^limit,
        select: %{id: a.id, status: a.status, credit_limit: a.credit_limit, otb: a.outstanding_balance}),
      [])
    if rows == [] do
      {:ok, ["(no accounts — schema may not be migrated yet)"]}
    else
      {:ok, ["#{length(rows)} account(s):",
             "  UUID                                  STATUS    LIMIT        OTB" |
             Enum.map(rows, fn a ->
               "  #{a.id}  #{String.pad_trailing(to_string(a.status), 8)}  " <>
               "limit=#{a.credit_limit}  otb=#{a.otb}"
             end)]}
    end
  end

  defp dispatch_console(:cms, "account", [uuid | _], _socket) do
    case safe_query(from(a in Account, where: a.id == ^uuid, limit: 1, select: a), []) do
      [a] ->
        avail = Decimal.sub(a.credit_limit, a.outstanding_balance)
        {:ok, ["Account: #{a.id}",
               "  Status        : #{a.status}",
               "  Credit Limit  : #{a.credit_limit}",
               "  Outstanding   : #{a.outstanding_balance}",
               "  Available OTB : #{avail}",
               "  Created       : #{a.inserted_at}"]}
      [] -> {:error, "Account not found: #{uuid}"}
    end
  end

  defp dispatch_console(:cms, "account", _, _socket),
    do: {:error, "Usage: account <uuid>"}

  defp dispatch_console(:cms, "search", [term | _], _socket) do
    like = "%#{term}%"
    rows = safe_query(
      from(a in Account,
        where: ilike(fragment("cast(? as text)", a.id), ^like) or
               ilike(fragment("cast(? as text)", a.status), ^like),
        limit: 20,
        select: %{id: a.id, status: a.status, credit_limit: a.credit_limit}),
      [])
    if rows == [] do
      {:ok, ["No accounts matching '#{term}'"]}
    else
      {:ok, ["#{length(rows)} match(es) for '#{term}':" |
             Enum.map(rows, fn a -> "  #{a.id}  #{a.status}  limit=#{a.credit_limit}" end)]}
    end
  end

  defp dispatch_console(:cms, "search", _, _socket),
    do: {:error, "Usage: search <term>"}

  defp dispatch_console(:cms, "gl", [account_id | _], _socket) do
    rows = safe_query(
      from(e in "gl_ledger",
        where: e.account_id == ^account_id,
        order_by: [desc: e.posted_at], limit: 20,
        select: %{posted_at: e.posted_at, debit: e.debit_amount,
                  credit: e.credit_amount, desc: e.description}),
      [])
    if rows == [] do
      {:ok, ["(no GL entries for account #{account_id})"]}
    else
      {:ok, ["#{length(rows)} GL entries:",
             "  DATE                         DEBIT         CREDIT        DESCRIPTION" |
             Enum.map(rows, fn r ->
               "  #{r.posted_at}  " <>
               "#{String.pad_leading(to_string(r.debit || "—"), 12)}  " <>
               "#{String.pad_leading(to_string(r.credit || "—"), 12)}  #{r.desc}"
             end)]}
    end
  end

  defp dispatch_console(:cms, "gl", _, _socket),
    do: {:error, "Usage: gl <account_id>"}

  defp dispatch_console(:cms, "statement", [account_id | _], _socket) do
    rows = safe_query(
      from(s in "statements",
        where: s.account_id == ^account_id,
        order_by: [desc: s.cycle_date], limit: 6,
        select: %{cycle: s.cycle_date, balance: s.closing_balance, min: s.minimum_payment_due}),
      [])
    if rows == [] do
      {:ok, ["(no statements for account #{account_id})"]}
    else
      {:ok, ["#{length(rows)} statement(s):",
             "  CYCLE        CLOSING BALANCE   MIN PAYMENT" |
             Enum.map(rows, fn s ->
               "  #{s.cycle}  #{String.pad_leading(to_string(s.balance), 15)}  #{s.min}"
             end)]}
    end
  end

  defp dispatch_console(:cms, "statement", _, _socket),
    do: {:error, "Usage: statement <account_id>"}

  # ─── CIF ──────────────────────────────────────────────────────────────────

  defp dispatch_console(:cif, "list", _, _socket) do
    rows = safe_query(
      from(c in Customer, order_by: [desc: c.inserted_at], limit: 20,
        select: %{id: c.id, name: c.full_name, status: c.kyc_status}),
      [])
    if rows == [] do
      {:ok, ["(no customers found)"]}
    else
      {:ok, ["#{length(rows)} customer(s):" |
             Enum.map(rows, fn c ->
               "  #{c.id}  #{String.pad_trailing(to_string(c.name), 30)}  kyc=#{c.status}"
             end)]}
    end
  end

  defp dispatch_console(:cif, "search", [term | _], _socket) do
    like = "%#{term}%"
    rows = safe_query(
      from(c in Customer,
        where: ilike(c.full_name, ^like) or ilike(c.national_id, ^like),
        limit: 20,
        select: %{id: c.id, name: c.full_name, kyc: c.kyc_status}),
      [])
    if rows == [] do
      {:ok, ["No customers matching '#{term}'"]}
    else
      {:ok, ["#{length(rows)} match(es):" |
             Enum.map(rows, fn c ->
               "  #{c.id}  #{String.pad_trailing(to_string(c.name), 30)}  kyc=#{c.kyc}"
             end)]}
    end
  end

  defp dispatch_console(:cif, "search", _, _socket),
    do: {:error, "Usage: search <term>"}

  defp dispatch_console(:cif, "kyc", [customer_id | _], _socket) do
    case safe_query(from(c in Customer, where: c.id == ^customer_id, limit: 1, select: c), []) do
      [c] ->
        {:ok, ["Customer: #{c.id}",
               "  Name     : #{c.full_name}",
               "  KYC Tier : #{c.kyc_status}",
               "  Risk     : #{Map.get(c, :risk_flag, "—")}",
               "  Verified : #{Map.get(c, :id_verified_at, "not verified")}"]}
      [] -> {:error, "Customer not found: #{customer_id}"}
    end
  end

  defp dispatch_console(:cif, "kyc", _, _socket),
    do: {:error, "Usage: kyc <customer_id>"}

  # ─── CTA ──────────────────────────────────────────────────────────────────

  defp dispatch_console(:cta, "stock", _, _socket) do
    rows = safe_query(
      from(s in "card_stock", order_by: s.bin_range,
        select: %{bin: s.bin_range, stock: s.available_qty, reorder: s.reorder_threshold}),
      [])
    if rows == [] do
      {:ok, ["(no card stock data)", "# Tip: run mix ecto.migrate to create schema"]}
    else
      {:ok, ["Card stock levels:", "  BIN RANGE      AVAILABLE   REORDER" |
             Enum.map(rows, fn s ->
               flag = if s.stock <= s.reorder, do: " ⚠  LOW", else: ""
               "  #{String.pad_trailing(to_string(s.bin), 14)} #{String.pad_leading(to_string(s.stock), 9)}  #{s.reorder}#{flag}"
             end)]}
    end
  end

  defp dispatch_console(:cta, "orders", _, _socket) do
    rows = safe_query(
      from(o in "embossing_orders", order_by: [desc: o.inserted_at], limit: 20,
        select: %{id: o.id, status: o.status, account_id: o.account_id, ts: o.inserted_at}),
      [])
    if rows == [] do
      {:ok, ["(no embossing orders found)"]}
    else
      {:ok, ["#{length(rows)} order(s):" |
             Enum.map(rows, fn o ->
               "  #{o.id}  #{String.pad_trailing(to_string(o.status), 10)}  account=#{o.account_id}"
             end)]}
    end
  end

  defp dispatch_console(:cta, "card", [card_id | _], _socket) do
    rows = safe_query(
      from(c in "cards", where: c.id == ^card_id, limit: 1,
        select: %{id: c.id, status: c.status, account_id: c.account_id,
                  activated_at: c.activated_at, expires_at: c.expires_at}),
      [])
    case rows do
      [c] ->
        {:ok, ["Card: #{c.id}",
               "  Status    : #{c.status}",
               "  Account   : #{c.account_id}",
               "  Activated : #{c.activated_at || "—"}",
               "  Expires   : #{c.expires_at || "—"}"]}
      [] -> {:error, "Card not found: #{card_id}"}
    end
  end

  defp dispatch_console(:cta, "card", _, _socket),
    do: {:error, "Usage: card <card_id>"}

  # ─── IVR ──────────────────────────────────────────────────────────────────

  defp dispatch_console(:ivr, "sessions", _, _socket) do
    rows = safe_query(
      from(s in "ivr_sessions",
        where: s.status == "active",
        order_by: [desc: s.started_at], limit: 20,
        select: %{id: s.id, ani: s.ani, state: s.state, ts: s.started_at}),
      [])
    if rows == [] do
      {:ok, ["(no active IVR sessions)"]}
    else
      {:ok, ["#{length(rows)} active session(s):" |
             Enum.map(rows, fn s ->
               "  #{s.id}  ANI=#{s.ani}  state=#{s.state}  started=#{s.ts}"
             end)]}
    end
  end

  defp dispatch_console(:ivr, "otp", [account_id | _], _socket) do
    rows = safe_query(
      from(o in "otp_seeds", where: o.account_id == ^account_id,
        select: %{id: o.id, type: o.otp_type, last_used: o.last_used_at}),
      [])
    if rows == [] do
      {:ok, ["(no OTP seeds for account #{account_id})"]}
    else
      {:ok, ["OTP seeds for #{account_id}:" |
             Enum.map(rows, fn o ->
               "  #{o.id}  type=#{o.type}  last_used=#{o.last_used || "never"}"
             end)]}
    end
  end

  defp dispatch_console(:ivr, "otp", _, _socket),
    do: {:error, "Usage: otp <account_id>"}

  defp dispatch_console(:ivr, "status", _, _socket),
    do: {:ok, ["IVR Channel Status:", "  (connect IVR system integration for live channel data)"]}

  # ─── DPS ──────────────────────────────────────────────────────────────────

  defp dispatch_console(:dps, "list", args, _socket) do
    filter = Enum.at(args, 0, "open")
    base   = case filter do
      "all"      -> from(d in "disputes", order_by: [desc: d.inserted_at], limit: 20)
      "resolved" -> from(d in "disputes", where: d.status == "resolved", order_by: [desc: d.inserted_at], limit: 20)
      _          -> from(d in "disputes", where: d.status in ["open", "pending"], order_by: [desc: d.inserted_at], limit: 20)
    end
    rows = safe_query(
      from(d in base,
        select: %{id: d.id, status: d.status, amount: d.amount, account_id: d.account_id}),
      [])
    if rows == [] do
      {:ok, ["(no #{filter} disputes)"]}
    else
      {:ok, ["#{length(rows)} dispute(s) [#{filter}]:" |
             Enum.map(rows, fn d ->
               "  #{d.id}  #{String.pad_trailing(to_string(d.status), 10)}  amount=#{d.amount}  acc=#{d.account_id}"
             end)]}
    end
  end

  defp dispatch_console(:dps, "view", [dispute_id | _], _socket) do
    rows = safe_query(
      from(d in "disputes", where: d.id == ^dispute_id, limit: 1,
        select: %{id: d.id, status: d.status, amount: d.amount,
                  reason: d.reason_code, account_id: d.account_id, ts: d.inserted_at}),
      [])
    case rows do
      [d] ->
        {:ok, ["Dispute: #{d.id}",
               "  Status  : #{d.status}",
               "  Amount  : #{d.amount}",
               "  Reason  : #{d.reason}",
               "  Account : #{d.account_id}",
               "  Filed   : #{d.ts}"]}
      [] -> {:error, "Dispute not found: #{dispute_id}"}
    end
  end

  defp dispatch_console(:dps, "view", _, _socket),
    do: {:error, "Usage: view <dispute_id>"}

  defp dispatch_console(:dps, "chargebacks", _, _socket) do
    rows = safe_query(
      from(c in "chargebacks", order_by: [desc: c.inserted_at], limit: 15,
        select: %{id: c.id, status: c.status, deadline: c.network_deadline, amount: c.amount}),
      [])
    if rows == [] do
      {:ok, ["(no chargebacks found)"]}
    else
      {:ok, ["#{length(rows)} chargeback(s):" |
             Enum.map(rows, fn c ->
               "  #{c.id}  #{String.pad_trailing(to_string(c.status), 10)}  amount=#{c.amount}  deadline=#{c.deadline}"
             end)]}
    end
  end

  # ─── TRAMS ────────────────────────────────────────────────────────────────

  defp dispatch_console(:trams, "clearing", args, _socket) do
    date_str = Enum.at(args, 0)
    rows = if date_str do
      safe_query(
        from(c in "clearing_records",
          where: fragment("date(?)", c.settlement_date) == ^date_str,
          order_by: [desc: c.inserted_at], limit: 30,
          select: %{id: c.id, pan_token: c.pan_token, amount: c.amount,
                    status: c.clearing_status, ts: c.settlement_date}),
        [])
    else
      safe_query(
        from(c in "clearing_records",
          order_by: [desc: c.inserted_at], limit: 30,
          select: %{id: c.id, pan_token: c.pan_token, amount: c.amount,
                    status: c.clearing_status, ts: c.settlement_date}),
        [])
    end
    suffix = if date_str, do: " for #{date_str}", else: " (latest)"
    if rows == [] do
      {:ok, ["(no clearing records#{suffix})"]}
    else
      {:ok, ["#{length(rows)} clearing record(s)#{suffix}:" |
             Enum.map(rows, fn r ->
               "  #{r.id}  pan=#{r.pan_token}  amount=#{r.amount}  status=#{r.status}"
             end)]}
    end
  end

  defp dispatch_console(:trams, "search", [pan_token | _], _socket) do
    rows = safe_query(
      from(c in "clearing_records",
        where: c.pan_token == ^pan_token,
        order_by: [desc: c.inserted_at], limit: 20,
        select: %{id: c.id, amount: c.amount, status: c.clearing_status, ts: c.settlement_date}),
      [])
    if rows == [] do
      {:ok, ["(no clearing records for #{pan_token})"]}
    else
      {:ok, ["#{length(rows)} record(s) for #{pan_token}:" |
             Enum.map(rows, fn r ->
               "  #{r.id}  amount=#{r.amount}  status=#{r.status}  date=#{r.ts}"
             end)]}
    end
  end

  defp dispatch_console(:trams, "search", _, _socket),
    do: {:error, "Usage: search <pan_token>"}

  defp dispatch_console(:trams, "status", _, _socket),
    do: {:ok, ["IPM Processing Status:",
               "  Broadway pipeline: check /dashboard for real-time throughput and errors"]}

  # ─── COL ──────────────────────────────────────────────────────────────────

  defp dispatch_console(:col, "cases", args, _socket) do
    filter = Enum.at(args, 0, "open")
    base   = case filter do
      "all"      -> from(c in "collection_cases", order_by: [desc: c.inserted_at], limit: 20)
      "promised" -> from(c in "collection_cases", where: c.status == "promise_to_pay", order_by: [desc: c.inserted_at], limit: 20)
      _          -> from(c in "collection_cases", where: c.status in ["open", "in_progress"], order_by: [desc: c.inserted_at], limit: 20)
    end
    rows = safe_query(
      from(c in base,
        select: %{id: c.id, account_id: c.account_id, status: c.status, amount: c.overdue_amount}),
      [])
    if rows == [] do
      {:ok, ["(no #{filter} collection cases)"]}
    else
      {:ok, ["#{length(rows)} case(s) [#{filter}]:" |
             Enum.map(rows, fn c ->
               "  #{c.id}  acc=#{c.account_id}  #{String.pad_trailing(to_string(c.status), 12)}  overdue=#{c.amount}"
             end)]}
    end
  end

  defp dispatch_console(:col, "writeoffs", _, _socket) do
    rows = safe_query(
      from(w in "writeoff_records",
        order_by: [desc: w.written_off_at], limit: 20,
        select: %{id: w.id, account_id: w.account_id,
                  amount: w.written_off_amount, ts: w.written_off_at}),
      [])
    if rows == [] do
      {:ok, ["(no write-off records)"]}
    else
      {:ok, ["#{length(rows)} write-off(s):" |
             Enum.map(rows, fn w ->
               "  #{w.id}  acc=#{w.account_id}  amount=#{w.amount}  date=#{w.ts}"
             end)]}
    end
  end

  # ─── CDM ──────────────────────────────────────────────────────────────────

  defp dispatch_console(:cdm, "queue", _, _socket) do
    rows = safe_query(
      from(a in "credit_applications",
        where: a.status == "pending",
        order_by: [asc: a.submitted_at], limit: 20,
        select: %{id: a.id, customer_id: a.customer_id,
                  requested_limit: a.requested_limit, ts: a.submitted_at}),
      [])
    if rows == [] do
      {:ok, ["(no pending applications)"]}
    else
      {:ok, ["#{length(rows)} pending application(s):" |
             Enum.map(rows, fn a ->
               "  #{a.id}  customer=#{a.customer_id}  requested=#{a.requested_limit}  submitted=#{a.ts}"
             end)]}
    end
  end

  defp dispatch_console(:cdm, "decisions", _, _socket) do
    rows = safe_query(
      from(a in "credit_applications",
        where: a.status in ["approved", "declined"],
        order_by: [desc: a.decided_at], limit: 20,
        select: %{id: a.id, decision: a.status, approved_limit: a.approved_limit, ts: a.decided_at}),
      [])
    if rows == [] do
      {:ok, ["(no underwriting decisions found)"]}
    else
      {:ok, ["#{length(rows)} decision(s):" |
             Enum.map(rows, fn a ->
               "  #{a.id}  #{String.pad_trailing(to_string(a.decision), 8)}  " <>
               "limit=#{a.approved_limit || "—"}  decided=#{a.ts}"
             end)]}
    end
  end

  # ─── ASM ──────────────────────────────────────────────────────────────────

  defp dispatch_console(:asm, "operators", _, _socket) do
    rows = safe_query(
      from(o in "operators", order_by: [asc: o.username],
        select: %{id: o.id, username: o.username, role: o.role,
                  status: o.status, last_login: o.last_login_at}),
      [])
    if rows == [] do
      {:ok, ["(no operators found)"]}
    else
      {:ok, ["#{length(rows)} operator(s):",
             "  USERNAME              ROLE           STATUS     LAST LOGIN" |
             Enum.map(rows, fn o ->
               "  #{String.pad_trailing(to_string(o.username), 20)}  " <>
               "#{String.pad_trailing(to_string(o.role), 13)}  " <>
               "#{String.pad_trailing(to_string(o.status), 8)}  #{o.last_login || "never"}"
             end)]}
    end
  end

  defp dispatch_console(:asm, "params", [], _socket) do
    rows =
      try do
        ParameterEngine.all()
      rescue
        _ ->
          safe_query(
            from(p in "system_parameters", order_by: [asc: p.scope, asc: p.key],
              select: %{scope: p.scope, key: p.key, value: p.value}),
            [])
      end
    if rows == [] do
      {:ok, ["(no parameters — table may not exist yet)"]}
    else
      {:ok, ["System parameters:" |
             Enum.map(rows, fn p ->
               scope = Map.get(p, :scope, "")
               prefix = if scope && scope != "", do: "#{scope}/", else: ""
               "  #{prefix}#{p.key}  =  #{p.value}"
             end)]}
    end
  end

  defp dispatch_console(:asm, "param", [key | _], _socket) do
    val =
      try do
        ParameterEngine.get(key)
      rescue
        _ -> :not_found
      end
    case val do
      :not_found ->
        rows = safe_query(
          from(p in "system_parameters", where: p.key == ^key, limit: 1,
            select: %{key: p.key, value: p.value}),
          [])
        case rows do
          [p] -> {:ok, ["#{p.key} = #{p.value}"]}
          []  -> {:error, "Parameter not found: #{key}"}
        end
      v -> {:ok, ["#{key} = #{inspect(v)}"]}
    end
  end

  defp dispatch_console(:asm, "param", _, _socket),
    do: {:error, "Usage: param <key>"}

  defp dispatch_console(:asm, "audit", args, _socket) do
    op   = Enum.at(args, 0)
    rows = if op do
      safe_query(
        from(a in "audit_log",
          where: a.operator_id == ^op,
          order_by: [desc: a.inserted_at], limit: 30,
          select: %{action: a.action, resource: a.resource, ts: a.inserted_at}),
        [])
    else
      safe_query(
        from(a in "audit_log", order_by: [desc: a.inserted_at], limit: 30,
          select: %{operator: a.operator_id, action: a.action, resource: a.resource, ts: a.inserted_at}),
        [])
    end
    if rows == [] do
      {:ok, ["(no audit records#{if op, do: " for #{op}", else: ""})"]}
    else
      {:ok, ["#{length(rows)} audit record(s)#{if op, do: " for #{op}", else: ""}:" |
             Enum.map(rows, fn a ->
               op_part = if op, do: "", else: " op=#{Map.get(a, :operator, "?")} "
               "  #{a.ts}#{op_part}  #{a.action}  #{a.resource}"
             end)]}
    end
  end

  # ─── MBS ──────────────────────────────────────────────────────────────────

  defp dispatch_console(:mbs, "merchants", args, _socket) do
    limit = args |> Enum.at(0, "10") |> Integer.parse() |> then(fn {n, _} -> min(n, 50) end)
    rows  = safe_query(
      from(m in "merchants", order_by: [asc: m.name], limit: ^limit,
        select: %{id: m.id, name: m.name, status: m.status, mdr_tier: m.mdr_tier}),
      [])
    if rows == [] do
      {:ok, ["(no merchants found)"]}
    else
      {:ok, ["#{length(rows)} merchant(s):" |
             Enum.map(rows, fn m ->
               "  #{m.id}  #{String.pad_trailing(to_string(m.name), 30)}  #{m.status}  tier=#{m.mdr_tier}"
             end)]}
    end
  end

  defp dispatch_console(:mbs, "terminals", [merchant_id | _], _socket) do
    rows = safe_query(
      from(t in "pos_terminals", where: t.merchant_id == ^merchant_id,
        order_by: [asc: t.terminal_id],
        select: %{id: t.terminal_id, status: t.status, last_txn: t.last_transaction_at}),
      [])
    if rows == [] do
      {:ok, ["(no terminals for merchant #{merchant_id})"]}
    else
      {:ok, ["#{length(rows)} terminal(s):" |
             Enum.map(rows, fn t ->
               "  #{String.pad_trailing(to_string(t.id), 16)}  #{String.pad_trailing(to_string(t.status), 10)}  last_txn=#{t.last_txn || "never"}"
             end)]}
    end
  end

  defp dispatch_console(:mbs, "terminals", _, _socket),
    do: {:error, "Usage: terminals <merchant_id>"}

  defp dispatch_console(:mbs, "mdr", [merchant_id | _], _socket) do
    rows = safe_query(
      from(m in "mdr_configs", where: m.merchant_id == ^merchant_id, limit: 1,
        select: %{rate: m.mdr_rate, floor: m.floor_rate, cap: m.fee_cap, tier: m.tier_name}),
      [])
    case rows do
      [m] ->
        {:ok, ["MDR config for merchant #{merchant_id}:",
               "  Tier     : #{m.tier}",
               "  MDR Rate : #{m.rate}%",
               "  Floor    : #{m.floor}%",
               "  Fee Cap  : #{m.cap}"]}
      [] -> {:ok, ["(no MDR config for merchant #{merchant_id})"]}
    end
  end

  defp dispatch_console(:mbs, "mdr", _, _socket),
    do: {:error, "Usage: mdr <merchant_id>"}

  # ─── LMS ──────────────────────────────────────────────────────────────────

  defp dispatch_console(:lms, "schemes", _, _socket) do
    rows = safe_query(
      from(s in "loyalty_schemes", order_by: [asc: s.name],
        select: %{id: s.id, name: s.name, status: s.status, earn_rate: s.earn_rate}),
      [])
    if rows == [] do
      {:ok, ["(no loyalty schemes found)"]}
    else
      {:ok, ["#{length(rows)} scheme(s):" |
             Enum.map(rows, fn s ->
               "  #{s.id}  #{String.pad_trailing(to_string(s.name), 25)}  #{s.status}  earn=#{s.earn_rate} pts/unit"
             end)]}
    end
  end

  defp dispatch_console(:lms, "points", [account_id | _], _socket) do
    rows = safe_query(
      from(p in "loyalty_balances", where: p.account_id == ^account_id,
        select: %{scheme: p.scheme_id, balance: p.balance,
                  expiring: p.expiring_balance, expiry: p.next_expiry_date}),
      [])
    if rows == [] do
      {:ok, ["(no loyalty balance for account #{account_id})"]}
    else
      {:ok, ["Points for #{account_id}:" |
             Enum.map(rows, fn p ->
               "  scheme=#{p.scheme}  balance=#{p.balance} pts  expiring=#{p.expiring} pts  expires=#{p.expiry}"
             end)]}
    end
  end

  defp dispatch_console(:lms, "points", _, _socket),
    do: {:error, "Usage: points <account_id>"}

  defp dispatch_console(:lms, "enrollments", [account_id | _], _socket) do
    rows = safe_query(
      from(e in "loyalty_enrollments", where: e.account_id == ^account_id,
        order_by: [asc: e.enrolled_at],
        select: %{scheme: e.scheme_id, status: e.status, enrolled: e.enrolled_at}),
      [])
    if rows == [] do
      {:ok, ["(no scheme enrollments for account #{account_id})"]}
    else
      {:ok, ["#{length(rows)} enrollment(s) for #{account_id}:" |
             Enum.map(rows, fn e ->
               "  scheme=#{e.scheme}  #{e.status}  enrolled=#{e.enrolled}"
             end)]}
    end
  end

  defp dispatch_console(:lms, "enrollments", _, _socket),
    do: {:error, "Usage: enrollments <account_id>"}

  # ─── HCS ──────────────────────────────────────────────────────────────────

  defp dispatch_console(:hcs, "companies", _, _socket) do
    rows = safe_query(
      from(c in "corporate_companies", order_by: [asc: c.name], limit: 20,
        select: %{id: c.id, name: c.name, status: c.status, credit_pool: c.credit_pool}),
      [])
    if rows == [] do
      {:ok, ["(no corporate companies found)"]}
    else
      {:ok, ["#{length(rows)} company(ies):" |
             Enum.map(rows, fn c ->
               "  #{c.id}  #{String.pad_trailing(to_string(c.name), 30)}  #{c.status}  pool=#{c.credit_pool}"
             end)]}
    end
  end

  defp dispatch_console(:hcs, "employees", [company_id | _], _socket) do
    rows = safe_query(
      from(e in "employee_cards", where: e.company_id == ^company_id,
        limit: 30, order_by: [asc: e.employee_name],
        select: %{id: e.id, name: e.employee_name, account_id: e.account_id,
                  sub_limit: e.sub_limit, status: e.status}),
      [])
    if rows == [] do
      {:ok, ["(no employee cards for company #{company_id})"]}
    else
      {:ok, ["#{length(rows)} employee card(s):" |
             Enum.map(rows, fn e ->
               "  #{String.pad_trailing(to_string(e.name), 25)}  acc=#{e.account_id}  limit=#{e.sub_limit}  #{e.status}"
             end)]}
    end
  end

  defp dispatch_console(:hcs, "employees", _, _socket),
    do: {:error, "Usage: employees <company_id>"}

  defp dispatch_console(:hcs, "controls", [company_id | _], _socket) do
    rows = safe_query(
      from(c in "spending_controls", where: c.company_id == ^company_id,
        select: %{type: c.control_type, value: c.control_value, status: c.status}),
      [])
    if rows == [] do
      {:ok, ["(no spending controls for company #{company_id})"]}
    else
      {:ok, ["Spending controls for #{company_id}:" |
             Enum.map(rows, fn c ->
               "  #{String.pad_trailing(to_string(c.type), 20)}  #{c.value}  status=#{c.status}"
             end)]}
    end
  end

  defp dispatch_console(:hcs, "controls", _, _socket),
    do: {:error, "Usage: controls <company_id>"}

  # ─── ITS ──────────────────────────────────────────────────────────────────

  defp dispatch_console(:its, "copies", args, _socket) do
    filter = Enum.at(args, 0, "open")
    base   = case filter do
      "all"      -> from(c in "copy_requests", order_by: [desc: c.inserted_at], limit: 20)
      "resolved" -> from(c in "copy_requests", where: c.status == "fulfilled", order_by: [desc: c.inserted_at], limit: 20)
      _          -> from(c in "copy_requests", where: c.status in ["open", "pending"], order_by: [desc: c.inserted_at], limit: 20)
    end
    rows = safe_query(
      from(c in base, select: %{id: c.id, status: c.status, arn: c.arn, ts: c.inserted_at}),
      [])
    if rows == [] do
      {:ok, ["(no #{filter} copy requests)"]}
    else
      {:ok, ["#{length(rows)} copy request(s) [#{filter}]:" |
             Enum.map(rows, fn c ->
               "  #{c.id}  #{String.pad_trailing(to_string(c.status), 10)}  ARN=#{c.arn}  #{c.ts}"
             end)]}
    end
  end

  defp dispatch_console(:its, "fees", args, _socket) do
    date_str = Enum.at(args, 0)
    rows = if date_str do
      safe_query(
        from(f in "fee_claims",
          where: fragment("date(?)", f.settlement_date) == ^date_str,
          order_by: [desc: f.inserted_at], limit: 30,
          select: %{id: f.id, type: f.fee_type, amount: f.fee_amount, ts: f.settlement_date}),
        [])
    else
      safe_query(
        from(f in "fee_claims",
          order_by: [desc: f.inserted_at], limit: 30,
          select: %{id: f.id, type: f.fee_type, amount: f.fee_amount, ts: f.settlement_date}),
        [])
    end
    suffix = if date_str, do: " for #{date_str}", else: ""
    if rows == [] do
      {:ok, ["(no fee claims#{suffix})"]}
    else
      {:ok, ["#{length(rows)} fee claim(s)#{suffix}:" |
             Enum.map(rows, fn f ->
               "  #{f.id}  #{String.pad_trailing(to_string(f.type), 15)}  amount=#{f.amount}  date=#{f.ts}"
             end)]}
    end
  end

  defp dispatch_console(:its, "adjustments", _, _socket) do
    rows = safe_query(
      from(a in "financial_adjustment_records",
        order_by: [desc: a.inserted_at], limit: 20,
        select: %{id: a.id, network: a.network, reason: a.reason_code,
                  amount: a.adjustment_amount, ts: a.inserted_at}),
      [])
    if rows == [] do
      {:ok, ["(no financial adjustment records)"]}
    else
      {:ok, ["#{length(rows)} FAR(s):" |
             Enum.map(rows, fn a ->
               "  #{a.id}  #{String.pad_trailing(to_string(a.network), 6)}  reason=#{a.reason}  amount=#{a.amount}  #{a.ts}"
             end)]}
    end
  end

  # ─── System status (all modules) ──────────────────────────────────────────

  defp console_cmd_status do
    {:ok, [
      "VisionPlus System Status:",
      "  Node     : #{node()}",
      "  OTP app  : :vmu_core",
      "  DB pool  : #{inspect(VmuCore.Repo.config()[:pool_size] || 10)} connections",
      "  LiveView : connected via /live"
    ]}
  end

  # ─── Unknown command catch-all ────────────────────────────────────────────

  defp dispatch_console(module, cmd, _args, _socket) do
    mod_str = if module, do: String.upcase(to_string(module)), else: "this module"
    {:error, "Unknown command '#{cmd}' — type 'help' for #{mod_str} commands"}
  end
end
