defmodule VmuCoreWeb.Live.Admin.LogoComponent do
  @moduledoc """
  Logo / Product parameter CRUD LiveComponent.

  A LOGO defines a complete card product template (BIN, scheme, interest rates,
  fees, billing rules, auth channel flags, credit limits, STIP).
  Sits below BANK and above BLOCK in the parameter hierarchy.

  The create/edit form uses a 5-step tabbed wizard to organise the 50+ fields.
  """
  use Phoenix.LiveComponent

  import Ecto.Query, warn: false
  import VmuCoreWeb.AdminUI

  alias VmuCore.{Repo}
  alias VmuCore.Shared.{LogoParameter, BankParameter, SysParameter, ParameterWriter}
  alias VmuCore.CMS.PlanSegment
  alias VmuCore.ASM.Authz

  @steps ["Identity", "Interest Rates", "Fees", "Billing & Auth", "Limits & STIP"]

  # ── Mount / Update ──────────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       mode: :list,
       editing: nil,
       result: nil,
       form_data: %{},
       current_step: 1,
       filter_bank: nil,
       steps: @steps,
       # Plan segment management
       plans_logo: nil,
       logo_plans: [],
       plan_editing: nil,
       plan_form_data: %{},
       plan_result: nil,
       plan_form_open: false,
       current_operator: nil,
       can_edit: false
     )
     |> load_data()}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(can_edit: Authz.can?(assigns[:current_operator], "logo", "edit"))}
  end

  defp load_data(socket) do
    logos = Repo.all(LogoParameter)
    banks = Repo.all(BankParameter)
    syss  = Repo.all(SysParameter)
    assign(socket, logos: logos, banks: banks, sys_records: syss)
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("logo_new", _params, socket) do
    if socket.assigns.can_edit do
      sys_id  = case socket.assigns.sys_records do [s | _] -> s.sys_id;  _ -> "" end
      bank_id = case socket.assigns.banks       do [b | _] -> b.bank_id; _ -> "" end
      fd = default_form(sys_id, bank_id)
      {:noreply, assign(socket, mode: :form, editing: nil, form_data: fd,
                        current_step: 1, result: nil)}
    else
      {:noreply, assign(socket, result: {:error, "Your role cannot create products."})}
    end
  end

  def handle_event("logo_edit", %{"id" => logo_id}, socket) do
    if socket.assigns.can_edit do
      logo = Enum.find(socket.assigns.logos, &(&1.logo_id == logo_id))
      fd   = if logo, do: logo_to_form(logo), else: %{}
      {:noreply, assign(socket, mode: :form, editing: logo, form_data: fd,
                        current_step: 1, result: nil)}
    else
      {:noreply, assign(socket, result: {:error, "Your role cannot edit products."})}
    end
  end

  def handle_event("logo_cancel", _params, socket) do
    {:noreply, socket |> assign(mode: :list, editing: nil, result: nil) |> load_data()}
  end

  def handle_event("logo_filter_bank", %{"bank_id" => bank_id}, socket) do
    filter = if bank_id == "", do: nil, else: bank_id
    {:noreply, assign(socket, filter_bank: filter)}
  end

  def handle_event("logo_change", %{"logo" => params}, socket) do
    {:noreply, assign(socket, form_data: params)}
  end

  def handle_event("step_go", %{"step" => step_str}, socket) do
    step = String.to_integer(step_str)
    {:noreply, assign(socket, current_step: step)}
  end

  def handle_event("step_next", _params, socket) do
    step = min(socket.assigns.current_step + 1, length(@steps))
    {:noreply, assign(socket, current_step: step)}
  end

  def handle_event("step_prev", _params, socket) do
    step = max(socket.assigns.current_step - 1, 1)
    {:noreply, assign(socket, current_step: step)}
  end

  def handle_event("logo_save", %{"logo" => params}, socket) do
    if socket.assigns.can_edit do
      attrs = build_logo_attrs(params)

      result = case socket.assigns.editing do
        nil  -> ParameterWriter.create_logo(attrs)
        logo -> ParameterWriter.update_logo(logo, attrs)
      end

      case result do
        {:ok, _} ->
          label = if is_nil(socket.assigns.editing), do: "Product created.", else: "Product updated."
          {:noreply, socket |> load_data() |> assign(mode: :list, result: {:ok, label})}

        {:error, cs} ->
          msg = Enum.map_join(cs.errors, "; ", fn {f, {m, _}} -> "#{f}: #{m}" end)
          {:noreply, assign(socket, result: {:error, "Save failed — #{msg}"})}
      end
    else
      {:noreply, assign(socket, result: {:error, "Your role cannot save products."})}
    end
  end

  def handle_event("logo_delete", %{"id" => logo_id}, socket) do
    if socket.assigns.can_edit do
      logo = Enum.find(socket.assigns.logos, &(&1.logo_id == logo_id))
      if logo, do: Repo.delete(logo) |> tap(fn _ -> VmuCore.Shared.ParameterEngine.refresh_all() end)
      {:noreply, socket |> load_data() |> assign(result: {:ok, "Product #{logo_id} deleted."})}
    else
      {:noreply, assign(socket, result: {:error, "Your role cannot delete products."})}
    end
  end

  # ── Plan Segment events ─────────────────────────────────────────────────────

  def handle_event("logo_plans", %{"id" => logo_id}, socket) do
    logo  = Enum.find(socket.assigns.logos, &(&1.logo_id == logo_id))
    plans = load_plans_for(logo_id)
    {:noreply, assign(socket,
      mode: :plans, plans_logo: logo, logo_plans: plans,
      plan_editing: nil, plan_form_data: %{}, plan_result: nil, plan_form_open: false)}
  end

  def handle_event("plan_back", _params, socket) do
    {:noreply, assign(socket, mode: :list, plans_logo: nil, plan_result: nil)}
  end

  def handle_event("plan_new", _params, socket) do
    if socket.assigns.can_edit do
      logo = socket.assigns.plans_logo
      fd = %{
        "plan_id" => "", "logo_id" => logo.logo_id, "sys_id" => logo.sys_id,
        "bank_id" => logo.bank_id, "plan_type" => "RETAIL", "apr" => "0.0",
        "promo_apr" => "", "promo_expiry_date" => "", "grace_eligible" => "true",
        "min_payment_pct" => "", "payment_priority" => "4", "statement_order" => "1",
        "emi_tenor_months" => "", "active" => "true", "description" => ""
      }
      {:noreply, assign(socket, plan_editing: nil, plan_form_data: fd, plan_form_open: true, plan_result: nil)}
    else
      {:noreply, assign(socket, plan_result: {:error, "Your role cannot create plans."})}
    end
  end

  def handle_event("plan_edit", %{"id" => plan_id}, socket) do
    if socket.assigns.can_edit do
      plan = Enum.find(socket.assigns.logo_plans, &(&1.plan_id == plan_id))
      fd = plan_to_form(plan)
      {:noreply, assign(socket, plan_editing: plan, plan_form_data: fd, plan_form_open: true, plan_result: nil)}
    else
      {:noreply, assign(socket, plan_result: {:error, "Your role cannot edit plans."})}
    end
  end

  def handle_event("plan_cancel", _params, socket) do
    {:noreply, assign(socket, plan_form_open: false, plan_editing: nil, plan_form_data: %{}, plan_result: nil)}
  end

  def handle_event("plan_change", %{"plan" => params}, socket) do
    {:noreply, assign(socket, plan_form_data: params)}
  end

  def handle_event("plan_save", %{"plan" => params}, socket) do
    if socket.assigns.can_edit do
      attrs = build_plan_attrs(params)
      result = case socket.assigns.plan_editing do
        nil  ->
          %PlanSegment{} |> PlanSegment.changeset(attrs) |> Repo.insert()
        plan ->
          plan |> PlanSegment.changeset(attrs) |> Repo.update()
      end
      case result do
        {:ok, _} ->
          plans = load_plans_for(socket.assigns.plans_logo.logo_id)
          label = if is_nil(socket.assigns.plan_editing), do: "Plan created.", else: "Plan updated."
          {:noreply, assign(socket,
            logo_plans: plans, plan_form_open: false, plan_editing: nil,
            plan_form_data: %{}, plan_result: {:ok, label})}
        {:error, cs} ->
          msg = Enum.map_join(cs.errors, "; ", fn {f, {m, _}} -> "#{f}: #{m}" end)
          {:noreply, assign(socket, plan_result: {:error, "Save failed — #{msg}"})}
      end
    else
      {:noreply, assign(socket, plan_result: {:error, "Your role cannot save plans."})}
    end
  end

  def handle_event("plan_delete", %{"id" => plan_id}, socket) do
    if socket.assigns.can_edit do
      plan = Enum.find(socket.assigns.logo_plans, &(&1.plan_id == plan_id))
      if plan, do: Repo.delete(plan)
      plans = load_plans_for(socket.assigns.plans_logo.logo_id)
      {:noreply, assign(socket, logo_plans: plans, plan_result: {:ok, "Plan #{plan_id} deleted."})}
    else
      {:noreply, assign(socket, plan_result: {:error, "Your role cannot delete plans."})}
    end
  end

  # ── Form data helpers ───────────────────────────────────────────────────────

  defp default_form(sys_id, bank_id) do
    %{
      "logo_id" => "", "sys_id" => sys_id, "bank_id" => bank_id,
      "bin_prefix" => "", "description" => "",
      "card_scheme" => "", "product_type" => "",
      # Interest rates
      "purchase_apr" => "0.0", "cash_apr" => "0.0", "penalty_apr" => "0.0",
      "promo_apr" => "0.0", "penalty_apr_dpd_trigger" => "60",
      "interest_calculation_method" => "AVERAGE_DAILY_BALANCE",
      # Fees
      "annual_fee" => "0.0", "annual_fee_posting" => "UPON_ACTIVATION",
      "late_fee" => "0.0", "overlimit_fee" => "0.0", "replacement_fee" => "0.0",
      "returned_payment_fee" => "0.0", "card_replacement_fee" => "0.0",
      "cash_advance_fee_percent" => "0.0", "cash_advance_fee_min" => "0.0",
      "foreign_transaction_fee_percent" => "0.0",
      # Billing
      "min_payment_pct" => "5.0", "min_payment_floor" => "25.0",
      "min_payment_calculation" => "PERCENTAGE_OF_BALANCE",
      "grace_days" => "25", "payment_due_days" => "25",
      "cash_limit_pct" => "30.0", "statement_cycle_days" => "30",
      # Overlimit
      "overlimit_allowed" => "false", "overlimit_tolerance_pct" => "0.0",
      # Auth channels
      "ecom_enabled" => "true", "atm_enabled" => "true", "intl_enabled" => "false",
      "contactless_enabled" => "true", "recurring_enabled" => "true",
      "moto_enabled" => "false", "quasi_cash_enabled" => "false", "cash_back_enabled" => "false",
      # Card/Chip
      "chip_enabled" => "true", "mag_stripe_enabled" => "true", "pin_required" => "true",
      "card_validity_years" => "3", "supplementary_cards_allowed" => "true",
      "supplementary_card_limit" => "3",
      # Credit limits
      "credit_limit_min" => "", "credit_limit_default" => "", "credit_limit_max" => "",
      # STIP
      "stip_enabled" => "false", "stip_floor_limit" => "50.0", "stip_max_amount" => "500.0"
    }
  end

  defp logo_to_form(%LogoParameter{} = l) do
    %{
      "logo_id" => l.logo_id, "sys_id" => l.sys_id, "bank_id" => l.bank_id,
      "bin_prefix" => l.bin_prefix, "description" => l.description,
      "card_scheme" => l.card_scheme || "", "product_type" => l.product_type || "",
      "purchase_apr" => dec(l.purchase_apr), "cash_apr" => dec(l.cash_apr),
      "penalty_apr" => dec(l.penalty_apr), "promo_apr" => dec(l.promo_apr),
      "penalty_apr_dpd_trigger" => to_string(l.penalty_apr_dpd_trigger || 60),
      "interest_calculation_method" => l.interest_calculation_method || "AVERAGE_DAILY_BALANCE",
      "annual_fee" => dec(l.annual_fee), "annual_fee_posting" => l.annual_fee_posting || "UPON_ACTIVATION",
      "late_fee" => dec(l.late_fee), "overlimit_fee" => dec(l.overlimit_fee),
      "replacement_fee" => dec(l.replacement_fee), "returned_payment_fee" => dec(l.returned_payment_fee),
      "card_replacement_fee" => dec(l.card_replacement_fee),
      "cash_advance_fee_percent" => dec(l.cash_advance_fee_percent),
      "cash_advance_fee_min" => dec(l.cash_advance_fee_min),
      "foreign_transaction_fee_percent" => dec(l.foreign_transaction_fee_percent),
      "min_payment_pct" => dec(l.min_payment_pct), "min_payment_floor" => dec(l.min_payment_floor),
      "min_payment_calculation" => l.min_payment_calculation || "PERCENTAGE_OF_BALANCE",
      "grace_days" => to_string(l.grace_days || 25), "payment_due_days" => to_string(l.payment_due_days || 25),
      "cash_limit_pct" => dec(l.cash_limit_pct), "statement_cycle_days" => to_string(l.statement_cycle_days || 30),
      "overlimit_allowed" => to_string(l.overlimit_allowed || false),
      "overlimit_tolerance_pct" => dec(l.overlimit_tolerance_pct),
      "ecom_enabled" => to_string(l.ecom_enabled != false),
      "atm_enabled" => to_string(l.atm_enabled != false),
      "intl_enabled" => to_string(l.intl_enabled == true),
      "contactless_enabled" => to_string(l.contactless_enabled != false),
      "recurring_enabled" => to_string(l.recurring_enabled != false),
      "moto_enabled" => to_string(l.moto_enabled == true),
      "quasi_cash_enabled" => to_string(l.quasi_cash_enabled == true),
      "cash_back_enabled" => to_string(l.cash_back_enabled == true),
      "chip_enabled" => to_string(l.chip_enabled != false),
      "mag_stripe_enabled" => to_string(l.mag_stripe_enabled != false),
      "pin_required" => to_string(l.pin_required != false),
      "card_validity_years" => to_string(l.card_validity_years || 3),
      "supplementary_cards_allowed" => to_string(l.supplementary_cards_allowed != false),
      "supplementary_card_limit" => to_string(l.supplementary_card_limit || 3),
      "credit_limit_min" => dec(l.credit_limit_min),
      "credit_limit_default" => dec(l.credit_limit_default),
      "credit_limit_max" => dec(l.credit_limit_max),
      "stip_enabled" => to_string(l.stip_enabled == true),
      "stip_floor_limit" => dec(l.stip_floor_limit),
      "stip_max_amount" => dec(l.stip_max_amount)
    }
  end

  defp dec(nil), do: ""
  defp dec(d),   do: Decimal.to_string(d)

  defp build_logo_attrs(p) do
    %{
      logo_id: p["logo_id"], sys_id: p["sys_id"], bank_id: p["bank_id"],
      bin_prefix: p["bin_prefix"], description: p["description"],
      card_scheme: nilify(p["card_scheme"]), product_type: nilify(p["product_type"]),
      purchase_apr: dp(p["purchase_apr"]), cash_apr: dp(p["cash_apr"]),
      penalty_apr: dp(p["penalty_apr"]), promo_apr: dp(p["promo_apr"]),
      penalty_apr_dpd_trigger: ip(p["penalty_apr_dpd_trigger"]),
      interest_calculation_method: p["interest_calculation_method"],
      annual_fee: dp(p["annual_fee"]), annual_fee_posting: p["annual_fee_posting"],
      late_fee: dp(p["late_fee"]), overlimit_fee: dp(p["overlimit_fee"]),
      replacement_fee: dp(p["replacement_fee"]), returned_payment_fee: dp(p["returned_payment_fee"]),
      card_replacement_fee: dp(p["card_replacement_fee"]),
      cash_advance_fee_percent: dp(p["cash_advance_fee_percent"]),
      cash_advance_fee_min: dp(p["cash_advance_fee_min"]),
      foreign_transaction_fee_percent: dp(p["foreign_transaction_fee_percent"]),
      min_payment_pct: dp(p["min_payment_pct"]), min_payment_floor: dp(p["min_payment_floor"]),
      min_payment_calculation: p["min_payment_calculation"],
      grace_days: ip(p["grace_days"]), payment_due_days: ip(p["payment_due_days"]),
      cash_limit_pct: dp(p["cash_limit_pct"]), statement_cycle_days: ip(p["statement_cycle_days"]),
      overlimit_allowed: p["overlimit_allowed"] == "true",
      overlimit_tolerance_pct: dp(p["overlimit_tolerance_pct"]),
      ecom_enabled: p["ecom_enabled"] == "true", atm_enabled: p["atm_enabled"] == "true",
      intl_enabled: p["intl_enabled"] == "true", contactless_enabled: p["contactless_enabled"] == "true",
      recurring_enabled: p["recurring_enabled"] == "true", moto_enabled: p["moto_enabled"] == "true",
      quasi_cash_enabled: p["quasi_cash_enabled"] == "true", cash_back_enabled: p["cash_back_enabled"] == "true",
      chip_enabled: p["chip_enabled"] == "true", mag_stripe_enabled: p["mag_stripe_enabled"] == "true",
      pin_required: p["pin_required"] == "true",
      card_validity_years: ip(p["card_validity_years"]),
      supplementary_cards_allowed: p["supplementary_cards_allowed"] == "true",
      supplementary_card_limit: ip(p["supplementary_card_limit"]),
      credit_limit_min: dpn(p["credit_limit_min"]), credit_limit_default: dpn(p["credit_limit_default"]),
      credit_limit_max: dpn(p["credit_limit_max"]),
      stip_enabled: p["stip_enabled"] == "true",
      stip_floor_limit: dp(p["stip_floor_limit"]), stip_max_amount: dp(p["stip_max_amount"])
    }
  end

  defp dp(nil), do: Decimal.new(0)
  defp dp(""),  do: Decimal.new(0)
  defp dp(s)  do
    case Decimal.parse(to_string(s)) do
      {d, ""} -> d
      _       -> Decimal.new(0)
    end
  end

  defp dpn(""), do: nil
  defp dpn(s),  do: dp(s)

  defp ip(nil), do: nil
  defp ip(""),  do: nil
  defp ip(s) do
    case Integer.parse(to_string(s)) do
      {n, _} -> n
      _      -> nil
    end
  end

  defp nilify(""), do: nil
  defp nilify(s),  do: s

  defp load_plans_for(logo_id) do
    Repo.all(from p in PlanSegment, where: p.logo_id == ^logo_id, order_by: [asc: p.payment_priority])
  end

  defp plan_to_form(%PlanSegment{} = p) do
    %{
      "plan_id"           => p.plan_id,
      "logo_id"           => p.logo_id,
      "sys_id"            => p.sys_id,
      "bank_id"           => p.bank_id,
      "plan_type"         => p.plan_type,
      "apr"               => Decimal.to_string(p.apr),
      "promo_apr"         => if(p.promo_apr, do: Decimal.to_string(p.promo_apr), else: ""),
      "promo_expiry_date" => if(p.promo_expiry_date, do: Date.to_string(p.promo_expiry_date), else: ""),
      "grace_eligible"    => to_string(p.grace_eligible),
      "min_payment_pct"   => if(p.min_payment_pct, do: Decimal.to_string(p.min_payment_pct), else: ""),
      "payment_priority"  => to_string(p.payment_priority),
      "statement_order"   => to_string(p.statement_order),
      "emi_tenor_months"  => if(p.emi_tenor_months, do: to_string(p.emi_tenor_months), else: ""),
      "active"            => to_string(p.active),
      "description"       => p.description || ""
    }
  end

  defp build_plan_attrs(p) do
    %{
      plan_id:           p["plan_id"],
      logo_id:           p["logo_id"],
      sys_id:            p["sys_id"],
      bank_id:           p["bank_id"],
      plan_type:         p["plan_type"],
      apr:               parse_dec(p["apr"]),
      promo_apr:         parse_dec_opt(p["promo_apr"]),
      promo_expiry_date: parse_date(p["promo_expiry_date"]),
      grace_eligible:    p["grace_eligible"] == "true",
      min_payment_pct:   parse_dec_opt(p["min_payment_pct"]),
      payment_priority:  parse_int(p["payment_priority"]),
      statement_order:   parse_int(p["statement_order"]),
      emi_tenor_months:  parse_int_opt(p["emi_tenor_months"]),
      active:            p["active"] == "true",
      description:       nilify(p["description"] || "")
    }
  end

  defp parse_dec(nil),         do: Decimal.new(0)
  defp parse_dec(""),          do: Decimal.new(0)
  defp parse_dec(s),           do: Decimal.new(s)
  defp parse_dec_opt(nil),     do: nil
  defp parse_dec_opt(""),      do: nil
  defp parse_dec_opt(s),       do: Decimal.new(s)
  defp parse_int(nil),         do: 0
  defp parse_int(""),          do: 0
  defp parse_int(s),           do: String.to_integer(s)
  defp parse_int_opt(nil),     do: nil
  defp parse_int_opt(""),      do: nil
  defp parse_int_opt(s),       do: String.to_integer(s)
  defp parse_date(nil),        do: nil
  defp parse_date(""),         do: nil
  defp parse_date(s),          do: Date.from_iso8601!(s)

  # ── Render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_header title="Products / Logos" subtitle="Card product templates (LOGO level in the parameter hierarchy)">
        <:actions>
          <button :if={@mode == :list && @can_edit} phx-click="logo_new" phx-target={@myself} class="btn btn-primary">
            + New Product
          </button>
        </:actions>
      </.page_header>

      <%= if @result do %>
        <% {kind, msg} = @result %>
        <.alert kind={kind} message={msg} />
      <% end %>

      <%= case @mode do %>
        <% :list -> %>
          <.render_list logos={@logos} banks={@banks} myself={@myself} filter_bank={@filter_bank} can_edit={@can_edit} />
        <% :plans -> %>
          <.render_plans
            plans_logo={@plans_logo}
            logo_plans={@logo_plans}
            plan_editing={@plan_editing}
            plan_form_data={@plan_form_data}
            plan_result={@plan_result}
            plan_form_open={@plan_form_open}
            myself={@myself}
            can_edit={@can_edit}
          />
        <% _ -> %>
          <.render_form
            form_data={@form_data}
            editing={@editing}
            myself={@myself}
            banks={@banks}
            sys_records={@sys_records}
            current_step={@current_step}
            steps={@steps}
          />
      <% end %>
    </div>
    """
  end

  defp render_list(assigns) do
    filtered = case assigns.filter_bank do
      nil -> assigns.logos
      bid -> Enum.filter(assigns.logos, &(&1.bank_id == bid))
    end
    assigns = assign(assigns, filtered: filtered)
    ~H"""
    <!-- Filter bar -->
    <div class="flex items-center gap-3 mb-4">
      <label class="text-sm font-bold" style="color:var(--text-secondary);">Filter by Organisation:</label>
      <select phx-change="logo_filter_bank" phx-target={@myself} name="bank_id"
        style="width:auto;padding:6px 10px;font-size:13px;">
        <option value="">All Organisations</option>
        <%= for bank <- @banks do %>
          <option value={bank.bank_id} selected={@filter_bank == bank.bank_id}>
            <%= bank.bank_id %> — <%= bank.org_name || bank.description %>
          </option>
        <% end %>
      </select>
      <span class="text-sm text-muted"><%= length(@filtered) %> product(s)</span>
    </div>

    <%= if @filtered == [] do %>
      <.empty_state icon="💳" title="No Products Found"
        message="Create a product (LOGO) to define card programme parameters.">
        <:actions>
          <button :if={@can_edit} phx-click="logo_new" phx-target={@myself} class="btn btn-primary">
            + New Product
          </button>
        </:actions>
      </.empty_state>
    <% else %>
      <div class="card">
        <table class="data-table">
          <thead>
            <tr>
              <th>LOGO ID</th>
              <th>BIN Prefix</th>
              <th>Description</th>
              <th>Scheme</th>
              <th>Type</th>
              <th>Purchase APR</th>
              <th>Annual Fee</th>
              <th>STIP</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for logo <- @filtered do %>
              <tr>
                <td><span class="mono"><%= logo.logo_id %></span></td>
                <td><span class="mono"><%= logo.bin_prefix %></span></td>
                <td>
                  <div style="font-weight:500;"><%= logo.description %></div>
                  <div class="text-xs text-muted">ORG: <%= logo.bank_id %> / SYS: <%= logo.sys_id %></div>
                </td>
                <td>
                  <span :if={logo.card_scheme} class="badge badge-blue"><%= logo.card_scheme %></span>
                  <span :if={!logo.card_scheme} class="text-muted text-xs">—</span>
                </td>
                <td>
                  <span :if={logo.product_type} class="badge badge-gray"><%= logo.product_type %></span>
                  <span :if={!logo.product_type} class="text-muted text-xs">—</span>
                </td>
                <td class="font-mono"><%= logo.purchase_apr %>%</td>
                <td class="font-mono"><%= logo.annual_fee %></td>
                <td>
                  <span class={"badge #{if logo.stip_enabled, do: "badge-green", else: "badge-gray"}"}>
                    <%= if logo.stip_enabled, do: "ON", else: "OFF" %>
                  </span>
                </td>
                <td>
                  <div class="actions">
                    <button phx-click="logo_plans" phx-target={@myself}
                      phx-value-id={logo.logo_id} class="btn btn-sm btn-secondary">📊 Plans</button>
                    <button :if={@can_edit} phx-click="logo_edit" phx-target={@myself}
                      phx-value-id={logo.logo_id} class="btn btn-sm btn-secondary">Edit</button>
                    <button :if={@can_edit} phx-click="logo_delete" phx-target={@myself}
                      phx-value-id={logo.logo_id} class="btn btn-sm btn-danger"
                      data-confirm={"Delete product #{logo.logo_id}?"}>Delete</button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% end %>
    """
  end

  defp render_form(assigns) do
    is_new = is_nil(assigns.editing)
    assigns = assign(assigns,
      is_new: is_new,
      cs: LogoParameter.card_scheme_options(),
      pt: LogoParameter.product_type_options(),
      cm: LogoParameter.calc_method_options(),
      mp: LogoParameter.min_pay_options(),
      fp: LogoParameter.fee_posting_options(),
      cv: LogoParameter.card_validity_options(),
      sl: LogoParameter.supplementary_limit_options()
    )
    ~H"""
    <form phx-change="logo_change" phx-submit="logo_save" phx-target={@myself}>
      <div class="card">
        <div class="card-header">
          <div>
            <div class="card-title"><%= if @is_new, do: "New Product / Logo", else: "Edit Product / Logo" %></div>
            <div class="card-subtitle">Configure all parameters for this card product programme.</div>
          </div>
        </div>
        <div class="card-body">

          <!-- Step navigation -->
          <.step_nav steps={@steps} current_step={@current_step} />

          <!-- Step 1: Identity -->
          <div style={"#{if @current_step != 1, do: "display:none"}"}>
            <div class="form-grid">
              <div class="field">
                <label>LOGO ID <span style="color:var(--danger)">*</span></label>
                <input type="text" name="logo[logo_id]" value={@form_data["logo_id"]}
                  maxlength="4" placeholder="e.g. 0100" disabled={!@is_new}
                  style="font-family:var(--font-mono);letter-spacing:.1em;text-transform:uppercase;"/>
                <p class="hint">4-character code. Cannot be changed after creation.</p>
              </div>
              <div class="field">
                <label>BIN Prefix <span style="color:var(--danger)">*</span></label>
                <input type="text" name="logo[bin_prefix]" value={@form_data["bin_prefix"]}
                  maxlength="6" minlength="6" placeholder="e.g. 457173"
                  style="font-family:var(--font-mono);letter-spacing:.1em;"/>
                <p class="hint">6-digit Bank Identification Number (BIN) prefix.</p>
              </div>
              <div class="field">
                <label>Organisation (BANK ID)</label>
                <select name="logo[bank_id]">
                  <%= for bank <- @banks do %>
                    <option value={bank.bank_id} selected={@form_data["bank_id"] == bank.bank_id}>
                      <%= bank.bank_id %> — <%= bank.org_name || bank.description %>
                    </option>
                  <% end %>
                </select>
              </div>
              <div class="field">
                <label>SYS ID</label>
                <select name="logo[sys_id]">
                  <%= for sys <- @sys_records do %>
                    <option value={sys.sys_id} selected={@form_data["sys_id"] == sys.sys_id}>
                      <%= sys.sys_id %> — <%= sys.description %>
                    </option>
                  <% end %>
                </select>
              </div>
              <div class="field" style="grid-column:1/-1;">
                <label>Product Description <span style="color:var(--danger)">*</span></label>
                <input type="text" name="logo[description]" value={@form_data["description"]}
                  placeholder="e.g. Emirates NBD Visa Platinum Credit Card"/>
              </div>
              <div class="field">
                <label>Card Scheme / Network</label>
                <select name="logo[card_scheme]">
                  <%= for {label, val} <- @cs do %>
                    <option value={val} selected={@form_data["card_scheme"] == val}><%= label %></option>
                  <% end %>
                </select>
              </div>
              <div class="field">
                <label>Product Type</label>
                <select name="logo[product_type]">
                  <%= for {label, val} <- @pt do %>
                    <option value={val} selected={@form_data["product_type"] == val}><%= label %></option>
                  <% end %>
                </select>
              </div>
            </div>
          </div>

          <!-- Step 2: Interest Rates -->
          <div style={"#{if @current_step != 2, do: "display:none"}"}>
            <div class="form-grid">
              <div class="field">
                <label>Purchase APR (%)</label>
                <input type="number" name="logo[purchase_apr]" value={@form_data["purchase_apr"]}
                  step="0.01" min="0" max="99" placeholder="e.g. 22.00"/>
                <p class="hint">Annual Percentage Rate on purchase balances.</p>
              </div>
              <div class="field">
                <label>Cash Advance APR (%)</label>
                <input type="number" name="logo[cash_apr]" value={@form_data["cash_apr"]}
                  step="0.01" min="0" max="99"/>
                <p class="hint">Usually higher than purchase rate.</p>
              </div>
              <div class="field">
                <label>Penalty APR (%)</label>
                <input type="number" name="logo[penalty_apr]" value={@form_data["penalty_apr"]}
                  step="0.01" min="0" max="99"/>
                <p class="hint">Escalated rate triggered after DPD threshold.</p>
              </div>
              <div class="field">
                <label>Penalty APR Trigger (DPD)</label>
                <input type="number" name="logo[penalty_apr_dpd_trigger]" value={@form_data["penalty_apr_dpd_trigger"]}
                  min="1" max="180"/>
                <p class="hint">Days past due before penalty rate applies.</p>
              </div>
              <div class="field">
                <label>Promotional APR (%)</label>
                <input type="number" name="logo[promo_apr]" value={@form_data["promo_apr"]}
                  step="0.01" min="0" max="99"/>
                <p class="hint">Introductory or balance-transfer promotional rate (0 = no promo rate).</p>
              </div>
              <div class="field">
                <label>Interest Calculation Method</label>
                <select name="logo[interest_calculation_method]">
                  <%= for {label, val} <- @cm do %>
                    <option value={val} selected={@form_data["interest_calculation_method"] == val}><%= label %></option>
                  <% end %>
                </select>
              </div>
            </div>
          </div>

          <!-- Step 3: Fees -->
          <div style={"#{if @current_step != 3, do: "display:none"}"}>
            <div class="form-section" style="padding-top:0;border-top:none;">
              <div class="form-section-title">Annual Fee</div>
              <div class="form-grid">
                <div class="field">
                  <label>Annual Fee Amount</label>
                  <input type="number" name="logo[annual_fee]" value={@form_data["annual_fee"]} step="0.01" min="0"/>
                </div>
                <div class="field">
                  <label>Annual Fee Posting Trigger</label>
                  <select name="logo[annual_fee_posting]">
                    <%= for {label, val} <- @fp do %>
                      <option value={val} selected={@form_data["annual_fee_posting"] == val}><%= label %></option>
                    <% end %>
                  </select>
                </div>
              </div>
            </div>
            <div class="form-section">
              <div class="form-section-title">Penalty & Service Fees</div>
              <div class="form-grid">
                <div class="field">
                  <label>Late Payment Fee</label>
                  <input type="number" name="logo[late_fee]" value={@form_data["late_fee"]} step="0.01" min="0"/>
                </div>
                <div class="field">
                  <label>Overlimit Fee</label>
                  <input type="number" name="logo[overlimit_fee]" value={@form_data["overlimit_fee"]} step="0.01" min="0"/>
                </div>
                <div class="field">
                  <label>Replacement / Reissue Fee</label>
                  <input type="number" name="logo[replacement_fee]" value={@form_data["replacement_fee"]} step="0.01" min="0"/>
                </div>
                <div class="field">
                  <label>Returned Payment Fee</label>
                  <input type="number" name="logo[returned_payment_fee]" value={@form_data["returned_payment_fee"]} step="0.01" min="0"/>
                </div>
                <div class="field">
                  <label>Card Replacement Fee</label>
                  <input type="number" name="logo[card_replacement_fee]" value={@form_data["card_replacement_fee"]} step="0.01" min="0"/>
                </div>
              </div>
            </div>
            <div class="form-section">
              <div class="form-section-title">Transaction Fees</div>
              <div class="form-grid">
                <div class="field">
                  <label>Cash Advance Fee (%)</label>
                  <input type="number" name="logo[cash_advance_fee_percent]" value={@form_data["cash_advance_fee_percent"]} step="0.01" min="0"/>
                  <p class="hint">Percentage of cash advance amount.</p>
                </div>
                <div class="field">
                  <label>Cash Advance Fee (minimum)</label>
                  <input type="number" name="logo[cash_advance_fee_min]" value={@form_data["cash_advance_fee_min"]} step="0.01" min="0"/>
                  <p class="hint">Minimum flat fee regardless of percentage.</p>
                </div>
                <div class="field">
                  <label>Foreign Transaction Fee (%)</label>
                  <input type="number" name="logo[foreign_transaction_fee_percent]" value={@form_data["foreign_transaction_fee_percent"]} step="0.01" min="0"/>
                  <p class="hint">% surcharge on non-domestic currency transactions.</p>
                </div>
              </div>
            </div>
          </div>

          <!-- Step 4: Billing & Auth Channels -->
          <div style={"#{if @current_step != 4, do: "display:none"}"}>
            <div class="form-section" style="padding-top:0;border-top:none;">
              <div class="form-section-title">Minimum Payment</div>
              <div class="form-grid">
                <div class="field">
                  <label>Minimum Payment % of Balance</label>
                  <input type="number" name="logo[min_payment_pct]" value={@form_data["min_payment_pct"]} step="0.01" min="0" max="100"/>
                </div>
                <div class="field">
                  <label>Minimum Payment Floor Amount</label>
                  <input type="number" name="logo[min_payment_floor]" value={@form_data["min_payment_floor"]} step="0.01" min="0"/>
                </div>
                <div class="field">
                  <label>Minimum Payment Calculation</label>
                  <select name="logo[min_payment_calculation]">
                    <%= for {label, val} <- @mp do %>
                      <option value={val} selected={@form_data["min_payment_calculation"] == val}><%= label %></option>
                    <% end %>
                  </select>
                </div>
                <div class="field">
                  <label>Grace Days</label>
                  <input type="number" name="logo[grace_days]" value={@form_data["grace_days"]} min="0" max="60"/>
                  <p class="hint">Days after statement before interest accrues on new purchases.</p>
                </div>
                <div class="field">
                  <label>Payment Due Days</label>
                  <input type="number" name="logo[payment_due_days]" value={@form_data["payment_due_days"]} min="0" max="60"/>
                  <p class="hint">Days after statement cut that payment is due.</p>
                </div>
                <div class="field">
                  <label>Cash Limit (% of Credit Limit)</label>
                  <input type="number" name="logo[cash_limit_pct]" value={@form_data["cash_limit_pct"]} step="0.01" min="0" max="100"/>
                </div>
                <div class="field">
                  <label>Statement Cycle Length (days)</label>
                  <input type="number" name="logo[statement_cycle_days]" value={@form_data["statement_cycle_days"]} min="28" max="31"/>
                </div>
              </div>
            </div>

            <div class="form-section">
              <div class="form-section-title">Overlimit Policy</div>
              <div class="form-grid">
                <div>
                  <div class="checkbox-row">
                    <input type="checkbox" id="ov_allow" name="logo[overlimit_allowed]" value="true"
                      checked={@form_data["overlimit_allowed"] == "true"}/>
                    <label for="ov_allow">Allow Overlimit Transactions
                      <span class="sublabel">Permit transactions that would exceed the credit limit.</span>
                    </label>
                  </div>
                </div>
                <div class="field">
                  <label>Overlimit Tolerance (%)</label>
                  <input type="number" name="logo[overlimit_tolerance_pct]" value={@form_data["overlimit_tolerance_pct"]} step="0.01" min="0" max="50"/>
                  <p class="hint">Maximum % above credit limit that will be approved.</p>
                </div>
              </div>
            </div>

            <div class="form-section">
              <div class="form-section-title">Authorisation Channel Flags</div>
              <div class="form-grid">
                <div>
                  <div class="checkbox-row">
                    <input type="checkbox" id="ch_ecom" name="logo[ecom_enabled]" value="true" checked={@form_data["ecom_enabled"] == "true"}/>
                    <label for="ch_ecom">eCommerce (CNP)
                      <span class="sublabel">Online / card-not-present transactions.</span>
                    </label>
                  </div>
                  <div class="checkbox-row">
                    <input type="checkbox" id="ch_atm" name="logo[atm_enabled]" value="true" checked={@form_data["atm_enabled"] == "true"}/>
                    <label for="ch_atm">ATM Cash Withdrawals</label>
                  </div>
                  <div class="checkbox-row">
                    <input type="checkbox" id="ch_intl" name="logo[intl_enabled]" value="true" checked={@form_data["intl_enabled"] == "true"}/>
                    <label for="ch_intl">International Transactions
                      <span class="sublabel">Outside home country.</span>
                    </label>
                  </div>
                  <div class="checkbox-row">
                    <input type="checkbox" id="ch_cl" name="logo[contactless_enabled]" value="true" checked={@form_data["contactless_enabled"] == "true"}/>
                    <label for="ch_cl">Contactless / NFC</label>
                  </div>
                </div>
                <div>
                  <div class="checkbox-row">
                    <input type="checkbox" id="ch_rec" name="logo[recurring_enabled]" value="true" checked={@form_data["recurring_enabled"] == "true"}/>
                    <label for="ch_rec">Recurring / Subscription Payments</label>
                  </div>
                  <div class="checkbox-row">
                    <input type="checkbox" id="ch_moto" name="logo[moto_enabled]" value="true" checked={@form_data["moto_enabled"] == "true"}/>
                    <label for="ch_moto">MOTO (Mail/Phone Order)</label>
                  </div>
                  <div class="checkbox-row">
                    <input type="checkbox" id="ch_qc" name="logo[quasi_cash_enabled]" value="true" checked={@form_data["quasi_cash_enabled"] == "true"}/>
                    <label for="ch_qc">Quasi-Cash Transactions
                      <span class="sublabel">Money orders, casino chips, etc.</span>
                    </label>
                  </div>
                  <div class="checkbox-row">
                    <input type="checkbox" id="ch_cb" name="logo[cash_back_enabled]" value="true" checked={@form_data["cash_back_enabled"] == "true"}/>
                    <label for="ch_cb">Cashback at POS</label>
                  </div>
                </div>
              </div>
            </div>

            <div class="form-section">
              <div class="form-section-title">Card & Chip Configuration</div>
              <div class="form-grid">
                <div>
                  <div class="checkbox-row">
                    <input type="checkbox" id="cc_chip" name="logo[chip_enabled]" value="true" checked={@form_data["chip_enabled"] == "true"}/>
                    <label for="cc_chip">EMV Chip Enabled</label>
                  </div>
                  <div class="checkbox-row">
                    <input type="checkbox" id="cc_mag" name="logo[mag_stripe_enabled]" value="true" checked={@form_data["mag_stripe_enabled"] == "true"}/>
                    <label for="cc_mag">Magnetic Stripe Enabled</label>
                  </div>
                  <div class="checkbox-row">
                    <input type="checkbox" id="cc_pin" name="logo[pin_required]" value="true" checked={@form_data["pin_required"] == "true"}/>
                    <label for="cc_pin">PIN Required for Chip Transactions</label>
                  </div>
                  <div class="checkbox-row">
                    <input type="checkbox" id="cc_supp" name="logo[supplementary_cards_allowed]" value="true" checked={@form_data["supplementary_cards_allowed"] == "true"}/>
                    <label for="cc_supp">Supplementary Cards Allowed</label>
                  </div>
                </div>
                <div>
                  <div class="field">
                    <label>Card Validity</label>
                    <select name="logo[card_validity_years]">
                      <%= for {label, val} <- @cv do %>
                        <option value={val} selected={@form_data["card_validity_years"] == val}><%= label %></option>
                      <% end %>
                    </select>
                  </div>
                  <div class="field mt-4">
                    <label>Max Supplementary Cards</label>
                    <select name="logo[supplementary_card_limit]">
                      <%= for {label, val} <- @sl do %>
                        <option value={val} selected={@form_data["supplementary_card_limit"] == val}><%= label %></option>
                      <% end %>
                    </select>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <!-- Step 5: Limits & STIP -->
          <div style={"#{if @current_step != 5, do: "display:none"}"}>
            <div class="form-section" style="padding-top:0;border-top:none;">
              <div class="form-section-title">Credit Limit Bounds</div>
              <p class="text-sm text-muted mb-4">Individual cardholder limits are set at account level; these are the product-level floor and ceiling.</p>
              <div class="form-grid-3">
                <div class="field">
                  <label>Minimum Credit Limit</label>
                  <input type="number" name="logo[credit_limit_min]" value={@form_data["credit_limit_min"]} step="0.01" min="0" placeholder="e.g. 500.00"/>
                </div>
                <div class="field">
                  <label>Default Credit Limit</label>
                  <input type="number" name="logo[credit_limit_default]" value={@form_data["credit_limit_default"]} step="0.01" min="0" placeholder="e.g. 5000.00"/>
                </div>
                <div class="field">
                  <label>Maximum Credit Limit</label>
                  <input type="number" name="logo[credit_limit_max]" value={@form_data["credit_limit_max"]} step="0.01" min="0" placeholder="e.g. 500000.00"/>
                </div>
              </div>
            </div>

            <div class="form-section">
              <div class="form-section-title">STIP — Stand-In Processing</div>
              <p class="text-sm text-muted mb-4">STIP allows the switch to approve transactions offline when host connectivity is degraded.</p>
              <div class="form-grid">
                <div>
                  <div class="checkbox-row">
                    <input type="checkbox" id="stip_on" name="logo[stip_enabled]" value="true" checked={@form_data["stip_enabled"] == "true"}/>
                    <label for="stip_on">Enable STIP Stand-In Processing
                      <span class="sublabel">Automatically approve low-risk transactions offline.</span>
                    </label>
                  </div>
                </div>
                <div class="field">
                  <label>STIP Floor Limit (auto-approve below)</label>
                  <input type="number" name="logo[stip_floor_limit]" value={@form_data["stip_floor_limit"]} step="0.01" min="0"/>
                  <p class="hint">Transactions below this amount are auto-approved in STIP mode.</p>
                </div>
                <div class="field">
                  <label>STIP Maximum Transaction Amount</label>
                  <input type="number" name="logo[stip_max_amount]" value={@form_data["stip_max_amount"]} step="0.01" min="0"/>
                  <p class="hint">Hard cap on STIP-approved transaction amount.</p>
                </div>
              </div>
            </div>
          </div>

        </div>
        <!-- Step navigation buttons -->
        <div class="card-footer">
          <button :if={@current_step > 1} type="button"
            phx-click="step_prev" phx-target={@myself} class="btn btn-secondary">
            ← Previous
          </button>
          <button type="button" phx-click="logo_cancel" phx-target={@myself} class="btn btn-secondary">
            Cancel
          </button>
          <div style="margin-left:auto;display:flex;gap:10px;">
            <button :if={@current_step < length(@steps)} type="button"
              phx-click="step_next" phx-target={@myself} class="btn btn-secondary">
              Next →
            </button>
            <button :if={@current_step == length(@steps)} type="submit" class="btn btn-primary">
              💾 <%= if @is_new, do: "Create Product", else: "Save Changes" %>
            </button>
          </div>
        </div>
      </div>
    </form>
    """
  end

  defp render_plans(assigns) do
    ~H"""
    <div>
      <%!-- Header --%>
      <div style="display:flex;align-items:center;gap:12px;margin-bottom:20px;">
        <button phx-click="plan_back" phx-target={@myself} class="btn btn-secondary">
          ← Back to Logos
        </button>
        <div>
          <div style="font-size:16px;font-weight:700;">Plan Segments — Logo <span class="mono"><%= @plans_logo.logo_id %></span></div>
          <div style="font-size:12px;color:var(--text-secondary);"><%= @plans_logo.description %></div>
        </div>
        <button :if={not @plan_form_open && @can_edit} phx-click="plan_new" phx-target={@myself}
          class="btn btn-primary" style="margin-left:auto;">
          + New Plan
        </button>
      </div>

      <%!-- Result banner --%>
      <%= if @plan_result do %>
        <% {kind, msg} = @plan_result %>
        <.alert kind={kind} message={msg} />
      <% end %>

      <%!-- Plan create/edit form --%>
      <%= if @plan_form_open do %>
        <div class="card" style="margin-bottom:20px;">
          <div style="font-size:14px;font-weight:700;margin-bottom:16px;">
            <%= if @plan_editing, do: "Edit Plan #{@plan_editing.plan_id}", else: "New Plan Segment" %>
          </div>
          <form phx-submit="plan_save" phx-change="plan_change" phx-target={@myself}>
            <%!-- Hidden carry-forward fields --%>
            <input type="hidden" name="plan[logo_id]"  value={@plan_form_data["logo_id"]}/>
            <input type="hidden" name="plan[sys_id]"   value={@plan_form_data["sys_id"]}/>
            <input type="hidden" name="plan[bank_id]"  value={@plan_form_data["bank_id"]}/>

            <div class="form-grid-2">
              <div class="form-group">
                <label class="form-label">Plan ID * <span class="form-hint">(4–8 chars, e.g. RET1)</span></label>
                <input type="text" class="input mono" name="plan[plan_id]"
                  value={@plan_form_data["plan_id"]} maxlength="8" required
                  readonly={not is_nil(@plan_editing)}/>
              </div>
              <div class="form-group">
                <label class="form-label">Plan Type *</label>
                <select class="input" name="plan[plan_type]" required>
                  <%= for {label, val} <- [{"RETAIL — Standard purchase","RETAIL"},{"CASH — Cash advance","CASH"},{"EMI — Equal monthly instalment","EMI"},{"BALANCE_TRANSFER — Balance transfer","BALANCE_TRANSFER"}] do %>
                    <option value={val} selected={@plan_form_data["plan_type"] == val}><%= label %></option>
                  <% end %>
                </select>
              </div>
              <div class="form-group">
                <label class="form-label">APR (%) *</label>
                <input type="number" class="input" name="plan[apr]"
                  value={@plan_form_data["apr"]} step="0.01" min="0" required/>
              </div>
              <div class="form-group">
                <label class="form-label">Promo APR (%)</label>
                <input type="number" class="input" name="plan[promo_apr]"
                  value={@plan_form_data["promo_apr"]} step="0.01" min="0"
                  placeholder="Leave blank if no promo rate"/>
              </div>
              <div class="form-group">
                <label class="form-label">Promo Expiry Date <span class="form-hint">(required if Promo APR set)</span></label>
                <input type="date" class="input" name="plan[promo_expiry_date]"
                  value={@plan_form_data["promo_expiry_date"]}/>
              </div>
              <div class="form-group">
                <label class="form-label">Grace Period Eligible</label>
                <select class="input" name="plan[grace_eligible]">
                  <option value="true"  selected={@plan_form_data["grace_eligible"] == "true"}>Yes</option>
                  <option value="false" selected={@plan_form_data["grace_eligible"] == "false"}>No</option>
                </select>
              </div>
              <div class="form-group">
                <label class="form-label">Min Payment % <span class="form-hint">(overrides LOGO default)</span></label>
                <input type="number" class="input" name="plan[min_payment_pct]"
                  value={@plan_form_data["min_payment_pct"]} step="0.01" min="0"
                  placeholder="Leave blank to use LOGO default"/>
              </div>
              <div class="form-group">
                <label class="form-label">Payment Priority * <span class="form-hint">(1=Fees … 5=EMI)</span></label>
                <input type="number" class="input" name="plan[payment_priority]"
                  value={@plan_form_data["payment_priority"]} min="1" max="99" required/>
              </div>
              <div class="form-group">
                <label class="form-label">Statement Order</label>
                <input type="number" class="input" name="plan[statement_order]"
                  value={@plan_form_data["statement_order"]} min="1"/>
              </div>
              <div class="form-group">
                <label class="form-label">EMI Tenor (months) <span class="form-hint">(EMI plan type only)</span></label>
                <input type="number" class="input" name="plan[emi_tenor_months]"
                  value={@plan_form_data["emi_tenor_months"]} min="1" max="360"
                  placeholder="e.g. 12"/>
              </div>
              <div class="form-group">
                <label class="form-label">Active</label>
                <select class="input" name="plan[active]">
                  <option value="true"  selected={@plan_form_data["active"] == "true"}>Active</option>
                  <option value="false" selected={@plan_form_data["active"] == "false"}>Inactive</option>
                </select>
              </div>
              <div class="form-group" style="grid-column:1/-1;">
                <label class="form-label">Description</label>
                <input type="text" class="input" name="plan[description]"
                  value={@plan_form_data["description"]} maxlength="100"
                  placeholder="e.g. Standard retail purchase plan"/>
              </div>
            </div>
            <div class="card-footer">
              <button type="button" phx-click="plan_cancel" phx-target={@myself}
                class="btn btn-secondary">Cancel</button>
              <button type="submit" class="btn btn-primary">
                💾 <%= if @plan_editing, do: "Update Plan", else: "Create Plan" %>
              </button>
            </div>
          </form>
        </div>
      <% end %>

      <%!-- Plan list --%>
      <%= if @logo_plans == [] do %>
        <div class="empty-row" style="padding:40px;text-align:center;color:var(--text-secondary);">
          <div style="font-size:28px;margin-bottom:8px;">📊</div>
          No plan segments yet. A LOGO requires at least one RETAIL and one CASH plan before accounts can be created.
        </div>
      <% else %>
        <div class="card">
          <div class="table-wrap">
            <table class="data-table">
              <colgroup>
                <col style="width:90px"/>
                <col style="width:160px"/>
                <col style="width:80px"/>
                <col style="width:80px"/>
                <col style="width:110px"/>
                <col style="width:60px"/>
                <col style="width:100px"/>
                <col style="width:60px"/>
                <col style="width:80px"/>
                <col style="width:60px"/>
                <col/>
              </colgroup>
              <thead>
                <tr>
                  <th>Plan ID</th>
                  <th>Type</th>
                  <th>APR</th>
                  <th>Promo APR</th>
                  <th>Promo Expiry</th>
                  <th>Grace</th>
                  <th>Min Pay %</th>
                  <th>Priority</th>
                  <th>EMI Tenor</th>
                  <th>Active</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for p <- @logo_plans do %>
                  <% eff = PlanSegment.effective_apr(p) %>
                  <tr>
                    <td class="mono fw-600"><%= p.plan_id %></td>
                    <td>
                      <span class={"badge #{plan_badge(p.plan_type)}"}>
                        <%= p.plan_type %>
                      </span>
                    </td>
                    <td class="mono"><%= eff %>%</td>
                    <td class="mono"><%= if p.promo_apr, do: "#{p.promo_apr}%", else: "—" %></td>
                    <td><%= if p.promo_expiry_date, do: Date.to_string(p.promo_expiry_date), else: "—" %></td>
                    <td><%= if p.grace_eligible, do: "✓", else: "✗" %></td>
                    <td class="mono"><%= if p.min_payment_pct, do: "#{p.min_payment_pct}%", else: "—" %></td>
                    <td><%= p.payment_priority %></td>
                    <td><%= if p.emi_tenor_months, do: "#{p.emi_tenor_months}m", else: "—" %></td>
                    <td>
                      <span class={"badge #{if p.active, do: "badge-green", else: "badge-gray"}"}>
                        <%= if p.active, do: "Active", else: "Off" %>
                      </span>
                    </td>
                    <td>
                      <div class="actions">
                        <button :if={@can_edit} phx-click="plan_edit" phx-target={@myself}
                          phx-value-id={p.plan_id} class="btn btn-sm btn-secondary">Edit</button>
                        <button :if={@can_edit} phx-click="plan_delete" phx-target={@myself}
                          phx-value-id={p.plan_id} class="btn btn-sm btn-danger"
                          data-confirm={"Delete plan #{p.plan_id}?"}>Delete</button>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp plan_badge("RETAIL"),           do: "badge-green"
  defp plan_badge("CASH"),             do: "badge-yellow"
  defp plan_badge("EMI"),              do: "badge-blue"
  defp plan_badge("BALANCE_TRANSFER"), do: "badge-purple"
  defp plan_badge(_),                  do: "badge-gray"
end
