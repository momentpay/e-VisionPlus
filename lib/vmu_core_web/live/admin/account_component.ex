defmodule VmuCoreWeb.Live.Admin.AccountComponent do
  use Phoenix.LiveComponent

  import Ecto.Query, warn: false
  import VmuCoreWeb.AdminUI

  alias VmuCore.{Repo}
  alias VmuCore.CMS.{
    Account, BalanceBucket, BlockCodeHistory, NonMonetaryEvent,
    SupplementaryCard, PlanSegment, TempLimit, FeeWaiver, FinancialAdjustment,
    LedgerEntry, AccountStateCoordinator, EmiSchedule
  }
  alias VmuCore.Shared.{Customer, BankParameter, LogoParameter, BlockParameter}
  alias VmuCore.CTA.{Cards, CardLifecycle}
  alias VmuCore.ASM.AuditLog

  @card_block_reasons [
    {"Lost",     "LOST"},
    {"Stolen",   "STOLEN"},
    {"Fraud",    "FRAUD"},
    {"Damaged",  "DAMAGED"},
    {"Admin hold", "ADMIN"}
  ]

  # Reasons that force a new PAN on replacement (CardLifecycle.replace/3)
  @card_replace_new_pan_reasons ~w[LOST STOLEN FRAUD]

  @tri_state [{"Inherit from product", ""}, {"Force allow", "true"}, {"Force block", "false"}]

  @default_operator_id "00000000-0000-0000-0000-000000000001"

  @block_codes [
    {"L — Lost Card",        "L"},
    {"S — Stolen Card",      "S"},
    {"F — Fraud Suspicion",  "F"},
    {"C — Collections Hold", "C"},
    {"O — Overlimit",        "O"}
  ]

  @block_reason_codes [
    {"REPORTED_LOST",     "Cardholder reported card lost"},
    {"REPORTED_STOLEN",   "Cardholder reported card stolen"},
    {"FRAUD_ALERT",       "Fraud team flagged suspicious activity"},
    {"COLLECTIONS_HOLD",  "Account moved to collections queue"},
    {"OVERLIMIT",         "Balance exceeds credit limit"},
    {"CUSTOMER_REQUEST",  "Cardholder requested temporary block"},
    {"EOD_AUTOMATED",     "Applied by automated EOD batch"}
  ]

  @unblock_reason_codes [
    {"INVESTIGATION_CLOSED", "Investigation completed, block lifted"},
    {"PAYMENT_RECEIVED",     "Overlimit block lifted after payment"},
    {"SUPERVISOR_OVERRIDE",  "Manual override by supervisor"},
    {"CUSTOMER_REQUEST",     "Cardholder requested unblock"}
  ]

  @operator_roles [{"Agent", "AGENT"}, {"Supervisor", "SUPERVISOR"}, {"System", "SYSTEM"}]

  # ── Lifecycle ────────────────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       mode: :list,
       result: nil,
       accounts: [],
       customers_map: %{},
       acc_search: "",
       status_filter: "",
       bank_filter: "",
       logo_filter: "",
       dpd_filter: "",
       # Detail
       account: nil,
       customer: nil,
       balance_bucket: nil,
       block_history: [],
       nonmon_events: [],
       supp_cards: [],
       plans: [],
       fee_entries: [],
       adj_entries: [],
       active_temp_limit: nil,
       statements: [],
       emi_schedules: [],
       detail_tab: 1,
       # CTA-P3: card generation list + event timeline for the Cards tab
       cards: [],
       card_events: [],
       selected_card_id: nil,
       # Constants for templates (module attrs not accessible via @ in HEEx)
       block_codes:          @block_codes,
       block_reason_codes:   @block_reason_codes,
       unblock_reason_codes: @unblock_reason_codes,
       operator_roles:       @operator_roles,
       card_block_reasons:   @card_block_reasons,
       tri_state:            @tri_state,
       # Action panel
       active_action: :none,
       action_data: %{},
       supp_search: "",
       supp_search_results: [],
       # Wizard
       wizard_step: 1,
       form_data: %{},
       customer_search: "",
       customer_results: [],
       logos_for_bank: [],
       blocks_for_logo: [],
       selected_logo: nil,
       bank_options: []
     )
     |> load_bank_options()
     |> load_accounts()}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  # ── Data Loading ─────────────────────────────────────────────────────────────

  defp load_bank_options(socket) do
    banks = Repo.all(BankParameter)
    opts  = [{"— All Banks —", ""} | Enum.map(banks, &{"#{&1.bank_id} — #{&1.org_name || &1.description}", &1.bank_id})]
    assign(socket, bank_options: opts)
  end

  defp load_accounts(socket) do
    s = socket.assigns

    # Bank data-scope (ASM-P2.4): scoped operators see only their BANK
    bank_filter =
      case Map.get(s, :current_operator) do
        %VmuCore.ASM.Operator{} = op ->
          VmuCore.ASM.Authz.bank_scope(op) || s.bank_filter

        _ ->
          s.bank_filter
      end

    accounts = search_accounts(s.acc_search, s.status_filter, bank_filter, s.logo_filter, s.dpd_filter)
    cust_ids  = accounts |> Enum.map(& &1.customer_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    custs     = if cust_ids == [], do: [], else: Repo.all(from c in Customer, where: c.customer_id in ^cust_ids)
    custs_map = Map.new(custs, &{&1.customer_id, &1})
    assign(socket, accounts: accounts, customers_map: custs_map)
  end

  defp search_accounts(search, status_f, bank_f, logo_f, dpd_f) do
    query = from(a in Account, order_by: [desc: a.inserted_at], limit: 100)

    query =
      if search != "" and search != nil do
        cust_ids =
          Repo.all(from c in Customer,
            where: ilike(c.first_name, ^"%#{search}%") or ilike(c.last_name, ^"%#{search}%"),
            select: c.customer_id)
        where(query, [a], a.last_four == ^search or a.customer_id in ^cust_ids)
      else
        query
      end

    query = if status_f != "", do: where(query, [a], a.account_status == ^status_f), else: query
    query = if bank_f   != "", do: where(query, [a], a.bank_id        == ^bank_f),   else: query
    query = if logo_f   != "", do: where(query, [a], a.logo_id        == ^logo_f),   else: query

    query =
      case dpd_f do
        "current" -> where(query, [a], a.delinquency_bucket == 0)
        "30"      -> where(query, [a], a.delinquency_bucket >= 1  and a.delinquency_bucket <= 30)
        "60"      -> where(query, [a], a.delinquency_bucket >= 31 and a.delinquency_bucket <= 60)
        "90"      -> where(query, [a], a.delinquency_bucket >= 61 and a.delinquency_bucket <= 90)
        "90plus"  -> where(query, [a], a.delinquency_bucket >= 91)
        _         -> query
      end

    Repo.all(query)
  end

  defp load_detail(socket, account_id) do
    acc = Repo.get(Account, account_id)
    if acc do
      acc   = Repo.preload(acc, [:balance_bucket])
      cust  = if acc.customer_id, do: Repo.get(Customer, acc.customer_id), else: nil
      bh    = BlockCodeHistory.history_for(account_id)
      evts  = NonMonetaryEvent.history_for(account_id)
      cards = SupplementaryCard.list_for_primary(account_id)
      plans = if acc.logo_id do
        Repo.all(from p in PlanSegment,
          where: p.logo_id == ^acc.logo_id,
          order_by: [asc: p.payment_priority])
      else
        []
      end
      fees = Repo.all(from e in LedgerEntry,
        where: e.account_id == ^account_id and e.transaction_code == "FEE",
        order_by: [desc: e.posting_date], limit: 30)
      adjs = FinancialAdjustment.list_for(account_id)
      tlim  = TempLimit.active_for(account_id)
      stmts = Repo.all(from b in BalanceBucket,
        where: b.account_id == ^account_id,
        order_by: [desc: b.balance_date],
        limit: 12)
      emis  = EmiSchedule.list_for(account_id)

      # CTA-P3: plastic generation list + event timeline for the Cards tab
      cta_cards = Cards.by_account(account_id)
      card_evts = AuditLog.for_subjects(Enum.map(cta_cards, & &1.card_id), action_prefix: "card_")

      assign(socket,
        account:           acc,
        customer:          cust,
        balance_bucket:    acc.balance_bucket,
        block_history:     bh,
        nonmon_events:     evts,
        supp_cards:        cards,
        plans:             plans,
        fee_entries:       fees,
        adj_entries:       adjs,
        active_temp_limit: tlim,
        statements:        stmts,
        emi_schedules:     emis,
        cards:             cta_cards,
        card_events:       card_evts
      )
    else
      assign(socket, result: {:error, "Account not found."})
    end
  end

  # ── Events: List ─────────────────────────────────────────────────────────────

  @impl true
  def handle_event("acc_search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(acc_search: q) |> load_accounts()}
  end

  def handle_event("acc_filter", params, socket) do
    socket =
      socket
      |> assign(
        status_filter: Map.get(params, "status", socket.assigns.status_filter),
        bank_filter:   Map.get(params, "bank",   socket.assigns.bank_filter),
        logo_filter:   Map.get(params, "logo",   socket.assigns.logo_filter),
        dpd_filter:    Map.get(params, "dpd",    socket.assigns.dpd_filter)
      )
      |> load_accounts()
    {:noreply, socket}
  end

  def handle_event("acc_view", %{"id" => id}, socket) do
    # PII view audit (ASM-P4.2, FR-ASM-015): account detail includes
    # cardholder identity + balances
    VmuCore.ASM.AuditLog.record(
      Map.get(socket.assigns, :current_operator), "account_detail_view", id)

    socket =
      socket
      |> assign(mode: :detail, detail_tab: 1, active_action: :none, result: nil)
      |> load_detail(id)
    {:noreply, socket}
  end

  def handle_event("acc_new", _params, socket) do
    {:noreply, assign(socket,
      mode: :form,
      wizard_step: 1,
      form_data: %{},
      customer_search: "",
      customer_results: [],
      logos_for_bank: [],
      blocks_for_logo: [],
      selected_logo: nil,
      result: nil
    )}
  end

  def handle_event("acc_back", _params, socket) do
    {:noreply, socket |> assign(mode: :list, account: nil, result: nil) |> load_accounts()}
  end

  # ── Events: Detail ───────────────────────────────────────────────────────────

  def handle_event("detail_tab", %{"t" => t}, socket) do
    {:noreply, assign(socket, detail_tab: String.to_integer(t), active_action: :none, result: nil)}
  end

  def handle_event("action_open", %{"a" => action}, socket) do
    {:noreply, assign(socket, active_action: String.to_atom(action), action_data: %{}, result: nil)}
  end

  def handle_event("action_close", _params, socket) do
    {:noreply, assign(socket, active_action: :none, action_data: %{})}
  end

  def handle_event("action_change", %{"action" => params}, socket) do
    {:noreply, assign(socket, action_data: params)}
  end

  # ── Events: Card lifecycle (CTA-P3) ─────────────────────────────────────────

  def handle_event("card_action_open", %{"a" => action, "id" => card_id}, socket) do
    {:noreply, assign(socket, active_action: String.to_atom(action),
                       selected_card_id: card_id, result: nil)}
  end

  def handle_event("card_activate_save", params, socket) do
    card_id = socket.assigns.selected_card_id

    case CardLifecycle.activate(card_id, method: params["method"] || "admin") do
      {:ok, card} ->
        {:noreply, socket |> load_detail(socket.assigns.account.account_id)
                   |> assign(active_action: :none,
                        result: {:ok, "Card gen #{card.generation} activated."})}

      {:error, reason} ->
        {:noreply, assign(socket, result: {:error, "Activation failed — #{inspect(reason)}"})}
    end
  end

  def handle_event("card_block_save", %{"reason" => reason}, socket) when reason != "" do
    card_id = socket.assigns.selected_card_id

    case CardLifecycle.block(card_id, reason) do
      {:ok, card} ->
        {:noreply, socket |> load_detail(socket.assigns.account.account_id)
                   |> assign(active_action: :none,
                        result: {:ok, "Card gen #{card.generation} blocked (#{reason})."})}

      {:error, reason} ->
        {:noreply, assign(socket, result: {:error, "Block failed — #{inspect(reason)}"})}
    end
  end

  def handle_event("card_block_save", _params, socket) do
    {:noreply, assign(socket, result: {:error, "A block reason is required."})}
  end

  def handle_event("card_unblock_save", _params, socket) do
    card_id = socket.assigns.selected_card_id

    case CardLifecycle.unblock(card_id) do
      {:ok, card} ->
        {:noreply, socket |> load_detail(socket.assigns.account.account_id)
                   |> assign(active_action: :none,
                        result: {:ok, "Card gen #{card.generation} unblocked."})}

      {:error, reason} ->
        {:noreply, assign(socket, result: {:error, "Unblock failed — #{inspect(reason)}"})}
    end
  end

  def handle_event("card_replace_save", %{"reason" => reason} = params, socket) when reason != "" do
    card_id   = socket.assigns.selected_card_id
    waive_fee = params["waive_fee"] == "true"

    opts =
      [waive_fee: waive_fee]
      |> maybe_new_pan(reason)

    case CardLifecycle.replace(card_id, reason, opts) do
      {:ok, %{new: new_card, fee: fee}} ->
        {:noreply, socket |> load_detail(socket.assigns.account.account_id)
                   |> assign(active_action: :none,
                        result: {:ok, "Replaced — new card gen #{new_card.generation} " <>
                                      "issued (#{reason}, fee: #{fee})."})}

      {:error, reason} ->
        {:noreply, assign(socket, result: {:error, "Replace failed — #{inspect(reason)}"})}
    end
  end

  def handle_event("card_replace_save", _params, socket) do
    {:noreply, assign(socket, result: {:error, "A reason is required."})}
  end

  def handle_event("card_renew_save", params, socket) do
    card_id  = socket.assigns.selected_card_id
    years    = String.to_integer(params["years"] || "3")
    activate = params["activate"] == "true"

    case CardLifecycle.renew(card_id, years: years, activate: activate) do
      {:ok, %{new: new_card}} ->
        {:noreply, socket |> load_detail(socket.assigns.account.account_id)
                   |> assign(active_action: :none,
                        result: {:ok, "Renewed — new card gen #{new_card.generation}, " <>
                                      "expires #{new_card.expiry}."})}

      {:error, reason} ->
        {:noreply, assign(socket, result: {:error, "Renew failed — #{inspect(reason)}"})}
    end
  end

  def handle_event("card_channels_save", params, socket) do
    card_id = socket.assigns.selected_card_id

    controls = %{
      ecom_enabled:        tri_parse(params["ecom_enabled"]),
      atm_enabled:         tri_parse(params["atm_enabled"]),
      contactless_enabled: tri_parse(params["contactless_enabled"]),
      intl_enabled:        tri_parse(params["intl_enabled"])
    }

    case CardLifecycle.set_channel_controls(card_id, controls) do
      {:ok, _card} ->
        {:noreply, socket |> load_detail(socket.assigns.account.account_id)
                   |> assign(active_action: :none, result: {:ok, "Channel controls updated."})}

      {:error, reason} ->
        {:noreply, assign(socket, result: {:error, "Update failed — #{inspect(reason)}"})}
    end
  end

  # Apply block code
  def handle_event("acc_block", %{"action" => params}, socket) do
    acc   = socket.assigns.account
    op_id = normalize_uuid(params["operator_id"])

    case BlockCodeHistory.record_block(
      acc.account_id,
      params["block_code"],
      params["reason_code"],
      params["reason_text"] || "",
      op_id,
      params["operator_role"] || "AGENT"
    ) do
      {:ok, _hist} ->
        socket =
          socket
          |> load_detail(acc.account_id)
          |> assign(active_action: :none, action_data: %{},
               result: {:ok, "Block code #{params["block_code"]} applied successfully."})
        {:noreply, socket}

      {:error, cs} ->
        msg = cs_error_msg(cs)
        {:noreply, assign(socket, result: {:error, "Block failed — #{msg}"})}
    end
  end

  # Remove block code
  def handle_event("acc_unblock", %{"action" => params}, socket) do
    acc   = socket.assigns.account
    op_id = normalize_uuid(params["operator_id"])

    case BlockCodeHistory.record_unblock(
      acc.account_id,
      acc.block_code || "L",
      params["reason_code"],
      params["reason_text"] || "",
      op_id,
      params["operator_role"] || "AGENT"
    ) do
      {:ok, _hist} ->
        socket =
          socket
          |> load_detail(acc.account_id)
          |> assign(active_action: :none, action_data: %{},
               result: {:ok, "Block removed successfully."})
        {:noreply, socket}

      {:error, cs} ->
        {:noreply, assign(socket, result: {:error, "Unblock failed — #{cs_error_msg(cs)}"})}
    end
  end

  # Non-monetary event
  def handle_event("nonmon_save", %{"action" => params}, socket) do
    acc   = socket.assigns.account
    etype = params["event_type"]
    op_id = normalize_uuid(params["operator_id"])
    {old_val, new_val} = build_nonmon_values(etype, params, socket.assigns)

    case NonMonetaryEvent.record(
      account_id:    acc.account_id,
      event_type:    etype,
      old_value:     old_val,
      new_value:     new_val,
      reason:        params["reason"] || "",
      reference_id:  params["reference_id"],
      operator_id:   op_id,
      operator_role: params["operator_role"] || "AGENT"
    ) do
      {:ok, _event} ->
        apply_nonmon_change(etype, params, socket.assigns)
        socket =
          socket
          |> load_detail(acc.account_id)
          |> assign(active_action: :none, action_data: %{},
               result: {:ok, "#{etype_label(etype)} recorded successfully."})
        {:noreply, socket}

      {:error, cs} ->
        {:noreply, assign(socket, result: {:error, "Event failed — #{cs_error_msg(cs)}"})}
    end
  end

  # ── Events: Wizard ───────────────────────────────────────────────────────────

  def handle_event("cust_search_wizard", %{"q" => q}, socket) do
    results =
      if String.length(q || "") >= 2 do
        term    = "%#{q}%"
        bank_id = socket.assigns.form_data["bank_id"] || ""
        base    = from c in Customer,
          where: (ilike(c.first_name, ^term) or ilike(c.last_name, ^term) or
                  ilike(c.email, ^term) or ilike(c.mobile_number, ^term)),
          limit: 10
        base    = if bank_id != "", do: where(base, [c], c.bank_id == ^bank_id), else: base
        Repo.all(base)
      else
        []
      end
    {:noreply, assign(socket, customer_search: q, customer_results: results)}
  end

  def handle_event("select_customer", %{"id" => cust_id}, socket) do
    case Repo.get(Customer, cust_id) do
      nil  -> {:noreply, socket}
      cust ->
        fd    = Map.merge(socket.assigns.form_data, %{
          "customer_id"   => to_string(cust.customer_id),
          "customer_name" => "#{cust.first_name} #{cust.last_name}",
          "kyc_status"    => cust.kyc_status,
          "bank_id"       => cust.bank_id,
          "sys_id"        => cust.sys_id,
          "emboss_name"   => "#{cust.first_name} #{cust.last_name}"
                             |> String.upcase()
                             |> String.slice(0, 26)
        })
        logos = Repo.all(from l in LogoParameter, where: l.bank_id == ^cust.bank_id, order_by: [asc: l.logo_id])
        {:noreply, assign(socket,
          form_data:        fd,
          customer_search:  "",
          customer_results: [],
          logos_for_bank:   logos,
          wizard_step:      2
        )}
    end
  end

  def handle_event("wizard_step", %{"s" => s}, socket) do
    {:noreply, assign(socket, wizard_step: String.to_integer(s))}
  end

  def handle_event("wizard_change", %{"acc" => params}, socket) do
    fd = Map.merge(socket.assigns.form_data, params)

    socket =
      if params["logo_id"] && params["logo_id"] != socket.assigns.form_data["logo_id"] do
        logo_id  = params["logo_id"]
        bank_id  = fd["bank_id"] || ""
        sys_id   = fd["sys_id"] || ""
        logo_rec = Repo.get_by(LogoParameter, logo_id: logo_id, bank_id: bank_id, sys_id: sys_id)
        blocks   = Repo.all(from b in BlockParameter,
          where: b.logo_id == ^logo_id and b.bank_id == ^bank_id,
          order_by: [asc: b.block_id])
        assign(socket, form_data: fd, selected_logo: logo_rec, blocks_for_logo: blocks)
      else
        assign(socket, form_data: fd)
      end

    {:noreply, socket}
  end

  def handle_event("wizard_save", %{"acc" => params}, socket) do
    fd = Map.merge(socket.assigns.form_data, params)

    pan_stub  = "STUB_#{fd["bank_id"]}_#{fd["last_four"]}_#{fd["expiry_date"]}"
    pan_token = :crypto.hash(:sha256, pan_stub) |> Base.encode16(case: :lower)

    credit_limit = parse_decimal(fd["credit_limit"]) || Decimal.new(0)
    cash_limit   = parse_decimal(fd["cash_limit"]) ||
                   Decimal.mult(credit_limit, Decimal.new("0.30"))

    attrs = %{
      customer_id:      fd["customer_id"],
      sys_id:           fd["sys_id"],
      bank_id:          fd["bank_id"],
      logo_id:          fd["logo_id"],
      block_id:         fd["block_id"] || "DFLT",
      pan_token:        pan_token,
      last_four:        fd["last_four"],
      expiry_date:      fd["expiry_date"],
      emboss_name:      (fd["emboss_name"] || "") |> String.upcase() |> String.slice(0, 26),
      credit_limit:     credit_limit,
      open_to_buy:      credit_limit,
      cash_limit:       cash_limit,
      cash_open_to_buy: cash_limit,
      cycle_code:       parse_int(fd["cycle_code"]) || 1,
      account_status:   "ACTIVE",
      open_date:        Date.utc_today(),
      campaign_code:    fd["campaign_code"]
    }

    case %Account{} |> Account.changeset(attrs) |> Repo.insert() do
      {:ok, new_acc} ->
        %BalanceBucket{}
        |> BalanceBucket.changeset(%{account_id: new_acc.account_id, balance_date: Date.utc_today()})
        |> Repo.insert()

        socket =
          socket
          |> load_detail(new_acc.account_id)
          |> load_accounts()
          |> assign(mode: :detail, detail_tab: 1,
               result: {:ok, "Account created. Reference: #{short_id(to_string(new_acc.account_id))}"})
        {:noreply, socket}

      {:error, cs} ->
        {:noreply, assign(socket, result: {:error, "Creation failed — #{cs_error_msg(cs)}"})}
    end
  end

  # ── Events: Phase 4B Financial Operations ────────────────────────────────────

  # Supplementary card account search
  def handle_event("supp_search", %{"q" => q}, socket) do
    acc = socket.assigns.account
    results =
      if String.length(q || "") >= 2 do
        term = "%#{q}%"
        Repo.all(from a in Account,
          join: c in Customer, on: c.customer_id == a.customer_id,
          where: a.bank_id == ^acc.bank_id and
                 a.account_id != ^acc.account_id and
                 (a.last_four == ^q or
                  ilike(c.first_name, ^term) or ilike(c.last_name, ^term)),
          preload: [],
          limit: 8,
          select: %{account_id: a.account_id, last_four: a.last_four, emboss_name: a.emboss_name,
                    account_status: a.account_status,
                    customer_name: fragment("? || ' ' || ?", c.first_name, c.last_name)})
      else
        []
      end
    {:noreply, assign(socket, supp_search: q, supp_search_results: results)}
  end

  # Permanent credit limit change
  def handle_event("perm_limit_save", %{"action" => params}, socket) do
    acc      = socket.assigns.account
    new_lim  = parse_decimal(params["new_limit"])

    cond do
      is_nil(new_lim) ->
        {:noreply, assign(socket, result: {:error, "New limit is required and must be a valid number."})}

      Decimal.compare(new_lim, Decimal.new(0)) != :gt ->
        {:noreply, assign(socket, result: {:error, "New limit must be greater than zero."})}

      true ->
        old_lim = acc.credit_limit
        diff    = Decimal.sub(new_lim, old_lim)
        new_otb = Decimal.max(Decimal.add(acc.open_to_buy || Decimal.new(0), diff), Decimal.new(0))

        case acc |> Account.changeset(%{credit_limit: new_lim, open_to_buy: new_otb}) |> Repo.update() do
          {:ok, _updated} ->
            AccountStateCoordinator.refresh_limit(acc.account_id, new_lim)
            NonMonetaryEvent.record(
              account_id:    acc.account_id,
              event_type:    "limit_change",
              old_value:     %{"credit_limit" => Decimal.to_string(old_lim || Decimal.new(0))},
              new_value:     %{"credit_limit" => Decimal.to_string(new_lim)},
              reason:        params["reason"] || "Manual limit change",
              operator_id:   normalize_uuid(params["operator_id"]),
              operator_role: params["operator_role"] || "SUPERVISOR"
            )
            socket =
              socket
              |> load_detail(acc.account_id)
              |> assign(active_action: :none, action_data: %{},
                   result: {:ok, "Credit limit updated to #{Decimal.to_string(new_lim)}."})
            {:noreply, socket}

          {:error, cs} ->
            {:noreply, assign(socket, result: {:error, "Limit change failed — #{cs_error_msg(cs)}"})}
        end
    end
  end

  # Temporary limit grant (4-eyes)
  def handle_event("temp_limit_save", %{"action" => params}, socket) do
    acc = socket.assigns.account
    temp_val = parse_decimal(params["temp_limit"])

    if is_nil(temp_val) do
      {:noreply, assign(socket, result: {:error, "Temporary limit amount is required."})}
    else
      # ASM-P3.1: maker = authenticated operator; checker must be a real,
      # distinct, authorized operator (free-form IDs no longer accepted)
      with {:ok, checker} <- resolve_checker(socket, params["supervisor_id"], temp_val) do
      attrs = %{
        account_id:    acc.account_id,
        temp_limit:    temp_val,
        expiry_date:   params["expiry_date"],
        reason:        params["reason"] || "",
        operator_id:   maker_id(socket),
        supervisor_id: checker.username
      }

      case TempLimit.grant(attrs) do
        {:ok, _tlim} ->
          socket =
            socket
            |> load_detail(acc.account_id)
            |> assign(active_action: :none, action_data: %{},
                 result: {:ok, "Temporary limit #{Decimal.to_string(temp_val)} granted until #{params["expiry_date"]}."})
          {:noreply, socket}

        {:error, %Ecto.Changeset{} = cs} ->
          {:noreply, assign(socket, result: {:error, "Temp limit failed — #{cs_error_msg(cs)}"})}

        {:error, reason} when is_binary(reason) ->
          {:noreply, assign(socket, result: {:error, "Temp limit failed — #{reason}"})}

        {:error, reason} ->
          {:noreply, assign(socket, result: {:error, "Temp limit failed — #{inspect(reason)}"})}
      end
      else
        {:error, checker_error} ->
          {:noreply, assign(socket, result: {:error, checker_error_msg(checker_error)})}
      end
    end
  end

  # Fee waiver (4-eyes)
  def handle_event("fee_waiver_save", %{"action" => params}, socket) do
    acc = socket.assigns.account

    # ASM-P3.1: fee amounts vary — checker validated without amount bound
    # (waivers are bounded by the fee entry itself, not free-form input)
    result =
      with {:ok, checker} <- resolve_checker(socket, params["supervisor_id"], nil) do
        FeeWaiver.waive_by_entry_id(
          entry_id:      params["entry_id"],
          account_id:    acc.account_id,
          reason:        params["reason"] || "",
          operator_id:   maker_id(socket),
          supervisor_id: checker.username,
          posting_date:  Date.utc_today()
        )
      end

    case result do
      {:ok, _entry} ->
        socket =
          socket
          |> load_detail(acc.account_id)
          |> assign(active_action: :none, action_data: %{},
               result: {:ok, "Fee waiver posted successfully."})
        {:noreply, socket}

      {:error, :operator_and_supervisor_must_differ} ->
        {:noreply, assign(socket, result: {:error, "4-eyes: Operator ID and Supervisor ID must be different."})}

      {:error, {:fee_entry_not_found, _}} ->
        {:noreply, assign(socket, result: {:error, "Selected fee entry not found. Please reload and try again."})}

      {:error, :duplicate} ->
        {:noreply, assign(socket, result: {:error, "This fee waiver has already been applied."})}

      {:error, checker_error} when checker_error in [:checker_not_found, :checker_is_maker,
                                                     :checker_lacks_permission,
                                                     :checker_exceeds_authority] ->
        {:noreply, assign(socket, result: {:error, checker_error_msg(checker_error)})}

      {:error, reason} ->
        {:noreply, assign(socket, result: {:error, "Fee waiver failed — #{inspect(reason)}"})}
    end
  end

  # Financial adjustment (4-eyes)
  def handle_event("fin_adj_save", %{"action" => params}, socket) do
    acc    = socket.assigns.account
    amount = parse_decimal(params["amount"])

    cond do
      is_nil(amount) ->
        {:noreply, assign(socket, result: {:error, "Amount is required."})}

      params["reference_id"] == "" or is_nil(params["reference_id"]) ->
        {:noreply, assign(socket, result: {:error, "Reference ID (case/ticket number) is required."})}

      true ->
        direction = if params["direction"] == "debit", do: :debit, else: :credit

        fn_call = if direction == :credit,
          do: &FinancialAdjustment.post_credit/1,
          else: &FinancialAdjustment.post_debit/1

        # ASM-P3.1/P3.2: checker must be real, distinct, authorized, and
        # within their role's authority limit for this amount
        case resolve_checker(socket, params["supervisor_id"], amount) do
          {:error, checker_error} ->
            {:noreply, assign(socket, result: {:error, checker_error_msg(checker_error)})}

          {:ok, checker} ->
            opts = [
              account_id:    acc.account_id,
              amount:        amount,
              reason:        params["reason"] || "",
              reference_id:  params["reference_id"],
              operator_id:   maker_id(socket),
              supervisor_id: checker.username,
              posting_date:  Date.utc_today()
            ]

            case fn_call.(opts) do
              {:ok, _entry} ->
                dir_label = if direction == :credit, do: "Credit", else: "Debit"
                socket =
                  socket
                  |> load_detail(acc.account_id)
                  |> assign(active_action: :none, action_data: %{},
                       result: {:ok, "#{dir_label} adjustment of #{Decimal.to_string(amount)} posted."})
                {:noreply, socket}

              {:error, :operator_and_supervisor_must_differ} ->
                {:noreply, assign(socket, result: {:error, "4-eyes: Operator and Supervisor IDs must differ."})}

              {:error, reason} ->
                {:noreply, assign(socket, result: {:error, "Adjustment failed — #{inspect(reason)}"})}
            end
        end
    end
  end

  # Link supplementary card
  def handle_event("supp_card_link", %{"action" => params}, socket) do
    acc    = socket.assigns.account
    supp_id = params["supp_account_id"]

    if supp_id == "" or is_nil(supp_id) do
      {:noreply, assign(socket, result: {:error, "Please select a supplementary account first."})}
    else
      sub_limit = parse_decimal(params["sub_limit"])
      opts      = if sub_limit, do: [sub_limit: sub_limit], else: []

      case SupplementaryCard.create(acc.account_id, supp_id, opts) do
        {:ok, _rel} ->
          socket =
            socket
            |> load_detail(acc.account_id)
            |> assign(active_action: :none, supp_search: "", supp_search_results: [],
                 result: {:ok, "Supplementary card linked successfully."})
          {:noreply, socket}

        {:error, cs} ->
          {:noreply, assign(socket, result: {:error, "Link failed — #{cs_error_msg(cs)}"})}
      end
    end
  end

  # ── Private: Non-monetary helpers ────────────────────────────────────────────

  defp build_nonmon_values("address_change", params, assigns) do
    c   = assigns.customer
    old = %{"line1" => c && c.address_line1, "city" => c && c.city, "country" => c && c.country}
    new = %{"line1" => params["new_line1"], "line2" => params["new_line2"],
            "city"  => params["new_city"],  "postal" => params["new_postal"],
            "country" => params["new_country"]}
    {old, new}
  end
  defp build_nonmon_values("phone_change", params, assigns) do
    c   = assigns.customer
    old = %{"mobile_country" => c && c.mobile_country, "mobile_number" => c && c.mobile_number}
    new = %{"mobile_country" => params["new_mobile_country"], "mobile_number" => params["new_mobile_number"]}
    {old, new}
  end
  defp build_nonmon_values("email_change", params, assigns) do
    c = assigns.customer
    {%{"email" => c && c.email}, %{"email" => params["new_email"]}}
  end
  defp build_nonmon_values("cycle_change", params, assigns) do
    {%{"cycle_code" => assigns.account.cycle_code}, %{"cycle_code" => params["new_cycle_code"]}}
  end
  defp build_nonmon_values("name_change", params, assigns) do
    {%{"emboss_name" => assigns.account.emboss_name}, %{"emboss_name" => params["new_emboss_name"]}}
  end
  defp build_nonmon_values(_, _, _), do: {nil, nil}

  defp apply_nonmon_change("address_change", params, %{customer: c}) when not is_nil(c) do
    c |> Customer.changeset(%{
      address_line1: params["new_line1"], address_line2: params["new_line2"],
      city: params["new_city"], postal_code: params["new_postal"], country: params["new_country"]
    }) |> Repo.update()
  end
  defp apply_nonmon_change("phone_change", params, %{customer: c}) when not is_nil(c) do
    c |> Customer.changeset(%{
      mobile_country: params["new_mobile_country"], mobile_number: params["new_mobile_number"]
    }) |> Repo.update()
  end
  defp apply_nonmon_change("email_change", params, %{customer: c}) when not is_nil(c) do
    c |> Customer.changeset(%{email: params["new_email"]}) |> Repo.update()
  end
  defp apply_nonmon_change("cycle_change", params, %{account: acc}) do
    acc |> Account.changeset(%{cycle_code: parse_int(params["new_cycle_code"])}) |> Repo.update()
  end
  defp apply_nonmon_change("name_change", params, %{account: acc}) do
    new_name = (params["new_emboss_name"] || "") |> String.upcase() |> String.slice(0, 26)
    acc |> Account.changeset(%{emboss_name: new_name}) |> Repo.update()
  end
  defp apply_nonmon_change(_, _, _), do: :ok

  # ── Private: Small helpers ────────────────────────────────────────────────────

  # ── ASM-P3.1: 4-eyes identity helpers ────────────────────────────────────────

  # Maker = the authenticated operator (assigned by AdminLive); "SYSTEM"
  # fallback only for non-interactive callers
  defp maker_id(socket) do
    case Map.get(socket.assigns, :current_operator) do
      %{username: username} -> username
      _ -> "SYSTEM"
    end
  end

  defp resolve_checker(socket, supervisor_username, amount) do
    case Map.get(socket.assigns, :current_operator) do
      %VmuCore.ASM.Operator{} = maker ->
        VmuCore.ASM.Authz.validate_checker(supervisor_username, maker, "account", amount)

      _ ->
        {:error, :checker_not_found}
    end
  end

  defp checker_error_msg(:checker_not_found),
    do: "4-eyes: Supervisor username not found or not an active operator."
  defp checker_error_msg(:checker_is_maker),
    do: "4-eyes: You cannot approve your own action — enter a different supervisor."
  defp checker_error_msg(:checker_lacks_permission),
    do: "4-eyes: That operator's role cannot approve account actions."
  defp checker_error_msg(:checker_exceeds_authority),
    do: "4-eyes: Amount exceeds that supervisor's authority limit."
  defp checker_error_msg(other),
    do: "4-eyes validation failed — #{inspect(other)}"

  defp normalize_uuid(""), do: @default_operator_id
  defp normalize_uuid(nil), do: @default_operator_id
  defp normalize_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error      -> @default_operator_id
    end
  end

  defp cs_error_msg(cs) do
    Enum.map_join(cs.errors, "; ", fn {f, {m, _}} -> "#{f}: #{m}" end)
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""),  do: nil
  defp parse_decimal(s) do
    case Decimal.parse(s) do
      {d, ""} -> d
      _       -> nil
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(""),  do: nil
  defp parse_int(s),   do: String.to_integer(s)

  defp etype_label("address_change"), do: "Address change"
  defp etype_label("phone_change"),   do: "Phone change"
  defp etype_label("email_change"),   do: "Email change"
  defp etype_label("cycle_change"),   do: "Billing cycle change"
  defp etype_label("name_change"),    do: "Emboss name change"
  defp etype_label(t),                do: t

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_), do: "—"

  defp money(nil), do: "—"
  defp money(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string()
  defp money(v), do: to_string(v)

  defp date_s(nil), do: "—"
  defp date_s(%Date{} = d), do: Date.to_iso8601(d)
  defp date_s(%NaiveDateTime{} = dt), do: NaiveDateTime.to_string(dt) |> String.slice(0, 16)
  defp date_s(v), do: to_string(v)

  defp util_pct(%Decimal{} = limit, %Decimal{} = otb) do
    used = Decimal.sub(limit, otb)
    if Decimal.gt?(limit, Decimal.new(0)) do
      Decimal.div(used, limit) |> Decimal.mult(Decimal.new(100))
      |> Decimal.to_float() |> trunc() |> max(0) |> min(100)
    else
      0
    end
  end
  defp util_pct(_, _), do: 0

  defp util_color(pct) when pct < 50, do: "util-green"
  defp util_color(pct) when pct < 80, do: "util-yellow"
  defp util_color(_),                  do: "util-red"

  defp status_cls("ACTIVE"),     do: "badge-green"
  defp status_cls("BLOCKED"),    do: "badge-red"
  defp status_cls("SUSPENDED"),  do: "badge-yellow"
  defp status_cls("DELINQUENT"), do: "badge-red"
  defp status_cls("CLOSED"),     do: "badge-gray"
  defp status_cls(_),            do: "badge-gray"

  # ── CTA-P3 card helpers ──────────────────────────────────────────────────────

  defp selected_card(assigns) do
    Enum.find(assigns.cards, &(&1.card_id == assigns.selected_card_id))
  end

  # Tri-state select: current field value (true/false/nil) vs. the option's
  # string form value ("true"/"false"/"").
  defp tri_selected(true,  "true"),  do: true
  defp tri_selected(false, "false"), do: true
  defp tri_selected(nil,   ""),      do: true
  defp tri_selected(_, _),           do: false

  defp tri_parse("true"),  do: true
  defp tri_parse("false"), do: false
  defp tri_parse(_),       do: nil

  # LOST/STOLEN/FRAUD compromise the PAN — mint a synthetic replacement
  # number for this console action. A production issuer would call a real
  # BIN/tokenization service here; this generates a same-shape stand-in
  # (16 digits, same convention used across this codebase's test fixtures)
  # so the replacement flow is exercisable end-to-end today.
  defp maybe_new_pan(opts, reason) when reason in @card_replace_new_pan_reasons do
    new_pan = "4" <> (:rand.uniform(999_999_999_999_999) |> Integer.to_string() |> String.pad_leading(15, "0"))
    new_pan_token = :crypto.hash(:sha256, new_pan) |> Base.encode16(case: :lower)

    opts
    |> Keyword.put(:new_pan_token, new_pan_token)
    |> Keyword.put(:new_last_four, String.slice(new_pan, -4, 4))
  end

  defp maybe_new_pan(opts, _reason), do: opts

  defp card_status_cls("ACTIVE"),    do: "badge-green"
  defp card_status_cls("BLOCKED"),   do: "badge-red"
  defp card_status_cls("INACTIVE"),  do: "badge-yellow"
  defp card_status_cls("EXPIRED"),   do: "badge-gray"
  defp card_status_cls("REPLACED"),  do: "badge-gray"
  defp card_status_cls("DESTROYED"), do: "badge-gray"
  defp card_status_cls(_),           do: "badge-blue"

  # Channel-control dot: green = force-allow, red = force-block, gray = inherit
  defp channel_dot(label, true),  do: raw_dot(label, "#16a34a")
  defp channel_dot(label, false), do: raw_dot(label, "#dc2626")
  defp channel_dot(label, _nil),  do: raw_dot(label, "#9ca3af")

  defp raw_dot(label, color) do
    Phoenix.HTML.raw(
      "<span style=\"display:inline-block;width:16px;height:16px;line-height:16px;" <>
      "border-radius:3px;background:#{color};color:#fff;text-align:center;" <>
      "font-size:9px;margin-right:2px;\">#{label}</span>"
    )
  end

  defp card_event_dot("card_block"),   do: "timeline-dot-red"
  defp card_event_dot("card_replace"), do: "timeline-dot-red"
  defp card_event_dot("card_unblock"), do: "timeline-dot-green"
  defp card_event_dot("card_activate"),do: "timeline-dot-green"
  defp card_event_dot(_),              do: "timeline-dot-blue"

  defp card_event_label("card_activate"),          do: "Card Activated"
  defp card_event_label("card_block"),             do: "Card Blocked"
  defp card_event_label("card_unblock"),            do: "Card Unblocked"
  defp card_event_label("card_replace"),           do: "Card Replaced"
  defp card_event_label("card_renew"),             do: "Card Renewed"
  defp card_event_label("card_channel_controls"),  do: "Channel Controls Updated"
  defp card_event_label(action),                   do: action

  defp dpd_info(0),              do: {"Current",   "badge-green"}
  defp dpd_info(n) when n <= 30, do: {"1-30 DPD",  "badge-yellow"}
  defp dpd_info(n) when n <= 60, do: {"31-60 DPD", "badge-red"}
  defp dpd_info(n) when n <= 90, do: {"61-90 DPD", "badge-red"}
  defp dpd_info(_),              do: {"90+ DPD",   "badge-red"}

  defp block_dot("BLOCKED"),   do: "timeline-dot-red"
  defp block_dot("UNBLOCKED"), do: "timeline-dot-green"
  defp block_dot(_),           do: "timeline-dot-gray"

  defp event_dot("cycle_change"), do: "timeline-dot-red"
  defp event_dot(_),              do: "timeline-dot-blue"

  defp plan_type_badge("RETAIL"),           do: "badge-green"
  defp plan_type_badge("CASH"),             do: "badge-yellow"
  defp plan_type_badge("EMI"),              do: "badge-blue"
  defp plan_type_badge("BALANCE_TRANSFER"), do: "badge-purple"
  defp plan_type_badge(_),                  do: "badge-gray"

  defp emi_status_badge("PENDING"), do: "badge-yellow"
  defp emi_status_badge("PAID"),    do: "badge-green"
  defp emi_status_badge("OVERDUE"), do: "badge-red"
  defp emi_status_badge("WAIVED"),  do: "badge-gray"
  defp emi_status_badge(_),         do: "badge-gray"

  # ── Render ───────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_header
        title="Accounts (CMS)"
        subtitle="Credit Management System — account base segments, balances and card operations"
      >
        <:actions>
          <%= if @mode == :list do %>
            <button phx-click="acc_new" phx-target={@myself} class="btn btn-primary">+ Open Account</button>
          <% end %>
          <%= if @mode in [:detail, :form] do %>
            <button phx-click="acc_back" phx-target={@myself} class="btn btn-secondary">← Back to List</button>
          <% end %>
        </:actions>
      </.page_header>

      <%= if @result do %>
        <% {kind, msg} = @result %>
        <div class={"alert alert-#{kind}"} style="margin-bottom:16px;"><%= msg %></div>
      <% end %>

      <%= case @mode do %>
        <% :list   -> %> <%= render_list(assigns) %>
        <% :detail -> %> <%= render_detail(assigns) %>
        <% :form   -> %> <%= render_wizard(assigns) %>
        <% _       -> %> <p>Unknown mode.</p>
      <% end %>
    </div>
    """
  end

  # ── List view ────────────────────────────────────────────────────────────────

  defp render_list(assigns) do
    total      = length(assigns.accounts)
    active     = Enum.count(assigns.accounts, &(&1.account_status == "ACTIVE"))
    blocked    = Enum.count(assigns.accounts, &(not is_nil(&1.block_code)))
    delinquent = Enum.count(assigns.accounts, &((&1.delinquency_bucket || 0) > 0))

    assigns = assign(assigns,
      acc_total:      total,
      acc_active:     active,
      acc_blocked:    blocked,
      acc_delinquent: delinquent
    )

    ~H"""
    <div>
      <div class="stat-grid" style="grid-template-columns:repeat(4,1fr);margin-bottom:20px;">
        <div class="stat-card">
          <div class="stat-label">Total Accounts</div>
          <div class="stat-value"><%= @acc_total %></div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Active</div>
          <div class="stat-value" style="color:var(--success)"><%= @acc_active %></div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Blocked</div>
          <div class="stat-value" style="color:var(--danger)"><%= @acc_blocked %></div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Delinquent DPD</div>
          <div class="stat-value" style="color:var(--warning)"><%= @acc_delinquent %></div>
        </div>
      </div>

      <div class="card">
        <div class="card-header" style="display:flex;align-items:center;gap:12px;flex-wrap:wrap;">
          <input
            type="text"
            class="input"
            style="flex:1;min-width:220px;"
            placeholder="Search by cardholder name or last 4 digits…"
            value={@acc_search}
            phx-keyup="acc_search" phx-key="Enter"
            phx-debounce="300"
            phx-value-q={@acc_search}
            phx-target={@myself}
          />
          <select class="input" style="width:150px;"
            phx-change="acc_filter" phx-target={@myself} name="status">
            <option value="">All Statuses</option>
            <option value="ACTIVE">Active</option>
            <option value="BLOCKED">Blocked</option>
            <option value="SUSPENDED">Suspended</option>
            <option value="DELINQUENT">Delinquent</option>
            <option value="CLOSED">Closed</option>
          </select>
          <select class="input" style="width:170px;"
            phx-change="acc_filter" phx-target={@myself} name="dpd">
            <option value="">All DPD</option>
            <option value="current">Current (0)</option>
            <option value="30">1–30 DPD</option>
            <option value="60">31–60 DPD</option>
            <option value="90">61–90 DPD</option>
            <option value="90plus">90+ DPD</option>
          </select>
          <select class="input" style="width:180px;"
            phx-change="acc_filter" phx-target={@myself} name="bank">
            <%= for {label, val} <- @bank_options do %>
              <option value={val} selected={@bank_filter == val}><%= label %></option>
            <% end %>
          </select>
        </div>

        <div class="table-wrap">
          <table class="data-table">
            <colgroup>
              <col style="width:110px"/>
              <col style="width:180px"/>
              <col style="width:90px"/>
              <col style="width:80px"/>
              <col style="width:80px"/>
              <col style="width:100px"/>
              <col style="width:120px"/>
              <col style="width:110px"/>
              <col style="width:90px"/>
            </colgroup>
            <thead>
              <tr>
                <th>Account ID</th>
                <th>Cardholder</th>
                <th>Bank/Logo</th>
                <th>Status</th>
                <th>Block</th>
                <th>DPD</th>
                <th>Credit Limit</th>
                <th>Open to Buy</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= if @accounts == [] do %>
                <tr><td colspan="9" class="empty-row">No accounts found.</td></tr>
              <% end %>
              <%= for acc <- @accounts do %>
                <% cust = @customers_map[acc.customer_id] %>
                <% {dpd_label, dpd_cls} = dpd_info(acc.delinquency_bucket || 0) %>
                <tr>
                  <td class="mono" style="font-size:11px;color:var(--text-secondary)">
                    <%= short_id(to_string(acc.account_id)) %>…<br/>
                    <span style="font-size:10px;">****<%= acc.last_four %></span>
                  </td>
                  <td>
                    <%= if cust do %>
                      <div class="fw-600"><%= cust.first_name %> <%= cust.last_name %></div>
                      <div style="font-size:11px;color:var(--text-secondary)"><%= cust.email %></div>
                    <% else %>
                      <span class="text-muted">—</span>
                    <% end %>
                  </td>
                  <td style="font-size:12px;"><%= acc.bank_id %><br/><span class="text-muted"><%= acc.logo_id %></span></td>
                  <td><span class={"badge #{status_cls(acc.account_status)}"}><%= acc.account_status %></span></td>
                  <td>
                    <%= if acc.block_code do %>
                      <span class="badge badge-red"><%= acc.block_code %></span>
                    <% else %>
                      <span class="text-muted">—</span>
                    <% end %>
                  </td>
                  <td><span class={"badge #{dpd_cls}"}><%= dpd_label %></span></td>
                  <td class="mono"><%= money(acc.credit_limit) %></td>
                  <td class="mono"><%= money(acc.open_to_buy) %></td>
                  <td>
                    <button class="btn btn-sm btn-secondary"
                      phx-click="acc_view" phx-value-id={acc.account_id} phx-target={@myself}>
                      View
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  # ── Detail view ──────────────────────────────────────────────────────────────

  defp render_detail(assigns) do
    acc = assigns.account
    pct = util_pct(acc.credit_limit, acc.open_to_buy)

    assigns = assign(assigns, util_pct: pct, util_cls: util_color(pct))

    ~H"""
    <div>
      <%!-- Account header card --%>
      <div class="card" style="margin-bottom:16px;">
        <div style="display:flex;align-items:flex-start;justify-content:space-between;gap:24px;flex-wrap:wrap;">
          <div>
            <div style="font-size:20px;font-weight:700;margin-bottom:4px;">
              <%= if @customer do %>
                <%= @customer.first_name %> <%= @customer.last_name %>
              <% else %>
                Account <%= short_id(to_string(@account.account_id)) %>
              <% end %>
            </div>
            <div style="font-size:12px;color:var(--text-secondary);font-family:monospace;">
              ****&nbsp;<%= @account.last_four %>&nbsp;·&nbsp;exp&nbsp;<%= @account.expiry_date %>
              &nbsp;·&nbsp;ID:&nbsp;<%= short_id(to_string(@account.account_id)) %>…
            </div>
            <%= if @customer do %>
              <div style="font-size:12px;color:var(--text-secondary);margin-top:2px;">
                <%= @customer.email %>&nbsp;·&nbsp;+<%= @customer.mobile_country %>&nbsp;<%= @customer.mobile_number %>
              </div>
            <% end %>
          </div>
          <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;">
            <span class={"badge #{status_cls(@account.account_status)}"}><%= @account.account_status %></span>
            <%= if @account.block_code do %>
              <span class="badge badge-red">BLOCKED — <%= @account.block_code %></span>
            <% end %>
            <% {dpd_label, dpd_cls} = dpd_info(@account.delinquency_bucket || 0) %>
            <span class={"badge #{dpd_cls}"}><%= dpd_label %></span>
          </div>
        </div>

        <%!-- Credit utilization bar --%>
        <div style="margin-top:16px;">
          <div style="display:flex;justify-content:space-between;font-size:12px;color:var(--text-secondary);margin-bottom:4px;">
            <span>Credit Utilization — <%= @util_pct %>%</span>
            <span class="mono">Available: <strong><%= money(@account.open_to_buy) %></strong> / Limit: <%= money(@account.credit_limit) %></span>
          </div>
          <div class="util-bar">
            <div class={"util-fill #{@util_cls}"} style={"width:#{@util_pct}%"}></div>
          </div>
        </div>

        <%!-- Quick action buttons --%>
        <div style="display:flex;gap:8px;margin-top:16px;flex-wrap:wrap;">
          <%= if is_nil(@account.block_code) do %>
            <button class="btn btn-sm btn-danger"
              phx-click="action_open" phx-value-a="apply_block" phx-target={@myself}>
              🔒 Apply Block
            </button>
          <% else %>
            <button class="btn btn-sm btn-secondary"
              phx-click="action_open" phx-value-a="remove_block" phx-target={@myself}>
              🔓 Remove Block
            </button>
          <% end %>
          <button class="btn btn-sm btn-secondary"
            phx-click="action_open" phx-value-a="change_address" phx-target={@myself}>
            📬 Address Change
          </button>
          <button class="btn btn-sm btn-secondary"
            phx-click="action_open" phx-value-a="change_phone" phx-target={@myself}>
            📱 Phone Change
          </button>
          <button class="btn btn-sm btn-secondary"
            phx-click="action_open" phx-value-a="change_email" phx-target={@myself}>
            ✉️ Email Change
          </button>
          <button class="btn btn-sm btn-secondary"
            phx-click="action_open" phx-value-a="change_name" phx-target={@myself}>
            🪪 Emboss Name
          </button>
        </div>
        <div style="display:flex;gap:8px;margin-top:8px;flex-wrap:wrap;padding-top:8px;border-top:1px solid var(--border);">
          <span style="font-size:11px;color:var(--text-muted);align-self:center;font-weight:600;">FINANCIAL:</span>
          <button class="btn btn-sm btn-secondary"
            phx-click="action_open" phx-value-a="perm_limit" phx-target={@myself}>
            📈 Change Limit
          </button>
          <button class="btn btn-sm btn-secondary"
            phx-click="action_open" phx-value-a="temp_limit" phx-target={@myself}>
            ⏳ Temp Limit
          </button>
          <button class="btn btn-sm btn-secondary"
            phx-click="action_open" phx-value-a="fee_waiver" phx-target={@myself}>
            💸 Fee Waiver
          </button>
          <button class="btn btn-sm btn-secondary"
            phx-click="action_open" phx-value-a="fin_adj" phx-target={@myself}>
            ⚖️ Adjustment
          </button>
          <button class="btn btn-sm btn-secondary"
            phx-click="action_open" phx-value-a="link_supp" phx-target={@myself}>
            🔗 Link Supp Card
          </button>
        </div>
      </div>

      <%!-- Action panels --%>
      <%= if @active_action != :none do %>
        <%= render_action_panel(assigns) %>
      <% end %>

      <%!-- Tab navigation --%>
      <div class="card" style="padding:0;overflow:hidden;">
        <div class="detail-tabs">
          <%= for {idx, label, icon} <- [{1,"Overview","📋"},{2,"Balances","💰"},{3,"Cards","💳"},
                                          {4,"Statements","📄"},{5,"History","📜"},{6,"Plans","📊"}] do %>
            <div class={"detail-tab#{if @detail_tab == idx, do: " active"}"}
              phx-click="detail_tab" phx-value-t={idx} phx-target={@myself}>
              <%= icon %> <%= label %>
            </div>
          <% end %>
        </div>
        <div style="padding:20px;">
          <%= case @detail_tab do %>
            <% 1 -> %> <%= tab_overview(assigns) %>
            <% 2 -> %> <%= tab_balances(assigns) %>
            <% 3 -> %> <%= tab_cards(assigns) %>
            <% 4 -> %> <%= tab_statements(assigns) %>
            <% 5 -> %> <%= tab_history(assigns) %>
            <% 6 -> %> <%= tab_plans(assigns) %>
            <% _ -> %> <p>Invalid tab.</p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ── Action panels ─────────────────────────────────────────────────────────────

  defp render_action_panel(%{active_action: :apply_block} = assigns) do
    ~H"""
    <div class="action-panel action-panel-danger" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>🔒 Apply Block Code</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <form phx-submit="acc_block" phx-change="action_change" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">Block Code *</label>
            <select class="input" name="action[block_code]" required>
              <option value="">— Select —</option>
              <%= for {label, val} <- @block_codes do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Reason Code *</label>
            <select class="input" name="action[reason_code]" required>
              <option value="">— Select —</option>
              <%= for {label, val} <- @block_reason_codes do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Free Text (optional)</label>
            <input type="text" class="input" name="action[reason_text]" maxlength="200"
              placeholder="Additional details…"/>
          </div>
          <div class="form-group">
            <label class="form-label">Operator Role</label>
            <select class="input" name="action[operator_role]">
              <%= for {label, val} <- @operator_roles do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group" style="grid-column:1/-1;">
            <label class="form-label">Operator ID (UUID)</label>
            <input type="text" class="input" name="action[operator_id]"
              placeholder="00000000-0000-0000-0000-000000000001"
              style="font-family:monospace;"/>
            <div class="form-hint">Leave blank to use the system default. Will link to auth in Phase 6.</div>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-danger">Apply Block</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp render_action_panel(%{active_action: :remove_block} = assigns) do
    ~H"""
    <div class="action-panel" style="margin-bottom:16px;border-color:#bbf7d0;background:#f0fdf4;">
      <div class="action-panel-title">
        <span>🔓 Remove Block Code <%= @account.block_code %></span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <form phx-submit="acc_unblock" phx-change="action_change" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">Reason Code *</label>
            <select class="input" name="action[reason_code]" required>
              <option value="">— Select —</option>
              <%= for {label, val} <- @unblock_reason_codes do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Operator Role</label>
            <select class="input" name="action[operator_role]">
              <%= for {label, val} <- @operator_roles do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Notes (optional)</label>
            <input type="text" class="input" name="action[reason_text]" maxlength="200"
              placeholder="Reason for removing block…"/>
          </div>
          <div class="form-group">
            <label class="form-label">Operator ID (UUID)</label>
            <input type="text" class="input" name="action[operator_id]"
              placeholder="00000000-0000-0000-0000-000000000001"
              style="font-family:monospace;"/>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-success">Remove Block</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp render_action_panel(%{active_action: act} = assigns)
    when act in [:change_address, :change_phone, :change_email, :change_name] do
    ~H"""
    <div class="action-panel" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>
          <%= case @active_action do
            :change_address -> "📬 Address Change"
            :change_phone   -> "📱 Phone Change"
            :change_email   -> "✉️ Email Change"
            :change_name    -> "🪪 Emboss Name Change"
          end %>
        </span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <form phx-submit="nonmon_save" phx-change="action_change" phx-target={@myself}>
        <input type="hidden" name="action[event_type]" value={
          case @active_action do
            :change_address -> "address_change"
            :change_phone   -> "phone_change"
            :change_email   -> "email_change"
            :change_name    -> "name_change"
          end
        }/>
        <%= if @active_action == :change_address do %>
          <div class="form-grid-2">
            <div class="form-group" style="grid-column:1/-1;">
              <label class="form-label">New Address Line 1 *</label>
              <input type="text" class="input" name="action[new_line1]" required
                value={@customer && @customer.address_line1}/>
            </div>
            <div class="form-group" style="grid-column:1/-1;">
              <label class="form-label">Address Line 2</label>
              <input type="text" class="input" name="action[new_line2]"
                value={@customer && @customer.address_line2}/>
            </div>
            <div class="form-group">
              <label class="form-label">City *</label>
              <input type="text" class="input" name="action[new_city]" required
                value={@customer && @customer.city}/>
            </div>
            <div class="form-group">
              <label class="form-label">Postal Code</label>
              <input type="text" class="input" name="action[new_postal]"
                value={@customer && @customer.postal_code}/>
            </div>
            <div class="form-group">
              <label class="form-label">Country</label>
              <input type="text" class="input" name="action[new_country]"
                value={@customer && @customer.country}/>
            </div>
          </div>
        <% end %>
        <%= if @active_action == :change_phone do %>
          <div class="form-grid-2">
            <div class="form-group">
              <label class="form-label">Country Code</label>
              <input type="text" class="input" name="action[new_mobile_country]"
                value={@customer && @customer.mobile_country} placeholder="971"/>
            </div>
            <div class="form-group">
              <label class="form-label">Mobile Number *</label>
              <input type="text" class="input" name="action[new_mobile_number]" required
                value={@customer && @customer.mobile_number}/>
            </div>
          </div>
        <% end %>
        <%= if @active_action == :change_email do %>
          <div class="form-group">
            <label class="form-label">New Email Address *</label>
            <input type="email" class="input" name="action[new_email]" required
              value={@customer && @customer.email}/>
          </div>
        <% end %>
        <%= if @active_action == :change_name do %>
          <div class="form-group">
            <label class="form-label">New Emboss Name (max 26 chars, will be uppercased) *</label>
            <input type="text" class="input" name="action[new_emboss_name]" required
              maxlength="26" value={@account.emboss_name}/>
          </div>
        <% end %>
        <div class="form-grid-2" style="margin-top:12px;">
          <div class="form-group">
            <label class="form-label">Reason / Notes</label>
            <input type="text" class="input" name="action[reason]" placeholder="Call centre ref or reason…"/>
          </div>
          <div class="form-group">
            <label class="form-label">Reference ID (ticket / call ID)</label>
            <input type="text" class="input" name="action[reference_id]" maxlength="50"/>
          </div>
          <div class="form-group">
            <label class="form-label">Operator ID (UUID)</label>
            <input type="text" class="input" name="action[operator_id]"
              placeholder="00000000-0000-0000-0000-000000000001"
              style="font-family:monospace;"/>
          </div>
          <div class="form-group">
            <label class="form-label">Operator Role</label>
            <select class="input" name="action[operator_role]">
              <%= for {label, val} <- @operator_roles do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-primary">Save Change</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp render_action_panel(%{active_action: :perm_limit} = assigns) do
    ~H"""
    <div class="action-panel action-panel-warning" style="margin-bottom:16px;border-color:#fde68a;background:#fffbeb;">
      <div class="action-panel-title">
        <span>📈 Permanent Credit Limit Change</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <div style="font-size:12px;color:var(--text-secondary);margin-bottom:14px;">
        Current limit: <strong class="mono"><%= money(@account.credit_limit) %></strong>
        &nbsp;·&nbsp; Current OTB: <strong class="mono"><%= money(@account.open_to_buy) %></strong>
        &nbsp;·&nbsp; OTB is adjusted proportionally.
      </div>
      <form phx-submit="perm_limit_save" phx-change="action_change" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">New Credit Limit *</label>
            <input type="number" class="input" name="action[new_limit]" min="0" step="100" required
              placeholder="e.g. 25000"/>
          </div>
          <div class="form-group">
            <label class="form-label">Reason / Reference</label>
            <input type="text" class="input" name="action[reason]" maxlength="100"
              placeholder="Limit review 2026-Q3…"/>
          </div>
          <div class="form-group">
            <label class="form-label">Operator ID (UUID)</label>
            <input type="text" class="input" name="action[operator_id]"
              placeholder="Operator UUID" style="font-family:monospace;"/>
          </div>
          <div class="form-group">
            <label class="form-label">Operator Role</label>
            <select class="input" name="action[operator_role]">
              <%= for {label, val} <- @operator_roles do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-primary">Apply Limit Change</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp render_action_panel(%{active_action: :temp_limit} = assigns) do
    ~H"""
    <div class="action-panel action-panel-warning" style="margin-bottom:16px;border-color:#fde68a;background:#fffbeb;">
      <div class="action-panel-title">
        <span>⏳ Temporary Credit Limit</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <%= if @active_temp_limit do %>
        <div style="background:#fef3c7;border:1px solid #fcd34d;padding:10px 14px;border-radius:6px;font-size:13px;margin-bottom:14px;">
          ⚠️ Active temp limit: <strong><%= money(@active_temp_limit.temp_limit) %></strong>
          until <strong><%= date_s(@active_temp_limit.expiry_date) %></strong>
          (reason: <%= @active_temp_limit.reason %>).
          Granting a new one will supersede this.
        </div>
      <% end %>
      <div style="font-size:12px;color:var(--text-secondary);margin-bottom:14px;">
        Requires 4-eyes: operator and supervisor must be different people.
      </div>
      <form phx-submit="temp_limit_save" phx-change="action_change" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">Temporary Limit *</label>
            <input type="number" class="input" name="action[temp_limit]" min="0" step="100" required
              placeholder="e.g. 30000"/>
          </div>
          <div class="form-group">
            <label class="form-label">Expiry Date *</label>
            <input type="date" class="input" name="action[expiry_date]" required
              min={Date.to_iso8601(Date.add(Date.utc_today(), 1))}/>
          </div>
          <div class="form-group" style="grid-column:1/-1;">
            <label class="form-label">Reason *</label>
            <input type="text" class="input" name="action[reason]" required maxlength="100"
              placeholder="Holiday promo, branch request…"/>
          </div>
          <div class="form-group">
            <label class="form-label">Operator ID *</label>
            <input type="text" class="input" name="action[operator_id]" required
              placeholder="OPS001" style="font-family:monospace;"/>
          </div>
          <div class="form-group">
            <label class="form-label">Supervisor ID * (must differ)</label>
            <input type="text" class="input" name="action[supervisor_id]" required
              placeholder="SUP002" style="font-family:monospace;"/>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-primary">Grant Temp Limit</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp render_action_panel(%{active_action: :fee_waiver} = assigns) do
    ~H"""
    <div class="action-panel" style="margin-bottom:16px;border-color:#a5b4fc;background:#eef2ff;">
      <div class="action-panel-title">
        <span>💸 Fee Waiver</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <div style="font-size:12px;color:var(--text-secondary);margin-bottom:14px;">
        Requires 4-eyes. Select the fee entry to waive, provide reason and approving supervisor.
      </div>
      <form phx-submit="fee_waiver_save" phx-change="action_change" phx-target={@myself}>
        <div class="form-group" style="margin-bottom:14px;">
          <label class="form-label">Select Fee Entry to Waive *</label>
          <%= if @fee_entries == [] do %>
            <div style="font-size:13px;color:var(--text-muted);padding:8px 0;">No FEE ledger entries found for this account.</div>
          <% else %>
            <select class="input" name="action[entry_id]" required>
              <option value="">— Select a fee entry —</option>
              <%= for e <- @fee_entries do %>
                <option value={e.entry_id}>
                  <%= date_s(e.posting_date) %> · <%= money(e.dr_amount) %> · <%= e.narrative || e.idempotency_key %>
                </option>
              <% end %>
            </select>
          <% end %>
        </div>
        <div class="form-grid-2">
          <div class="form-group" style="grid-column:1/-1;">
            <label class="form-label">Reason * (max 100 chars)</label>
            <input type="text" class="input" name="action[reason]" required maxlength="100"
              placeholder="First-time waiver — customer paid within 48h…"/>
          </div>
          <div class="form-group">
            <label class="form-label">Operator ID *</label>
            <input type="text" class="input" name="action[operator_id]" required
              placeholder="OPS001" style="font-family:monospace;"/>
          </div>
          <div class="form-group">
            <label class="form-label">Supervisor ID * (must differ)</label>
            <input type="text" class="input" name="action[supervisor_id]" required
              placeholder="SUP002" style="font-family:monospace;"/>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-primary" disabled={@fee_entries == []}>Apply Fee Waiver</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp render_action_panel(%{active_action: :fin_adj} = assigns) do
    ~H"""
    <div class="action-panel" style="margin-bottom:16px;border-color:#c4b5fd;background:#f5f3ff;">
      <div class="action-panel-title">
        <span>⚖️ Financial Adjustment</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <div style="font-size:12px;color:var(--text-secondary);margin-bottom:14px;">
        Requires 4-eyes. <strong>Credit</strong> reduces balance (goodwill credit, correction). <strong>Debit</strong> increases balance (recoverable chargeback, error correction).
      </div>
      <form phx-submit="fin_adj_save" phx-change="action_change" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">Direction *</label>
            <select class="input" name="action[direction]" required>
              <option value="credit">CREDIT — reduce balance</option>
              <option value="debit">DEBIT — increase balance</option>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Amount *</label>
            <input type="number" class="input" name="action[amount]" min="0.01" step="0.01" required
              placeholder="e.g. 150.00"/>
          </div>
          <div class="form-group" style="grid-column:1/-1;">
            <label class="form-label">Reason * (max 100 chars)</label>
            <input type="text" class="input" name="action[reason]" required maxlength="100"
              placeholder="Goodwill credit — call centre CAS-1234"/>
          </div>
          <div class="form-group" style="grid-column:1/-1;">
            <label class="form-label">Reference ID (case / ticket number) *</label>
            <input type="text" class="input" name="action[reference_id]" required maxlength="50"
              placeholder="CAS-1234 or TKT-5678"/>
          </div>
          <div class="form-group">
            <label class="form-label">Operator ID *</label>
            <input type="text" class="input" name="action[operator_id]" required
              placeholder="OPS001" style="font-family:monospace;"/>
          </div>
          <div class="form-group">
            <label class="form-label">Supervisor ID * (must differ)</label>
            <input type="text" class="input" name="action[supervisor_id]" required
              placeholder="SUP002" style="font-family:monospace;"/>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-primary">Post Adjustment</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp render_action_panel(%{active_action: :link_supp} = assigns) do
    ~H"""
    <div class="action-panel" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>🔗 Link Supplementary Card</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <div style="font-size:12px;color:var(--text-secondary);margin-bottom:14px;">
        Search for an existing account in the same bank to link as a supplementary card. Balances will accrue to this primary account.
      </div>
      <div style="margin-bottom:12px;">
        <input type="text" class="input" style="width:100%;max-width:420px;"
          placeholder="Search by last 4 digits or cardholder name…"
          value={@supp_search}
          phx-keyup="supp_search" phx-debounce="300"
          phx-value-q={@supp_search} phx-target={@myself}/>
      </div>
      <%= if @supp_search_results != [] do %>
        <div class="table-wrap" style="margin-bottom:12px;">
          <table class="data-table">
            <thead><tr><th>Account ID</th><th>Cardholder</th><th>Last 4</th><th>Status</th></tr></thead>
            <tbody>
              <%= for a <- @supp_search_results do %>
                <tr>
                  <td class="mono" style="font-size:11px;"><%= short_id(to_string(a.account_id)) %>…</td>
                  <td><%= a.customer_name %></td>
                  <td class="mono">****<%= a.last_four %></td>
                  <td><span class={"badge #{status_cls(a.account_status)}"}><%= a.account_status %></span></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
      <form phx-submit="supp_card_link" phx-change="action_change" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group" style="grid-column:1/-1;">
            <label class="form-label">Supplementary Account ID (paste from search above) *</label>
            <input type="text" class="input" name="action[supp_account_id]" required
              placeholder="UUID of the supplementary account"
              style="font-family:monospace;"/>
          </div>
          <div class="form-group">
            <label class="form-label">Sub-limit (optional)</label>
            <input type="number" class="input" name="action[sub_limit]"
              min="0" step="100" placeholder="Leave blank to share primary OTB"/>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-primary">Link Supplementary Card</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  # ── Card action panels (CTA-P3) ────────────────────────────────────────────────

  defp render_action_panel(%{active_action: :card_activate} = assigns) do
    assigns = assign(assigns, card: selected_card(assigns))

    ~H"""
    <div class="action-panel" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>✅ Activate Card — Gen <%= @card && @card.generation %> (**** <%= @card && @card.last_four %>)</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <form phx-submit="card_activate_save" phx-target={@myself}>
        <div class="form-group">
          <label class="form-label">Activation Method</label>
          <select class="input" name="method">
            <option value="admin">Admin (ops console)</option>
            <option value="ivr">IVR (phone)</option>
            <option value="first_use">First use</option>
            <option value="app">Mobile app</option>
          </select>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-primary">Activate</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp render_action_panel(%{active_action: :card_block} = assigns) do
    assigns = assign(assigns, card: selected_card(assigns))

    ~H"""
    <div class="action-panel action-panel-danger" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>🔒 Block Card — Gen <%= @card && @card.generation %> (**** <%= @card && @card.last_four %>)</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <form phx-submit="card_block_save" phx-target={@myself}>
        <div class="form-group">
          <label class="form-label">Reason *</label>
          <select class="input" name="reason" required>
            <option value="">— Select —</option>
            <%= for {label, val} <- @card_block_reasons do %>
              <option value={val}><%= label %></option>
            <% end %>
          </select>
        </div>
        <div class="form-hint">
          Lost/Stolen/Fraud also blocks the account (hot-card list) — the account
          resumes normal auth once this card is replaced or unblocked.
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-danger">Block Card</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp render_action_panel(%{active_action: :card_unblock} = assigns) do
    assigns = assign(assigns, card: selected_card(assigns))

    ~H"""
    <div class="action-panel" style="margin-bottom:16px;border-color:#bbf7d0;background:#f0fdf4;">
      <div class="action-panel-title">
        <span>🔓 Unblock Card — Gen <%= @card && @card.generation %> (**** <%= @card && @card.last_four %>)</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <p style="font-size:12px;color:var(--text-secondary);">
        Currently blocked for: <strong><%= @card && @card.block_reason %></strong>
      </p>
      <form phx-submit="card_unblock_save" phx-target={@myself}>
        <div style="display:flex;gap:8px;">
          <button type="submit" class="btn btn-primary">Unblock Card</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp render_action_panel(%{active_action: :card_replace} = assigns) do
    assigns = assign(assigns, card: selected_card(assigns))

    ~H"""
    <div class="action-panel action-panel-danger" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>♻️ Replace Card — Gen <%= @card && @card.generation %> (**** <%= @card && @card.last_four %>)</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <form phx-submit="card_replace_save" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">Reason *</label>
            <select class="input" name="reason" required>
              <option value="">— Select —</option>
              <%= for {label, val} <- @card_block_reasons, val != "ADMIN" do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">
              <input type="checkbox" name="waive_fee" value="true"/> Waive replacement fee
            </label>
          </div>
        </div>
        <div class="form-hint">
          Lost / Stolen / Fraud issue a brand-new card number (the old number can
          never be reused). Damaged keeps the existing number. Fraud never
          charges a replacement fee.
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-danger">Replace Card</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp render_action_panel(%{active_action: :card_renew} = assigns) do
    assigns = assign(assigns, card: selected_card(assigns))

    ~H"""
    <div class="action-panel" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>🔄 Renew Card — Gen <%= @card && @card.generation %> (**** <%= @card && @card.last_four %>, expires <%= @card && @card.expiry %>)</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <form phx-submit="card_renew_save" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">Validity (years)</label>
            <select class="input" name="years">
              <option value="1">1</option>
              <option value="2">2</option>
              <option value="3" selected>3</option>
              <option value="5">5</option>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">
              <input type="checkbox" name="activate" value="true"/> Activate immediately (seamless swap)
            </label>
          </div>
        </div>
        <div class="form-hint">Same card number, no replacement fee.</div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-primary">Renew Card</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp render_action_panel(%{active_action: :card_channels} = assigns) do
    assigns = assign(assigns, card: selected_card(assigns))

    ~H"""
    <div class="action-panel" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>📶 Channel Controls — Gen <%= @card && @card.generation %> (**** <%= @card && @card.last_four %>)</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <div class="form-hint" style="margin-bottom:10px;">
        Overrides the product's channel defaults for this card only. "Inherit" restores normal product behavior.
      </div>
      <form phx-submit="card_channels_save" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">E-Commerce</label>
            <select class="input" name="ecom_enabled">
              <%= for {label, val} <- @tri_state do %>
                <option value={val} selected={tri_selected(@card && @card.ecom_enabled, val)}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">ATM</label>
            <select class="input" name="atm_enabled">
              <%= for {label, val} <- @tri_state do %>
                <option value={val} selected={tri_selected(@card && @card.atm_enabled, val)}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Contactless</label>
            <select class="input" name="contactless_enabled">
              <%= for {label, val} <- @tri_state do %>
                <option value={val} selected={tri_selected(@card && @card.contactless_enabled, val)}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">International</label>
            <select class="input" name="intl_enabled">
              <%= for {label, val} <- @tri_state do %>
                <option value={val} selected={tri_selected(@card && @card.intl_enabled, val)}><%= label %></option>
              <% end %>
            </select>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-primary">Save Channel Controls</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp render_action_panel(assigns), do: ~H""

  # ── Tabs ─────────────────────────────────────────────────────────────────────

  defp tab_overview(assigns) do
    acc  = assigns.account
    cust = assigns.customer
    assigns = assign(assigns, acc: acc, cust: cust)

    ~H"""
    <div class="form-grid-2">
      <div>
        <div class="form-pane-section-title">Account Details</div>
        <table style="width:100%;border-collapse:collapse;font-size:13px;">
          <tr><td class="kv-key">Account ID</td><td class="mono kv-val"><%= @acc.account_id %></td></tr>
          <tr><td class="kv-key">Bank / Logo / Block</td><td class="kv-val"><%= @acc.bank_id %> / <%= @acc.logo_id %> / <%= @acc.block_id %></td></tr>
          <tr><td class="kv-key">Status</td><td class="kv-val"><span class={"badge #{status_cls(@acc.account_status)}"}><%= @acc.account_status %></span></td></tr>
          <tr><td class="kv-key">Open Date</td><td class="kv-val"><%= date_s(@acc.open_date) %></td></tr>
          <tr><td class="kv-key">Billing Cycle</td><td class="kv-val">Day <%= @acc.cycle_code %> of month</td></tr>
          <tr><td class="kv-key">Next Statement</td><td class="kv-val"><%= date_s(@acc.next_statement_date) %></td></tr>
          <tr><td class="kv-key">Last Payment</td><td class="kv-val"><%= date_s(@acc.last_payment_date) %></td></tr>
          <tr><td class="kv-key">Campaign</td><td class="kv-val"><%= @acc.campaign_code || "—" %></td></tr>
        </table>
      </div>
      <div>
        <div class="form-pane-section-title">Card Details</div>
        <table style="width:100%;border-collapse:collapse;font-size:13px;">
          <tr><td class="kv-key">Emboss Name</td><td class="kv-val mono"><%= @acc.emboss_name || "—" %></td></tr>
          <tr><td class="kv-key">Last 4 Digits</td><td class="kv-val mono">****&nbsp;<%= @acc.last_four %></td></tr>
          <tr><td class="kv-key">Expiry (MMYY)</td><td class="kv-val mono"><%= @acc.expiry_date %></td></tr>
          <tr><td class="kv-key">Block Code</td>
            <td class="kv-val">
              <%= if @acc.block_code do %>
                <span class="badge badge-red"><%= @acc.block_code %></span>
                <span style="font-size:11px;margin-left:6px;color:var(--text-secondary)"><%= @acc.block_reason %></span>
              <% else %>
                <span class="text-muted">None</span>
              <% end %>
            </td>
          </tr>
          <tr><td class="kv-key">Blocked At</td><td class="kv-val"><%= date_s(@acc.blocked_at) %></td></tr>
        </table>

        <%= if @cust do %>
          <div class="form-pane-section-title" style="margin-top:20px;">Customer Info</div>
          <table style="width:100%;border-collapse:collapse;font-size:13px;">
            <tr><td class="kv-key">Full Name</td><td class="kv-val"><%= @cust.first_name %> <%= @cust.last_name %></td></tr>
            <tr><td class="kv-key">Email</td><td class="kv-val"><%= @cust.email %></td></tr>
            <tr><td class="kv-key">Phone</td><td class="kv-val">+<%= @cust.mobile_country %> <%= @cust.mobile_number %></td></tr>
            <tr><td class="kv-key">KYC Status</td>
              <td class="kv-val">
                <span class={"badge #{if @cust.kyc_status == "VERIFIED", do: "badge-green", else: "badge-yellow"}"}><%= @cust.kyc_status %></span>
              </td>
            </tr>
            <tr><td class="kv-key">Tier</td><td class="kv-val"><%= @cust.customer_tier %></td></tr>
          </table>
        <% end %>
      </div>
    </div>
    """
  end

  defp tab_balances(assigns) do
    ~H"""
    <%= if @balance_bucket do %>
      <% b = @balance_bucket %>
      <div class="form-grid-2">
        <div>
          <div class="form-pane-section-title">Principal Balances</div>
          <div class="balance-row"><span class="balance-key">Retail Balance</span><span class="balance-val mono"><%= money(b.retail_balance) %></span></div>
          <div class="balance-row"><span class="balance-key">Cash Advance</span><span class="balance-val mono"><%= money(b.cash_balance) %></span></div>
          <div class="balance-row"><span class="balance-key">Balance Transfer</span><span class="balance-val mono"><%= money(b.bt_balance) %></span></div>
          <div class="balance-row"><span class="balance-key">EMI Outstanding</span><span class="balance-val mono"><%= money(b.emi_balance) %></span></div>

          <div class="form-pane-section-title" style="margin-top:20px;">Charges & Fees</div>
          <div class="balance-row"><span class="balance-key">Accrued Interest</span><span class="balance-val mono"><%= money(b.accrued_interest) %></span></div>
          <div class="balance-row"><span class="balance-key">Unpaid Fees</span><span class="balance-val mono"><%= money(b.unpaid_fees) %></span></div>
          <div class="balance-row"><span class="balance-key">Disputed Amount</span><span class="balance-val mono"><%= money(b.disputed_amount) %></span></div>
        </div>
        <div>
          <div class="form-pane-section-title">Statement Position</div>
          <div class="balance-row"><span class="balance-key">Statement Balance</span><span class="balance-val mono balance-total"><%= money(b.statement_balance) %></span></div>
          <div class="balance-row"><span class="balance-key">Minimum Payment Due</span><span class="balance-val mono"><%= money(b.minimum_payment) %></span></div>
          <div class="balance-row"><span class="balance-key">Balance Date</span><span class="balance-val"><%= date_s(b.balance_date) %></span></div>
          <div class="balance-row"><span class="balance-key">Currency</span><span class="balance-val"><%= b.currency %></span></div>

          <div class="form-pane-section-title" style="margin-top:20px;">Credit Position</div>
          <div class="balance-row"><span class="balance-key">Credit Limit</span><span class="balance-val mono balance-total"><%= money(@account.credit_limit) %></span></div>
          <div class="balance-row"><span class="balance-key">Open to Buy</span><span class="balance-val mono"><%= money(@account.open_to_buy) %></span></div>
          <div class="balance-row"><span class="balance-key">Cash Limit</span><span class="balance-val mono"><%= money(@account.cash_limit) %></span></div>
          <div class="balance-row"><span class="balance-key">Cash Open to Buy</span><span class="balance-val mono"><%= money(@account.cash_open_to_buy) %></span></div>
        </div>
      </div>
    <% else %>
      <div class="empty-row" style="padding:40px;text-align:center;">No balance bucket found for this account.</div>
    <% end %>

    <%!-- Active temp limit banner --%>
    <%= if @active_temp_limit do %>
      <% tl = @active_temp_limit %>
      <div style="margin-top:20px;background:#fef3c7;border:1px solid #fcd34d;padding:12px 16px;border-radius:8px;font-size:13px;">
        <div style="font-weight:600;margin-bottom:4px;">⏳ Active Temporary Limit</div>
        <div style="display:flex;gap:20px;flex-wrap:wrap;">
          <span>Temp Limit: <strong class="mono"><%= money(tl.temp_limit) %></strong></span>
          <span>Original: <span class="mono"><%= money(tl.original_limit) %></span></span>
          <span>Expires: <strong><%= date_s(tl.expiry_date) %></strong></span>
          <span>Reason: <em><%= tl.reason %></em></span>
        </div>
      </div>
    <% end %>

    <%!-- Recent adjustments --%>
    <%= if @adj_entries != [] do %>
      <div class="form-pane-section-title" style="margin-top:20px;">Recent Adjustments (<%= length(@adj_entries) %>)</div>
      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>Date</th><th>Direction</th><th>Amount</th><th>Narrative</th><th>Ref</th></tr></thead>
          <tbody>
            <%= for e <- @adj_entries do %>
              <tr>
                <td><%= date_s(e.posting_date) %></td>
                <td>
                  <%= if Decimal.compare(e.dr_amount, Decimal.new(0)) == :gt and e.gl_account_dr == "1001" do %>
                    <span class="badge badge-red">DEBIT</span>
                  <% else %>
                    <span class="badge badge-green">CREDIT</span>
                  <% end %>
                </td>
                <td class="mono"><%= money(e.dr_amount) %></td>
                <td style="font-size:12px;max-width:240px;overflow:hidden;text-overflow:ellipsis;"><%= e.narrative %></td>
                <td style="font-size:11px;color:var(--text-secondary);"><%= e.source_ref %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% end %>
    """
  end

  defp tab_cards(assigns) do
    ~H"""
    <div>
      <div class="form-pane-section-title">
        Cards (<%= length(@cards) %> generation<%= if length(@cards) != 1, do: "s" %>)
      </div>

      <%= if @active_action in [:card_activate, :card_block, :card_unblock, :card_replace, :card_renew, :card_channels] do %>
        <%= render_action_panel(assigns) %>
      <% end %>

      <%= if @cards == [] do %>
        <div class="empty-row" style="padding:20px;text-align:center;">No card issued yet.</div>
      <% else %>
        <div class="table-wrap">
          <table class="data-table">
            <thead>
              <tr>
                <th>Gen</th><th>Type</th><th>PAN</th><th>Emboss Name</th><th>Expiry</th>
                <th>Status</th><th>Channels</th><th>Issued</th><th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for c <- @cards do %>
                <tr>
                  <td class="mono"><%= c.generation %></td>
                  <td><%= c.card_type %></td>
                  <td class="mono">**** <%= c.last_four || "----" %></td>
                  <td><%= c.emboss_name || "—" %></td>
                  <td class="mono"><%= c.expiry || "—" %></td>
                  <td><span class={"badge #{card_status_cls(c.status)}"}><%= c.status %></span>
                    <%= if c.block_reason do %>
                      <div style="font-size:10px;color:var(--text-muted);"><%= c.block_reason %></div>
                    <% end %>
                  </td>
                  <td style="font-size:10px;">
                    <span title="E-Commerce"><%= channel_dot("E", c.ecom_enabled) %></span>
                    <span title="ATM"><%= channel_dot("A", c.atm_enabled) %></span>
                    <span title="Contactless"><%= channel_dot("C", c.contactless_enabled) %></span>
                    <span title="International"><%= channel_dot("I", c.intl_enabled) %></span>
                  </td>
                  <td><%= date_s(c.issued_at) %></td>
                  <td>
                    <div class="actions" style="display:flex;flex-wrap:wrap;gap:4px;">
                      <%= if c.status == "INACTIVE" do %>
                        <button class="btn btn-xs" phx-click="card_action_open"
                          phx-value-a="card_activate" phx-value-id={c.card_id} phx-target={@myself}>Activate</button>
                      <% end %>
                      <%= if c.status == "ACTIVE" do %>
                        <button class="btn btn-xs btn-danger" phx-click="card_action_open"
                          phx-value-a="card_block" phx-value-id={c.card_id} phx-target={@myself}>Block</button>
                        <button class="btn btn-xs" phx-click="card_action_open"
                          phx-value-a="card_channels" phx-value-id={c.card_id} phx-target={@myself}>Channels</button>
                      <% end %>
                      <%= if c.status == "BLOCKED" do %>
                        <button class="btn btn-xs btn-success" phx-click="card_action_open"
                          phx-value-a="card_unblock" phx-value-id={c.card_id} phx-target={@myself}>Unblock</button>
                      <% end %>
                      <%= if c.status in ["ACTIVE", "BLOCKED", "EXPIRED"] do %>
                        <button class="btn btn-xs" phx-click="card_action_open"
                          phx-value-a="card_replace" phx-value-id={c.card_id} phx-target={@myself}>Replace</button>
                        <button class="btn btn-xs" phx-click="card_action_open"
                          phx-value-a="card_renew" phx-value-id={c.card_id} phx-target={@myself}>Renew</button>
                      <% end %>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>

      <div class="form-pane-section-title" style="margin-top:20px;">
        Supplementary Cards (<%= length(@supp_cards) %>)
      </div>
      <%= if @supp_cards == [] do %>
        <div class="empty-row" style="padding:20px;text-align:center;">No supplementary cards issued.</div>
      <% else %>
        <div class="table-wrap">
          <table class="data-table">
            <thead>
              <tr><th>Supp Account ID</th><th>Type</th><th>Sub-Limit</th><th>Activated</th><th>Status</th></tr>
            </thead>
            <tbody>
              <%= for sc <- @supp_cards do %>
                <tr>
                  <td class="mono" style="font-size:11px;"><%= short_id(to_string(sc.supplementary_account_id)) %>…</td>
                  <td>SUPPLEMENTARY</td>
                  <td class="mono"><%= if sc.sub_limit, do: money(sc.sub_limit), else: "Shared" %></td>
                  <td><%= date_s(sc.activated_at) %></td>
                  <td><span class={"badge #{status_cls(sc.status || "ACTIVE")}"}><%= sc.status || "ACTIVE" %></span></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>

      <div class="form-pane-section-title" style="margin-top:20px;">
        Card Event History (<%= length(@card_events) %>)
      </div>
      <%= if @card_events == [] do %>
        <div class="empty-row" style="padding:20px;text-align:center;">No card events recorded yet.</div>
      <% else %>
        <div class="timeline">
          <%= for e <- @card_events do %>
            <div class="timeline-item">
              <div class={"timeline-dot #{card_event_dot(e.action)}"}></div>
              <div class="timeline-content">
                <div class="timeline-label">
                  <%= card_event_label(e.action) %>
                  &nbsp;<span class="badge badge-gray" style="font-size:10px;">card <%= short_id(e.subject) %>…</span>
                </div>
                <div class="timeline-meta">
                  <%= date_s(e.performed_at) %>
                  &nbsp;·&nbsp;By: <%= e.operator_id %>
                  &nbsp;·&nbsp;<span style="font-size:10px;"><%= e.details %></span>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp tab_statements(assigns) do
    ~H"""
    <div>
      <div class="form-pane-section-title">Statement History (last 12 billing cycles)</div>
      <%= if @statements == [] do %>
        <div class="empty-row" style="padding:40px;text-align:center;color:var(--text-secondary);">
          <div style="font-size:28px;margin-bottom:8px;">📄</div>
          No statement history yet — statements are generated on each billing cycle date.
        </div>
      <% else %>
        <div class="table-wrap">
          <table class="data-table">
            <colgroup>
              <col style="width:110px"/>
              <col style="width:120px"/>
              <col style="width:100px"/>
              <col style="width:100px"/>
              <col style="width:100px"/>
              <col style="width:100px"/>
              <col style="width:100px"/>
              <col style="width:100px"/>
            </colgroup>
            <thead>
              <tr>
                <th>Billing Date</th>
                <th>Stmt Balance</th>
                <th>Retail</th>
                <th>Cash</th>
                <th>EMI</th>
                <th>BT</th>
                <th>Interest</th>
                <th>Fees</th>
                <th>Min Due</th>
              </tr>
            </thead>
            <tbody>
              <%= for s <- @statements do %>
                <tr>
                  <td class="mono"><%= date_s(s.balance_date) %></td>
                  <td class="mono fw-600"><%= money(s.statement_balance) %></td>
                  <td class="mono"><%= money(s.retail_balance) %></td>
                  <td class="mono"><%= money(s.cash_balance) %></td>
                  <td class="mono"><%= money(s.emi_balance) %></td>
                  <td class="mono"><%= money(s.bt_balance) %></td>
                  <td class="mono"><%= money(s.accrued_interest) %></td>
                  <td class="mono"><%= money(s.unpaid_fees) %></td>
                  <td class="mono"><%= money(s.minimum_payment) %></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  defp tab_history(assigns) do
    all_events =
      Enum.map(assigns.block_history, fn h ->
        %{at: h.applied_at, type: :block, data: h}
      end) ++
      Enum.map(assigns.nonmon_events, fn e ->
        %{at: e.applied_at, type: :nonmon, data: e}
      end)
      |> Enum.sort_by(& &1.at, {:desc, NaiveDateTime})

    assigns = assign(assigns, all_events: all_events)

    ~H"""
    <div>
      <div class="form-pane-section-title">Account History (<%= length(@all_events) %> events)</div>
      <%= if @all_events == [] do %>
        <div class="empty-row" style="padding:40px;text-align:center;">No events recorded yet.</div>
      <% else %>
        <div class="timeline">
          <%= for ev <- @all_events do %>
            <%= if ev.type == :block do %>
              <% h = ev.data %>
              <div class="timeline-item">
                <div class={"timeline-dot #{block_dot(h.action)}"}></div>
                <div class="timeline-content">
                  <div class="timeline-label">
                    <%= h.action %> — Block Code <%= h.block_code || "—" %>
                    &nbsp;<span class="badge badge-gray" style="font-size:10px;"><%= h.reason_code %></span>
                  </div>
                  <div class="timeline-meta">
                    <%= date_s(h.applied_at) %>
                    &nbsp;·&nbsp;Role: <%= h.operator_role %>
                    <%= if h.reason_text && h.reason_text != "" do %>
                      &nbsp;·&nbsp;<em><%= h.reason_text %></em>
                    <% end %>
                  </div>
                </div>
              </div>
            <% else %>
              <% e = ev.data %>
              <div class="timeline-item">
                <div class={"timeline-dot #{event_dot(e.event_type)}"}></div>
                <div class="timeline-content">
                  <div class="timeline-label">
                    <%= etype_label(e.event_type) %>
                    <%= if e.reference_id do %>
                      &nbsp;<span class="badge badge-gray" style="font-size:10px;">ref: <%= e.reference_id %></span>
                    <% end %>
                  </div>
                  <div class="timeline-meta">
                    <%= date_s(e.applied_at) %>
                    &nbsp;·&nbsp;Role: <%= e.operator_role %>
                    <%= if e.reason && e.reason != "" do %>
                      &nbsp;·&nbsp;<em><%= e.reason %></em>
                    <% end %>
                  </div>
                  <%= if e.new_value do %>
                    <div style="font-size:11px;margin-top:3px;color:var(--text-secondary);">
                      → <%= Enum.map_join(e.new_value, ", ", fn {k, v} -> "#{k}: #{v}" end) %>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp tab_plans(assigns) do
    ~H"""
    <div>
      <%!-- Plan segments (inherited from LOGO) --%>
      <div class="form-pane-section-title">Plan Segments for Logo <%= @account.logo_id %></div>
      <%= if @plans == [] do %>
        <div class="empty-row" style="padding:24px;text-align:center;color:var(--text-secondary);">
          No plan segments configured for this logo.
          Manage plans from the Products / Logos admin screen.
        </div>
      <% else %>
        <div class="table-wrap" style="margin-bottom:24px;">
          <table class="data-table">
            <colgroup>
              <col style="width:90px"/>
              <col style="width:140px"/>
              <col style="width:80px"/>
              <col style="width:80px"/>
              <col style="width:110px"/>
              <col style="width:60px"/>
              <col style="width:110px"/>
              <col style="width:70px"/>
              <col style="width:70px"/>
            </colgroup>
            <thead>
              <tr>
                <th>Plan ID</th>
                <th>Type</th>
                <th>APR</th>
                <th>Promo APR</th>
                <th>Promo Expiry</th>
                <th>Grace</th>
                <th>Min Payment %</th>
                <th>Priority</th>
                <th>Active</th>
              </tr>
            </thead>
            <tbody>
              <%= for p <- @plans do %>
                <% eff_apr = PlanSegment.effective_apr(p) %>
                <tr>
                  <td class="mono fw-600"><%= p.plan_id %></td>
                  <td><span class={"badge #{plan_type_badge(p.plan_type)}"}><%= p.plan_type %></span></td>
                  <td class="mono"><%= money(eff_apr) %>%</td>
                  <td class="mono"><%= if p.promo_apr, do: "#{money(p.promo_apr)}%", else: "—" %></td>
                  <td><%= date_s(p.promo_expiry_date) %></td>
                  <td><%= if p.grace_eligible, do: "✓", else: "✗" %></td>
                  <td class="mono"><%= if p.min_payment_pct, do: "#{money(p.min_payment_pct)}%", else: "—" %></td>
                  <td><%= p.payment_priority %></td>
                  <td><%= if p.active, do: "✓", else: "✗" %></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>

      <%!-- EMI Schedule (per account) --%>
      <div class="form-pane-section-title" style="margin-top:8px;">EMI Instalment Schedule</div>
      <%= if @emi_schedules == [] do %>
        <div class="empty-row" style="padding:24px;text-align:center;color:var(--text-secondary);">
          No active EMI plans on this account.
        </div>
      <% else %>
        <div class="table-wrap">
          <table class="data-table">
            <colgroup>
              <col style="width:80px"/>
              <col style="width:90px"/>
              <col style="width:100px"/>
              <col style="width:100px"/>
              <col style="width:100px"/>
              <col style="width:100px"/>
              <col style="width:100px"/>
              <col style="width:110px"/>
            </colgroup>
            <thead>
              <tr>
                <th>#</th>
                <th>Plan</th>
                <th>Due Date</th>
                <th>Principal</th>
                <th>Interest</th>
                <th>Instalment</th>
                <th>Outstanding</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              <%= for s <- @emi_schedules do %>
                <tr>
                  <td class="mono"><%= s.instalment_no %> / <%= s.tenor_total %></td>
                  <td class="mono"><%= s.plan_id %></td>
                  <td class="mono"><%= date_s(s.due_date) %></td>
                  <td class="mono"><%= money(s.principal_due) %></td>
                  <td class="mono"><%= money(s.interest_due) %></td>
                  <td class="mono fw-600"><%= money(s.instalment_due) %></td>
                  <td class="mono"><%= money(s.outstanding) %></td>
                  <td><span class={"badge #{emi_status_badge(s.status)}"}><%= s.status %></span></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Wizard ───────────────────────────────────────────────────────────────────

  defp render_wizard(assigns) do
    ~H"""
    <div class="card">
      <div style="font-size:16px;font-weight:700;margin-bottom:20px;">Open New Account — Step <%= @wizard_step %> of 5</div>

      <%!-- Step progress bar --%>
      <div style="display:flex;gap:4px;margin-bottom:24px;">
        <%= for {s, label} <- [{1,"Customer"},{2,"Product"},{3,"Card & Credit"},{4,"Config"},{5,"Review"}] do %>
          <div style={"flex:1;padding:6px 8px;text-align:center;font-size:12px;font-weight:600;border-radius:4px;cursor:pointer;
            background:#{if s <= @wizard_step, do: "var(--accent)", else: "var(--bg-canvas)"};
            color:#{if s <= @wizard_step, do: "#fff", else: "var(--text-secondary)"};"}
            phx-click={if s < @wizard_step, do: "wizard_step"} phx-value-s={s} phx-target={@myself}>
            <%= s %>. <%= label %>
          </div>
        <% end %>
      </div>

      <%= case @wizard_step do %>
        <% 1 -> %> <%= wizard_step1(assigns) %>
        <% 2 -> %> <%= wizard_step2(assigns) %>
        <% 3 -> %> <%= wizard_step3(assigns) %>
        <% 4 -> %> <%= wizard_step4(assigns) %>
        <% 5 -> %> <%= wizard_step5(assigns) %>
        <% _ -> %> <p>Invalid step.</p>
      <% end %>
    </div>
    """
  end

  defp wizard_step1(assigns) do
    ~H"""
    <div>
      <div class="form-pane-section-title">Step 1 — Select Customer</div>

      <%= if @form_data["customer_id"] do %>
        <div style="background:#f0fdf4;border:1px solid #bbf7d0;padding:12px 16px;border-radius:8px;margin-bottom:16px;display:flex;justify-content:space-between;align-items:center;">
          <div>
            <div style="font-weight:600;"><%= @form_data["customer_name"] %></div>
            <div style="font-size:12px;color:var(--text-secondary);">
              Bank: <%= @form_data["bank_id"] %> · KYC: <%= @form_data["kyc_status"] %>
            </div>
          </div>
          <button class="btn btn-sm btn-ghost"
            phx-click="wizard_step" phx-value-s="1" phx-target={@myself}>Change</button>
        </div>
        <div style="display:flex;justify-content:flex-end;">
          <button class="btn btn-primary"
            phx-click="wizard_step" phx-value-s="2" phx-target={@myself}>
            Next: Select Product →
          </button>
        </div>
      <% else %>
        <div style="margin-bottom:12px;">
          <input type="text"
            class="input"
            placeholder="Search by name, email, or mobile…"
            value={@customer_search}
            phx-keyup="cust_search_wizard"
            phx-debounce="300"
            phx-value-q={@customer_search}
            phx-target={@myself}
            style="width:100%;max-width:480px;"
          />
        </div>

        <%= if @customer_results != [] do %>
          <div class="table-wrap">
            <table class="data-table">
              <thead>
                <tr><th>Name</th><th>Email</th><th>Bank</th><th>KYC</th><th></th></tr>
              </thead>
              <tbody>
                <%= for c <- @customer_results do %>
                  <tr>
                    <td><%= c.first_name %> <%= c.last_name %></td>
                    <td style="font-size:12px;"><%= c.email %></td>
                    <td><%= c.bank_id %></td>
                    <td><span class={"badge #{if c.kyc_status == "VERIFIED", do: "badge-green", else: "badge-yellow"}"}><%= c.kyc_status %></span></td>
                    <td>
                      <button class="btn btn-sm btn-primary"
                        phx-click="select_customer" phx-value-id={c.customer_id} phx-target={@myself}>
                        Select
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>

        <%= if @customer_search != "" && @customer_results == [] do %>
          <div class="empty-row" style="padding:20px;text-align:center;">No customers found. Try a different search.</div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp wizard_step2(assigns) do
    ~H"""
    <div>
      <div class="form-pane-section-title">Step 2 — Select Product (LOGO + BLOCK)</div>
      <form phx-change="wizard_change" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">Logo (Product) *</label>
            <select class="input" name="acc[logo_id]" required>
              <option value="">— Select Logo —</option>
              <%= for l <- @logos_for_bank do %>
                <option value={l.logo_id} selected={@form_data["logo_id"] == l.logo_id}>
                  <%= l.logo_id %> — <%= l.description || l.logo_id %>
                </option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Block (Sub-product) *</label>
            <select class="input" name="acc[block_id]">
              <option value="DFLT">DFLT — Default Block</option>
              <%= for b <- @blocks_for_logo do %>
                <option value={b.block_id} selected={@form_data["block_id"] == b.block_id}>
                  <%= b.block_id %> — <%= b.description || b.block_id %>
                </option>
              <% end %>
            </select>
          </div>
        </div>
      </form>

      <%= if @selected_logo do %>
        <div style="background:#f8faff;border:1px solid var(--border);padding:12px 16px;border-radius:8px;font-size:13px;margin-top:8px;">
          <div style="font-weight:600;margin-bottom:6px;">Logo Defaults</div>
          <div style="display:flex;gap:24px;flex-wrap:wrap;">
            <span>APR: <strong><%= money(@selected_logo.apr) %>%</strong></span>
            <span>Annual Fee: <strong><%= money(@selected_logo.annual_fee) %></strong></span>
            <span>Min Limit: <strong><%= money(@selected_logo.min_credit_limit) %></strong></span>
            <span>Max Limit: <strong><%= money(@selected_logo.max_credit_limit) %></strong></span>
          </div>
        </div>
      <% end %>

      <div style="display:flex;gap:8px;margin-top:20px;">
        <button class="btn btn-secondary"
          phx-click="wizard_step" phx-value-s="1" phx-target={@myself}>← Back</button>
        <button class="btn btn-primary"
          phx-click="wizard_step" phx-value-s="3" phx-target={@myself}
          disabled={is_nil(@form_data["logo_id"]) or @form_data["logo_id"] == ""}>
          Next: Card & Credit →
        </button>
      </div>
    </div>
    """
  end

  defp wizard_step3(assigns) do
    ~H"""
    <div>
      <div class="form-pane-section-title">Step 3 — Card & Credit Details</div>
      <form phx-change="wizard_change" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">Credit Limit *</label>
            <input type="number" class="input" name="acc[credit_limit]"
              value={@form_data["credit_limit"]} min="0" step="100" required/>
          </div>
          <div class="form-group">
            <label class="form-label">Cash Sub-limit (auto: 30% of limit)</label>
            <input type="number" class="input" name="acc[cash_limit]"
              value={@form_data["cash_limit"]} min="0" step="100"
              placeholder="Leave blank for 30% auto-calculation"/>
          </div>
          <div class="form-group">
            <label class="form-label">Emboss Name (max 26 chars, uppercase) *</label>
            <input type="text" class="input" name="acc[emboss_name]"
              value={@form_data["emboss_name"]} maxlength="26" required
              style="text-transform:uppercase;" placeholder="JOHN SMITH"/>
          </div>
          <div class="form-group">
            <label class="form-label">Billing Cycle Day (1–28) *</label>
            <input type="number" class="input" name="acc[cycle_code]"
              value={@form_data["cycle_code"] || "1"} min="1" max="28" required/>
          </div>
          <div class="form-group">
            <label class="form-label">Card Last 4 Digits *</label>
            <input type="text" class="input" name="acc[last_four]"
              value={@form_data["last_four"]} maxlength="4" pattern="[0-9]{4}"
              required placeholder="e.g. 4567"/>
          </div>
          <div class="form-group">
            <label class="form-label">Expiry (MMYY format) *</label>
            <input type="text" class="input" name="acc[expiry_date]"
              value={@form_data["expiry_date"]} maxlength="4" pattern="[0-9]{4}"
              required placeholder="e.g. 1228"/>
          </div>
        </div>
      </form>
      <div style="margin-top:4px;font-size:12px;color:var(--text-secondary);">
        Note: A placeholder PAN token will be generated from the last 4 digits and expiry. Real PAN issuance is handled by CTA (Phase 5).
      </div>
      <div style="display:flex;gap:8px;margin-top:20px;">
        <button class="btn btn-secondary"
          phx-click="wizard_step" phx-value-s="2" phx-target={@myself}>← Back</button>
        <button class="btn btn-primary"
          phx-click="wizard_step" phx-value-s="4" phx-target={@myself}>Next: Config →</button>
      </div>
    </div>
    """
  end

  defp wizard_step4(assigns) do
    ~H"""
    <div>
      <div class="form-pane-section-title">Step 4 — Additional Configuration</div>
      <form phx-change="wizard_change" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">Campaign Code (optional)</label>
            <input type="text" class="input" name="acc[campaign_code]"
              value={@form_data["campaign_code"]} maxlength="20"
              placeholder="e.g. LAUNCH2026"/>
          </div>
          <div class="form-group">
            <label class="form-label">Open Date</label>
            <input type="date" class="input" name="acc[open_date_str]"
              value={@form_data["open_date_str"] || Date.to_iso8601(Date.utc_today())}/>
          </div>
        </div>
      </form>
      <div style="display:flex;gap:8px;margin-top:20px;">
        <button class="btn btn-secondary"
          phx-click="wizard_step" phx-value-s="3" phx-target={@myself}>← Back</button>
        <button class="btn btn-primary"
          phx-click="wizard_step" phx-value-s="5" phx-target={@myself}>Next: Review →</button>
      </div>
    </div>
    """
  end

  defp wizard_step5(assigns) do
    ~H"""
    <div>
      <div class="form-pane-section-title">Step 5 — Review & Confirm</div>

      <div class="form-grid-2" style="margin-bottom:20px;">
        <div>
          <div style="font-weight:600;margin-bottom:8px;">Customer & Product</div>
          <table style="font-size:13px;width:100%;border-collapse:collapse;">
            <tr><td class="kv-key">Customer</td><td class="kv-val"><%= @form_data["customer_name"] || "—" %></td></tr>
            <tr><td class="kv-key">Bank</td><td class="kv-val"><%= @form_data["bank_id"] || "—" %></td></tr>
            <tr><td class="kv-key">Logo</td><td class="kv-val"><%= @form_data["logo_id"] || "—" %></td></tr>
            <tr><td class="kv-key">Block</td><td class="kv-val"><%= @form_data["block_id"] || "DFLT" %></td></tr>
          </table>
        </div>
        <div>
          <div style="font-weight:600;margin-bottom:8px;">Card & Credit</div>
          <table style="font-size:13px;width:100%;border-collapse:collapse;">
            <tr><td class="kv-key">Emboss Name</td><td class="kv-val mono"><%= (@form_data["emboss_name"] || "") |> String.upcase() %></td></tr>
            <tr><td class="kv-key">Last 4 / Expiry</td><td class="kv-val mono">****<%= @form_data["last_four"] %> / <%= @form_data["expiry_date"] %></td></tr>
            <tr><td class="kv-key">Credit Limit</td><td class="kv-val mono"><%= @form_data["credit_limit"] || "—" %></td></tr>
            <tr><td class="kv-key">Cash Limit</td><td class="kv-val mono"><%= @form_data["cash_limit"] || "30% auto" %></td></tr>
            <tr><td class="kv-key">Billing Cycle</td><td class="kv-val">Day <%= @form_data["cycle_code"] || "1" %></td></tr>
            <tr><td class="kv-key">Campaign</td><td class="kv-val"><%= @form_data["campaign_code"] || "—" %></td></tr>
          </table>
        </div>
      </div>

      <div style="background:#fff8dc;border:1px solid #fbbf24;padding:12px 16px;border-radius:8px;font-size:13px;margin-bottom:20px;">
        ⚠️ This will create a new active account with the above settings. A placeholder PAN token will be generated. The account will be immediately visible in the system.
      </div>

      <form phx-submit="wizard_save" phx-target={@myself}>
        <input type="hidden" name="acc[_confirm]" value="true"/>
        <div style="display:flex;gap:8px;">
          <button class="btn btn-secondary"
            phx-click="wizard_step" phx-value-s="4" phx-target={@myself} type="button">← Back</button>
          <button type="submit" class="btn btn-primary" style="font-weight:700;">
            ✓ Open Account
          </button>
        </div>
      </form>
    </div>
    """
  end
end
