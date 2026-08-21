defmodule VmuCoreWeb.Live.Admin.CustomerComponent do
  @moduledoc """
  Phase 3 — Customer Information File (CIF) LiveComponent.

  Manages cms_customers records in the admin UI.
  Hierarchy position: SYS → BANK → Customer → Account → Card

  Features:
  - Customer list with real-time search (name, email, mobile, ID number)
  - KYC status filters and summary tiles
  - Create / Edit form (4-section 2-pane layout)
  - KYC workflow: PENDING → VERIFIED / REJECTED
  - Customer detail view with linked accounts
  - Corporate customer fields for BUSINESS / CORPORATE tiers
  """
  use Phoenix.LiveComponent

  import Ecto.Query, warn: false
  import VmuCoreWeb.AdminUI
  import VmuCoreWeb.Components.AgGrid

  alias VmuCore.{Repo}
  alias VmuCore.Shared.{Customer, BankParameter, SysParameter}
  alias VmuCore.Shared.ModuleConfigEngine
  alias VmuCore.ASM.Authz
  alias VmuCore.CMS.Arrangements
  alias VmuCoreWeb.Live.Admin.{AccountComponent, DebitComponent, PrepaidComponent, HcsComponent, WalletComponent}

  @id_types [
    {"-- Select ID Type --", ""},
    {"Emirates ID",     "EMIRATES_ID"},
    {"Passport",        "PASSPORT"},
    {"National ID",     "NATIONAL_ID"},
    {"Driving License", "DRIVING_LICENSE"},
    {"Iqama (KSA)",     "IQAMA"},
    {"Civil ID",        "CIVIL_ID"},
    {"Other",           "OTHER"}
  ]

  @dial_codes [
    {"+971 UAE",     "971"},  {"+966 Saudi Arabia", "966"}, {"+973 Bahrain", "973"},
    {"+965 Kuwait",  "965"},  {"+968 Oman",          "968"}, {"+974 Qatar",   "974"},
    {"+20  Egypt",   "20"},   {"+962 Jordan",         "962"}, {"+961 Lebanon", "961"},
    {"+92  Pakistan","92"},   {"+91  India",          "91"},  {"+880 Bangladesh","880"},
    {"+94  Sri Lanka","94"},  {"+63  Philippines",    "63"},  {"+62  Indonesia", "62"},
    {"+60  Malaysia", "60"},  {"+65  Singapore",      "65"},  {"+66  Thailand",  "66"},
    {"+44  UK",       "44"},  {"+1   USA/Canada",     "1"},   {"+49  Germany",   "49"},
    {"+33  France",   "33"},  {"+Other",              "OTHER"}
  ]

  @nationalities [
    {"-- Select Nationality --", ""},
    {"UAE National",          "AE"}, {"Saudi Arabian",      "SA"}, {"Bahraini",          "BH"},
    {"Kuwaiti",               "KW"}, {"Qatari",             "QA"}, {"Omani",             "OM"},
    {"Egyptian",              "EG"}, {"Jordanian",          "JO"}, {"Lebanese",          "LB"},
    {"Pakistani",             "PK"}, {"Indian",             "IN"}, {"Bangladeshi",       "BD"},
    {"Sri Lankan",            "LK"}, {"Filipino",           "PH"}, {"Indonesian",        "ID"},
    {"Malaysian",             "MY"}, {"Singaporean",        "SG"}, {"American",          "US"},
    {"British",               "GB"}, {"German",             "DE"}, {"French",            "FR"},
    {"Australian",            "AU"}, {"Canadian",           "CA"}, {"South African",     "ZA"},
    {"Other",                 "XX"}
  ]

  @countries_iso2 [
    {"-- Select Country --", ""},
    {"UAE",                  "AE"}, {"Saudi Arabia",       "SA"}, {"Bahrain",           "BH"},
    {"Kuwait",               "KW"}, {"Qatar",              "QA"}, {"Oman",              "OM"},
    {"Egypt",                "EG"}, {"Jordan",             "JO"}, {"Lebanon",           "LB"},
    {"Pakistan",             "PK"}, {"India",              "IN"}, {"Bangladesh",        "BD"},
    {"Sri Lanka",            "LK"}, {"Philippines",        "PH"}, {"Indonesia",         "ID"},
    {"Malaysia",             "MY"}, {"Singapore",          "SG"}, {"Thailand",          "TH"},
    {"United Kingdom",       "GB"}, {"United States",      "US"}, {"Germany",           "DE"},
    {"France",               "FR"}, {"Australia",          "AU"}, {"Canada",            "CA"},
    {"South Africa",         "ZA"}, {"Other",              "XX"}
  ]

  # ── Mount / Update ──────────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       mode:         :list,
       editing:      nil,
       viewing:      nil,
       result:       nil,
       form_data:    %{},
       cust_section: 1,
       search:       "",
       kyc_filter:   "",
       tier_filter:  "",
       bank_filter:  "",
       linked_accounts: [],
       arrangements: [],
       detail_tab: 1,
       arr_family: :credit,
       arr_selected_ref: nil,
       current_operator: nil,
       can_edit: false,
       can_create: false
     )
     |> load_options()
     |> load_customers()}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       can_edit:   Authz.can?(assigns[:current_operator], "customer", "edit"),
       can_create: Authz.can?(assigns[:current_operator], "customer", "create")
     )}
  end

  defp load_options(socket) do
    orgs = Repo.all(BankParameter) |> Enum.map(&{"#{&1.bank_id} — #{&1.org_name || &1.description}", &1.bank_id})
    syss = Repo.all(SysParameter)
    assign(socket, bank_options: [{"-- All Banks --", ""} | orgs], sys_records: syss)
  end

  defp load_customers(socket) do
    s  = socket.assigns

    # Bank data-scope (ASM-P2.4): a scoped operator's queries are forced to
    # their BANK regardless of the UI filter
    bank_filter =
      case Map.get(s, :current_operator) do
        %VmuCore.ASM.Operator{} = op ->
          VmuCore.ASM.Authz.bank_scope(op) || s.bank_filter

        _ ->
          s.bank_filter
      end

    customers = search_customers(s.search, s.kyc_filter, s.tier_filter, bank_filter)
    assign(socket, customers: customers)
  end

  defp search_customers(search, kyc_filter, tier_filter, bank_filter) do
    query = from(c in Customer, order_by: [desc: c.inserted_at], limit: 100)

    query =
      if search != "" do
        term = "%#{search}%"
        where(query, [c],
          ilike(c.first_name, ^term) or
          ilike(c.last_name,  ^term) or
          ilike(fragment("? || ' ' || ?", c.first_name, c.last_name), ^term) or
          ilike(c.email,      ^term) or
          ilike(c.mobile_number, ^term) or
          ilike(c.id_number,  ^term)
        )
      else
        query
      end

    query = if kyc_filter  != "", do: where(query, [c], c.kyc_status    == ^kyc_filter),  else: query
    query = if tier_filter != "", do: where(query, [c], c.customer_tier == ^tier_filter), else: query
    query = if bank_filter != "", do: where(query, [c], c.bank_id       == ^bank_filter), else: query

    Repo.all(query)
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  # Real bug found live (2026-07-28): phx-keyup always sends the input's
  # live-typed text under "value" automatically — the old phx-value-q
  # binding just re-sent the stale @search assign from the last render.
  # This main customer list search never actually worked as a result.
  @impl true
  def handle_event("cust_search", %{"value" => q}, socket) do
    {:noreply, socket |> assign(search: q) |> load_customers()}
  end

  def handle_event("cust_filter", params, socket) do
    socket =
      socket
      |> assign(
        kyc_filter:  Map.get(params, "kyc",  socket.assigns.kyc_filter),
        tier_filter: Map.get(params, "tier", socket.assigns.tier_filter),
        bank_filter: Map.get(params, "bank", socket.assigns.bank_filter)
      )
      |> load_customers()
    {:noreply, socket}
  end

  def handle_event("cust_new", _params, socket) do
    if socket.assigns.can_create do
      sys_id  = case socket.assigns.sys_records do [s | _] -> s.sys_id; _ -> "" end
      bank_id = case socket.assigns.bank_options do
        [_, {_, bid} | _] -> bid
        _                 -> ""
      end
      fd = %{
        "sys_id"       => sys_id,  "bank_id"    => bank_id,
        "first_name"   => "",      "last_name"  => "",
        "date_of_birth"=> "",      "nationality"=> "",
        "customer_tier"=> "RETAIL",
        "email"        => "",      "mobile_country" => "971",
        "mobile_number"=> "",
        "address_line1"=> "",      "address_line2" => "",
        "city"         => "",      "postal_code"   => "",
        "country"      => "",
        "id_type"      => "",      "id_number"  => "",
        "id_expiry"    => "",      "kyc_status" => "PENDING",
        "company_name" => "",      "registration_number"  => "",
        "registration_country" => "", "registration_date"  => ""
      }
      {:noreply, assign(socket, mode: :form, editing: nil, form_data: fd, result: nil, cust_section: 1)}
    else
      {:noreply, assign(socket, result: {:error, "Your role cannot create customers."})}
    end
  end

  def handle_event("cust_edit", %{"id" => id}, socket) do
    if socket.assigns.can_edit do
      cust = Enum.find(socket.assigns.customers, &(to_string(&1.customer_id) == id))
      fd   = if cust, do: cust_to_form(cust), else: %{}
      {:noreply, assign(socket, mode: :form, editing: cust, form_data: fd, result: nil, cust_section: 1)}
    else
      {:noreply, assign(socket, result: {:error, "Your role cannot edit customers."})}
    end
  end

  def handle_event("cust_view", %{"id" => id}, socket) do
    # PII view audit (ASM-P4.2, FR-ASM-015): who opened which customer, when
    VmuCore.ASM.AuditLog.record(
      Map.get(socket.assigns, :current_operator), "customer_pii_view", id)

    cust = Enum.find(socket.assigns.customers, &(to_string(&1.customer_id) == id))
    if cust do
      accounts = Customer.list_accounts_for(cust.customer_id)
      arrangements = Arrangements.search(%{customer_id: cust.customer_id})
      arr_family = default_arr_family(arrangements)
      {:noreply, assign(socket, mode: :detail, detail_tab: 1, arr_family: arr_family,
                         arr_selected_ref: first_ref_for_family(arrangements, arr_family),
                         viewing: cust, linked_accounts: accounts, arrangements: arrangements, result: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cust_back", _params, socket) do
    {:noreply, socket |> assign(mode: :list, viewing: nil, editing: nil) |> load_customers()}
  end

  def handle_event("cust_edit_from_detail", _params, socket) do
    if socket.assigns.can_edit do
      cust = socket.assigns.viewing
      fd   = cust_to_form(cust)
      {:noreply, assign(socket, mode: :form, editing: cust, form_data: fd, result: nil, cust_section: 1)}
    else
      {:noreply, assign(socket, result: {:error, "Your role cannot edit customers."})}
    end
  end

  def handle_event("cust_section", %{"s" => s}, socket) do
    {:noreply, assign(socket, cust_section: String.to_integer(s))}
  end

  def handle_event("detail_tab", %{"t" => t}, socket) do
    {:noreply, assign(socket, detail_tab: String.to_integer(t))}
  end

  # Portfolio-in-place sub-tabs (2026-07-28) — switching product family
  # auto-selects that family's first arrangement (if any) so a customer
  # with exactly one card of that type shows its detail immediately,
  # matching the reference design's single-card families.
  def handle_event("arr_family", %{"f" => f}, socket) do
    family = String.to_existing_atom(f)
    first_ref = first_ref_for_family(socket.assigns.arrangements, family)

    {:noreply, assign(socket, arr_family: family, arr_selected_ref: first_ref)}
  end

  def handle_event("arr_select", %{"ref" => ref}, socket) do
    {:noreply, assign(socket, arr_selected_ref: ref)}
  end

  def handle_event("cust_change", %{"cust" => params}, socket) do
    {:noreply, assign(socket, form_data: params)}
  end

  def handle_event("cust_save", %{"cust" => params}, socket) do
    creating? = is_nil(socket.assigns.editing)
    allowed?  = if creating?, do: socket.assigns.can_create, else: socket.assigns.can_edit

    if allowed? do
      attrs = build_cust_attrs(params)

      result =
        case socket.assigns.editing do
          nil  ->
            %Customer{} |> Customer.changeset(attrs) |> Repo.insert()
          cust ->
            cust |> Customer.changeset(attrs) |> Repo.update()
        end

      case result do
        {:ok, saved} ->
          action = if socket.assigns.editing, do: "updated", else: "created"
          accounts = Customer.list_accounts_for(saved.customer_id)
          arrangements = Arrangements.search(%{customer_id: saved.customer_id})
          arr_family = default_arr_family(arrangements)
          {:noreply, socket
            |> load_customers()
            |> assign(mode: :detail, detail_tab: 1, arr_family: arr_family,
                      arr_selected_ref: first_ref_for_family(arrangements, arr_family),
                      editing: nil, viewing: saved,
                      linked_accounts: accounts, arrangements: arrangements,
                      result: {:ok, "Customer #{action}."})}

        {:error, cs} ->
          msg = Enum.map_join(cs.errors, "; ", fn {f, {m, _}} -> "#{f}: #{m}" end)
          {:noreply, assign(socket, result: {:error, "Save failed — #{msg}"})}
      end
    else
      {:noreply, assign(socket, result: {:error, "Your role cannot save this customer."})}
    end
  end

  def handle_event("cust_delete", %{"id" => id}, socket) do
    if socket.assigns.can_edit do
      cust = Enum.find(socket.assigns.customers, &(to_string(&1.customer_id) == id))
      if cust, do: Repo.delete(cust)
      {:noreply, socket |> load_customers() |> assign(mode: :list, result: {:ok, "Customer deleted."})}
    else
      {:noreply, assign(socket, result: {:error, "Your role cannot delete customers."})}
    end
  end

  def handle_event("kyc_verify", %{"id" => id}, socket) do
    update_kyc(id, "VERIFIED", NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second), socket)
  end

  def handle_event("kyc_reject", %{"id" => id}, socket) do
    update_kyc(id, "REJECTED", nil, socket)
  end

  def handle_event("kyc_reset", %{"id" => id}, socket) do
    update_kyc(id, "PENDING", nil, socket)
  end

  defp update_kyc(id, status, verified_at, socket) do
    cust = Repo.get(Customer, id)
    if cust do
      attrs = %{kyc_status: status, kyc_verified_at: verified_at}
      case cust |> Customer.changeset(attrs) |> Repo.update() do
        {:ok, updated} ->
          accounts = Customer.list_accounts_for(updated.customer_id)
          arrangements = Arrangements.search(%{customer_id: updated.customer_id})
          {:noreply, socket
            |> load_customers()
            |> assign(viewing: updated, linked_accounts: accounts, arrangements: arrangements,
                      result: {:ok, "KYC status updated to #{status}."})}
        {:error, _} ->
          {:noreply, assign(socket, result: {:error, "Failed to update KYC status."})}
      end
    else
      {:noreply, assign(socket, result: {:error, "Customer not found."})}
    end
  end

  # ── Data helpers ─────────────────────────────────────────────────────────────

  defp cust_to_form(%Customer{} = c) do
    %{
      "sys_id"               => c.sys_id,
      "bank_id"              => c.bank_id,
      "first_name"           => c.first_name,
      "last_name"            => c.last_name,
      "date_of_birth"        => date_s(c.date_of_birth),
      "nationality"          => c.nationality,
      "customer_tier"        => c.customer_tier || "RETAIL",
      "email"                => c.email,
      "mobile_country"       => c.mobile_country || "971",
      "mobile_number"        => c.mobile_number,
      "address_line1"        => c.address_line1,
      "address_line2"        => c.address_line2,
      "city"                 => c.city,
      "postal_code"          => c.postal_code,
      "country"              => c.country,
      "id_type"              => c.id_type,
      "id_number"            => c.id_number,
      "id_expiry"            => date_s(c.id_expiry),
      "kyc_status"           => c.kyc_status || "PENDING",
      "company_name"         => c.company_name,
      "registration_number"  => c.registration_number,
      "registration_country" => c.registration_country,
      "registration_date"    => date_s(c.registration_date)
    }
  end

  defp build_cust_attrs(p) do
    %{
      sys_id:               p["sys_id"],
      bank_id:              p["bank_id"],
      first_name:           p["first_name"],
      last_name:            p["last_name"],
      date_of_birth:        parse_date(p["date_of_birth"]),
      nationality:          nilify(p["nationality"]),
      customer_tier:        p["customer_tier"] || "RETAIL",
      email:                nilify(p["email"]),
      mobile_country:       nilify(p["mobile_country"]),
      mobile_number:        nilify(p["mobile_number"]),
      address_line1:        nilify(p["address_line1"]),
      address_line2:        nilify(p["address_line2"]),
      city:                 nilify(p["city"]),
      postal_code:          nilify(p["postal_code"]),
      country:              nilify(p["country"]),
      id_type:              nilify(p["id_type"]),
      id_number:            nilify(p["id_number"]),
      id_expiry:            parse_date(p["id_expiry"]),
      kyc_status:           p["kyc_status"] || "PENDING",
      company_name:         nilify(p["company_name"]),
      registration_number:  nilify(p["registration_number"]),
      registration_country: nilify(p["registration_country"]),
      registration_date:    parse_date(p["registration_date"])
    }
  end

  defp date_s(nil), do: ""
  defp date_s(%Date{} = d), do: Date.to_string(d)
  defp date_s(other), do: to_string(other)

  defp parse_date(""),  do: nil
  defp parse_date(nil), do: nil
  defp parse_date(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> d
      _        -> nil
    end
  end

  defp nilify(""), do: nil
  defp nilify(v),  do: v

  defp full_name(%Customer{first_name: f, last_name: l}), do: "#{f} #{l}"

  defp kyc_badge_class("VERIFIED"), do: "badge-green"
  defp kyc_badge_class("REJECTED"), do: "badge-red"
  defp kyc_badge_class(_),          do: "badge-yellow"

  defp tier_badge_class("PREMIUM"),   do: "badge-blue"
  defp tier_badge_class("CORPORATE"), do: "badge-blue"
  defp tier_badge_class(_),           do: "badge-gray"

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8) <> "…"
  defp short_id(_), do: "—"

  defp customer_row(c, can_edit, operator) do
    %{
      row_id: c.customer_id,
      customer_id: short_id(c.customer_id),
      name: full_name(c),
      dob: masked(date_s(c.date_of_birth), "cif.date_of_birth", c.sys_id, operator),
      bank_id: c.bank_id,
      email: c.email || "—",
      mobile: if(c.mobile_number, do: "+#{c.mobile_country} #{c.mobile_number}", else: "—"),
      id_document: "#{c.id_type} · #{masked(c.id_number, "cif.id_number", c.sys_id, operator)}",
      kyc_status: c.kyc_status || "PENDING",
      kyc_status_class: kyc_badge_class(c.kyc_status),
      tier: c.customer_tier || "RETAIL",
      tier_class: tier_badge_class(c.customer_tier),
      can_edit: can_edit
    }
  end

  # ── PII masking (asm.pii_masking_rules, Module Configuration Framework) ─────
  # Empty rules map (default) = unmasked, matching pre-existing behavior.

  defp masked(raw, field_key, sys_id, operator) do
    {:ok, rules} = ModuleConfigEngine.get("asm", "pii_masking_rules", sys_id)

    case Map.get(rules, field_key) do
      nil -> raw
      rule -> if unmasked_for?(operator, rule), do: raw, else: mask_pii(raw)
    end
  end

  defp unmasked_for?(%{role: "ADMIN"}, _rule), do: true
  defp unmasked_for?(operator, rule) do
    unmasked_roles = Map.get(rule, "unmasked_roles", [])
    operator != nil and operator.role in unmasked_roles
  end

  defp mask_pii(nil), do: nil
  defp mask_pii(value) do
    str = to_string(value)
    len = String.length(str)

    if len <= 4 do
      String.duplicate("*", len)
    else
      String.duplicate("*", len - 4) <> String.slice(str, -4, 4)
    end
  end

  # ── Render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns,
      id_types:       @id_types,
      dial_codes:     @dial_codes,
      nationalities:  @nationalities,
      countries_iso2: @countries_iso2
    )
    ~H"""
    <div id={@id}>
      <.page_header title="Customers (CIF)" subtitle="Customer Information File — individual and corporate cardholders">
        <:actions>
          <%= if @mode == :list && @can_create do %>
            <button phx-click="cust_new" phx-target={@myself} class="btn btn-primary">
              + New Customer
            </button>
          <% end %>
          <%= if @mode in [:form, :detail] do %>
            <button phx-click="cust_back" phx-target={@myself} class="btn btn-secondary">
              ← Back to List
            </button>
          <% end %>
        </:actions>
      </.page_header>

      <%= if @result do %>
        <% {kind, msg} = @result %>
        <.alert kind={kind} message={msg} />
      <% end %>

      <%= case @mode do %>
        <% :list   -> %> <.render_list {assigns} />
        <% :detail -> %> <.render_detail {assigns} />
        <% :form   -> %> <.render_form {assigns} />
        <% _       -> %> <p>Unknown mode.</p>
      <% end %>
    </div>
    """
  end

  # ── List view ───────────────────────────────────────────────────────────────

  defp render_list(assigns) do
    total    = length(assigns.customers)
    verified = Enum.count(assigns.customers, &(&1.kyc_status == "VERIFIED"))
    pending  = Enum.count(assigns.customers, &(&1.kyc_status == "PENDING"))
    rejected = Enum.count(assigns.customers, &(&1.kyc_status == "REJECTED"))
    assigns  = assign(assigns, total: total, verified: verified, pending: pending, rejected: rejected)
    ~H"""
    <!-- KYC summary tiles -->
    <div class="stat-grid" style="grid-template-columns:repeat(4,1fr);margin-bottom:20px;">
      <div class="stat-card">
        <div class="stat-label">Total Customers</div>
        <div class="stat-value"><%= @total %></div>
        <div class="stat-sub">in current filter</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">KYC Verified</div>
        <div class="stat-value" style="color:var(--success)"><%= @verified %></div>
        <div class="stat-sub">cleared for operations</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">KYC Pending</div>
        <div class="stat-value" style="color:var(--warning)"><%= @pending %></div>
        <div class="stat-sub">awaiting review</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">KYC Rejected</div>
        <div class="stat-value" style="color:var(--danger)"><%= @rejected %></div>
        <div class="stat-sub">review required</div>
      </div>
    </div>

    <!-- Search + Filters -->
    <div class="card" style="margin-bottom:16px;">
      <div class="card-body" style="padding:14px 20px;">
        <div style="display:grid;grid-template-columns:1fr auto auto auto;gap:12px;align-items:center;">
          <div style="position:relative;">
            <span style="position:absolute;left:10px;top:50%;transform:translateY(-50%);color:var(--text-muted);font-size:14px;">🔍</span>
            <input
              type="text"
              placeholder="Search by name, email, mobile or ID number…"
              value={@search}
              phx-keyup="cust_search"
              phx-target={@myself}
              phx-debounce="300"
              style="padding-left:32px;width:100%;"
            />
          </div>
          <select phx-change="cust_filter" phx-value-kyc="" phx-target={@myself}
            name="kyc" style="min-width:140px;">
            <option value="" selected={@kyc_filter == ""}>All KYC Status</option>
            <option value="PENDING"  selected={@kyc_filter == "PENDING"}>Pending</option>
            <option value="VERIFIED" selected={@kyc_filter == "VERIFIED"}>Verified</option>
            <option value="REJECTED" selected={@kyc_filter == "REJECTED"}>Rejected</option>
          </select>
          <select phx-change="cust_filter" phx-target={@myself}
            name="tier" style="min-width:130px;">
            <option value="" selected={@tier_filter == ""}>All Tiers</option>
            <option value="RETAIL"    selected={@tier_filter == "RETAIL"}>Retail</option>
            <option value="PREMIUM"   selected={@tier_filter == "PREMIUM"}>Premium</option>
            <option value="BUSINESS"  selected={@tier_filter == "BUSINESS"}>Business</option>
            <option value="CORPORATE" selected={@tier_filter == "CORPORATE"}>Corporate</option>
          </select>
          <select phx-change="cust_filter" phx-target={@myself}
            name="bank" style="min-width:160px;">
            <%= for {label, val} <- @bank_options do %>
              <option value={val} selected={@bank_filter == val}><%= label %></option>
            <% end %>
          </select>
        </div>
      </div>
    </div>

    <!-- Customer table -->
    <%= if @customers == [] do %>
      <.empty_state icon="👤" title="No Customers Found"
        message={if @search != "" or @kyc_filter != "" or @tier_filter != "", do: "No customers match your search filters. Try clearing the filters.", else: "No customers have been onboarded yet. Create your first customer record."}>
        <:actions>
          <button :if={@can_create} phx-click="cust_new" phx-target={@myself} class="btn btn-primary">
            + New Customer
          </button>
        </:actions>
      </.empty_state>
    <% else %>
      <div class="card">
        <.ag_grid
          id="customer-list-grid"
          empty_message="No customers found."
          columns={[
            %{field: "name", header: "Name", flex: 1},
            %{field: "dob", header: "DOB", width: 110},
            %{field: "bank_id", header: "Bank", type: "mono", width: 90},
            %{field: "customer_id", header: "Customer ID", type: "mono", width: 140},
            %{field: "email", header: "Email", flex: 1},
            %{field: "mobile", header: "Mobile", width: 140},
            %{field: "id_document", header: "ID Document", flex: 1},
            %{field: "kyc_status", header: "KYC Status", type: "badge", classField: "kyc_status_class", width: 120},
            %{field: "tier", header: "Tier", type: "badge", classField: "tier_class", width: 100},
            %{field: "actions", header: "", type: "actions", width: 140,
              actions: [
                %{label: "View", event: "cust_view", param: "row_id"},
                %{label: "Edit", event: "cust_edit", param: "row_id", whenField: "can_edit", whenValue: true}
              ]}
          ]}
          rows={Enum.map(@customers, &customer_row(&1, @can_edit, @current_operator))}
        />
        <div class="card-footer" style="justify-content:flex-start;">
          <span class="text-sm text-muted">
            Showing <%= length(@customers) %> customer<%= if length(@customers) != 1, do: "s" %>
            <%= if length(@customers) == 100, do: " (limited to 100 — refine your search)" %>
          </span>
        </div>
      </div>
    <% end %>
    """
  end

  # ── Detail view ─────────────────────────────────────────────────────────────

  defp render_detail(assigns) do
    cust = assigns.viewing
    is_corporate = cust.customer_tier in ["BUSINESS", "CORPORATE"]
    assigns = assign(assigns, cust: cust, is_corporate: is_corporate)
    ~H"""
    <!-- Detail header (2026-07-28b UI cleanup — identity + KYC actions
         combined into one compact card instead of two full cards each
         with their own header/padding; cuts the excess vertical space
         between the page title and the tabs below). -->
    <div class="card" style="margin-bottom:12px;">
      <div class="card-body" style="padding:16px 20px;display:grid;grid-template-columns:1fr auto;gap:24px;align-items:start;">
        <div style="display:flex;gap:16px;align-items:center;">
          <div style="width:44px;height:44px;border-radius:50%;background:var(--accent-light);display:flex;align-items:center;justify-content:center;font-size:18px;flex-shrink:0;">
            <%= if @is_corporate, do: "🏢", else: "👤" %>
          </div>
          <div>
            <div style="font-size:18px;font-weight:700;color:var(--text-primary);line-height:1.2;">
              <%= full_name(@cust) %>
            </div>
            <div style="font-size:11px;color:var(--text-muted);font-family:var(--font-mono);margin-top:2px;">
              CIF: <%= @cust.customer_id %>
            </div>
            <div style="margin-top:6px;display:flex;gap:6px;">
              <span class={"badge #{kyc_badge_class(@cust.kyc_status)}"}><%= @cust.kyc_status || "PENDING" %></span>
              <span class={"badge #{tier_badge_class(@cust.customer_tier)}"}><%= @cust.customer_tier || "RETAIL" %></span>
              <span class="badge badge-gray"><%= @cust.bank_id %></span>
            </div>
          </div>
        </div>
        <div style="display:flex;gap:8px;align-items:center;">
          <button :if={@can_edit} phx-click="cust_edit_from_detail" phx-target={@myself} class="btn btn-sm btn-secondary">
            Edit Customer
          </button>
          <button :if={@can_edit} phx-click="cust_delete" phx-target={@myself}
            phx-value-id={@cust.customer_id} class="btn btn-sm btn-danger"
            data-confirm={"Permanently delete customer #{full_name(@cust)}? This cannot be undone."}>
            Delete
          </button>
        </div>
      </div>

      <!-- Inline KYC action row — a slim divider strip rather than a
           second full card, since these are contextual actions on the
           identity above, not a separate information section. -->
      <div style="border-top:1px solid var(--border);padding:10px 20px;display:flex;gap:10px;align-items:center;flex-wrap:wrap;">
        <span class="text-sm text-muted" style="margin-right:4px;">KYC:</span>
        <%= if @cust.kyc_status != "VERIFIED" do %>
          <button phx-click="kyc_verify" phx-target={@myself}
            phx-value-id={@cust.customer_id}
            class="btn btn-sm btn-primary"
            style="background:var(--success);border-color:var(--success);"
            data-confirm={"Mark #{full_name(@cust)} as KYC VERIFIED?"}>
            ✓ Verify
          </button>
        <% end %>
        <%= if @cust.kyc_status != "REJECTED" do %>
          <button phx-click="kyc_reject" phx-target={@myself}
            phx-value-id={@cust.customer_id}
            class="btn btn-sm btn-danger"
            data-confirm={"Mark #{full_name(@cust)} as KYC REJECTED?"}>
            ✗ Reject
          </button>
        <% end %>
        <%= if @cust.kyc_status != "PENDING" do %>
          <button phx-click="kyc_reset" phx-target={@myself}
            phx-value-id={@cust.customer_id}
            class="btn btn-sm btn-secondary"
            data-confirm={"Reset KYC status for #{full_name(@cust)} back to PENDING?"}>
            ↺ Reset to Pending
          </button>
        <% end %>
        <%= if @cust.kyc_verified_at do %>
          <span class="text-sm text-muted" style="margin-left:4px;">
            Verified at <%= NaiveDateTime.to_string(@cust.kyc_verified_at) %>
          </span>
        <% end %>
      </div>
    </div>

    <!-- Detail tabs (2026-07-28 — replaces the old always-scrolled 2x2
         info grid + full-width Arrangements card with the same
         detail-tabs pattern AccountComponent already uses, so this page
         doesn't require scrolling through every section to find one). -->
    <div class="card" style="padding:0;overflow:hidden;">
      <div class="detail-tabs">
        <%= for {idx, label, icon} <- detail_tabs(@is_corporate) do %>
          <div class={"detail-tab#{if @detail_tab == idx, do: " active"}"}
            phx-click="detail_tab" phx-value-t={idx} phx-target={@myself}>
            <%= icon %> <%= label %>
          </div>
        <% end %>
      </div>
      <div style="padding:20px;">
        <%= case @detail_tab do %>
          <% 1 -> %> <%= tab_overview(assigns) %>
          <% 2 -> %> <%= tab_identity_kyc(assigns) %>
          <% 3 -> %> <%= tab_corporate(assigns) %>
          <% 4 -> %> <%= tab_arrangements(assigns) %>
          <% _ -> %> <p>Invalid tab.</p>
        <% end %>
      </div>
    </div>
    """
  end

  defp detail_tabs(is_corporate) do
    [{1, "Overview", "📋"}, {2, "Identity & KYC", "🪪"}] ++
      (if is_corporate, do: [{3, "Corporate", "🏢"}], else: []) ++
      [{4, "Arrangements", "🔗"}]
  end

  defp tab_overview(assigns) do
    ~H"""
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:20px;">
      <div class="card">
        <div class="card-header"><div class="card-title">Personal Information</div></div>
        <div class="card-body">
          <.kv_detail rows={[
            {"First Name",   @cust.first_name},
            {"Last Name",    @cust.last_name},
            {"Date of Birth", masked(date_s(@cust.date_of_birth), "cif.date_of_birth", @cust.sys_id, @current_operator)},
            {"Nationality",  @cust.nationality},
            {"Customer Tier",@cust.customer_tier || "RETAIL"}
          ]}/>
        </div>
      </div>
      <div class="card">
        <div class="card-header"><div class="card-title">Contact Details</div></div>
        <div class="card-body">
          <.kv_detail rows={[
            {"Email",    @cust.email},
            {"Mobile",   if(@cust.mobile_number, do: "+#{@cust.mobile_country} #{@cust.mobile_number}")},
            {"Address",  @cust.address_line1},
            {"",         @cust.address_line2},
            {"City",     @cust.city},
            {"Country",  @cust.country}
          ]}/>
        </div>
      </div>
    </div>
    """
  end

  defp tab_identity_kyc(assigns) do
    ~H"""
    <div class="card">
      <div class="card-header"><div class="card-title">Identity Documents</div></div>
      <div class="card-body">
        <.kv_detail rows={[
          {"ID Type",   @cust.id_type},
          {"ID Number", masked(@cust.id_number, "cif.id_number", @cust.sys_id, @current_operator)},
          {"Expiry",    date_s(@cust.id_expiry)},
          {"KYC Status",@cust.kyc_status || "PENDING"}
        ]}/>
      </div>
    </div>
    """
  end

  defp tab_corporate(assigns) do
    ~H"""
    <%= if @is_corporate do %>
      <div class="card">
        <div class="card-header"><div class="card-title">Corporate Details</div></div>
        <div class="card-body">
          <.kv_detail rows={[
            {"Company",       @cust.company_name},
            {"Reg. Number",   @cust.registration_number},
            {"Reg. Country",  @cust.registration_country},
            {"Reg. Date",     date_s(@cust.registration_date)}
          ]}/>
        </div>
      </div>
    <% else %>
      <p class="text-sm text-muted">This customer is not a corporate account.</p>
    <% end %>
    """
  end

  # Arrangements (Koṣa domain-model alignment, 2026-07-28; reworked into
  # sub-tabs-with-inline-detail 2026-07-28b per architect-supplied
  # reference design) — every product relationship this customer has,
  # across Credit/Debit/Prepaid/Corporate, grouped into sub-tabs by
  # product family. Picking a specific card embeds that product's own
  # admin LiveComponent directly on this page via the same ?view=
  # deep-link mechanism AdminLive's URL-based navigation uses — it just
  # never leaves the Customer page. Replaces the old flat list of "View
  # in X" links that always navigated away.
  #
  # Known rough edge: the embedded component's own "Back to list"
  # control (if clicked) shows that WHOLE product's full list inline,
  # not just this customer's — each family's own dedicated admin page
  # is still the right place for that broader list/search/create
  # workflow; this view is for "I'm already looking at one customer,
  # show me their card" navigation.
  defp tab_arrangements(assigns) do
    assigns = assign(assigns, counts: arrangement_counts(assigns.arrangements))

    ~H"""
    <div class="detail-tabs" style="margin:-20px -20px 16px -20px;">
      <%= for {family, label, icon} <- arrangement_families() do %>
        <div class={"detail-tab#{if @arr_family == family, do: " active"}"}
          phx-click="arr_family" phx-value-f={family} phx-target={@myself}>
          <%= icon %> <%= label %> <span class="text-muted">(<%= Map.get(@counts, family, 0) %>)</span>
        </div>
      <% end %>
    </div>

    <% rows_for_family = Enum.filter(@arrangements, &(arrangement_family(&1.arrangement.product_type) == @arr_family)) %>

    <%= if rows_for_family == [] do %>
      <p class="text-sm text-muted">No <%= family_label(@arr_family) %> for this customer.</p>
    <% else %>
      <%= if length(rows_for_family) > 1 do %>
        <div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:16px;">
          <%= for row <- rows_for_family do %>
            <button type="button"
              class={"btn btn-sm #{if @arr_selected_ref == row.view_ref, do: "btn-primary", else: "btn-secondary"}"}
              phx-click="arr_select" phx-value-ref={row.view_ref} phx-target={@myself}>
              <%= row.arrangement.product_type %> — <%= String.slice(row.view_ref, 0, 8) %>…
              <%= if row.status, do: "(#{row.status})" %>
            </button>
          <% end %>
        </div>
      <% end %>

      <%= if @arr_selected_ref do %>
        <.live_component module={arrangement_component(@arr_family)}
          id={"portfolio-#{@arr_family}-#{@arr_selected_ref}"}
          current_operator={@current_operator} deep_link_id={@arr_selected_ref} embedded={true} />
      <% end %>
    <% end %>
    """
  end

  defp arrangement_families do
    [
      {:credit,    "Credit Card",    "💳"},
      {:debit,     "Debit Card",     "🏦"},
      {:prepaid,   "Prepaid Card",   "💰"},
      {:corporate, "Corporate Card", "🏢"},
      {:fleet,     "Fleet Card",     "🚚"},
      {:wallet,    "Digital Wallet", "👛"}
    ]
  end

  defp arrangement_family("CREDIT"), do: :credit
  defp arrangement_family("DEBIT"), do: :debit
  defp arrangement_family("PREPAID"), do: :prepaid
  defp arrangement_family("CORPORATE_FACILITY"), do: :corporate
  defp arrangement_family("CORPORATE_EMPLOYEE"), do: :corporate
  defp arrangement_family("CORPORATE_FLEET"), do: :fleet
  defp arrangement_family("WALLET"), do: :wallet
  defp arrangement_family(_), do: :other

  defp arrangement_component(:credit), do: AccountComponent
  defp arrangement_component(:debit), do: DebitComponent
  defp arrangement_component(:prepaid), do: PrepaidComponent
  defp arrangement_component(:corporate), do: HcsComponent
  defp arrangement_component(:fleet), do: HcsComponent
  defp arrangement_component(:wallet), do: WalletComponent

  defp arrangement_counts(arrangements) do
    Enum.reduce(arrangements, %{}, fn row, acc ->
      Map.update(acc, arrangement_family(row.arrangement.product_type), 1, &(&1 + 1))
    end)
  end

  defp family_label(:credit), do: "credit cards"
  defp family_label(:debit), do: "debit cards"
  defp family_label(:prepaid), do: "prepaid cards"
  defp family_label(:corporate), do: "corporate cards"
  defp family_label(:fleet), do: "fleet cards"
  defp family_label(:wallet), do: "digital wallets"

  # First family (in display order) that has at least one arrangement —
  # so opening a Debit-only customer's Arrangements tab doesn't default
  # to an empty Credit Card sub-tab.
  defp default_arr_family(arrangements) do
    families_with_data = arrangements |> Enum.map(&arrangement_family(&1.arrangement.product_type)) |> MapSet.new()

    arrangement_families()
    |> Enum.find(fn {family, _, _} -> MapSet.member?(families_with_data, family) end)
    |> case do
      {family, _, _} -> family
      nil -> :credit
    end
  end

  defp first_ref_for_family(arrangements, family) do
    arrangements
    |> Enum.filter(&(arrangement_family(&1.arrangement.product_type) == family))
    |> case do
      [first | _] -> first.view_ref
      [] -> nil
    end
  end

  # ── Form view (2-pane: section nav + fields) ────────────────────────────────

  @sections [
    {1, "Personal",    "👤"},
    {2, "Contact",     "📱"},
    {3, "Address",     "🏠"},
    {4, "Identity/KYC","🪪"},
    {5, "Corporate",   "🏢"}
  ]

  defp render_form(assigns) do
    is_new     = is_nil(assigns.editing)
    is_corp    = assigns.form_data["customer_tier"] in ["BUSINESS", "CORPORATE"]
    visible_sections =
      if is_corp,
        do:   @sections,
        else: Enum.reject(@sections, fn {n, _, _} -> n == 5 end)
    assigns = assign(assigns,
      is_new:           is_new,
      is_corp:          is_corp,
      visible_sections: visible_sections,
      form_title:       if(is_new, do: "New Customer", else: "Edit Customer")
    )
    ~H"""
    <form phx-change="cust_change" phx-submit="cust_save" phx-target={@myself}>
      <div class="card">
        <div class="card-header">
          <div>
            <div class="card-title"><%= @form_title %></div>
            <div class="card-subtitle">Required: SYS ID, BANK ID, First Name, Last Name.</div>
          </div>
          <div style="display:flex;gap:8px;">
            <button type="button" phx-click="cust_back" phx-target={@myself} class="btn btn-secondary btn-sm">Cancel</button>
            <button type="submit" class="btn btn-primary btn-sm">
              <%= if @is_new, do: "Create", else: "Save Changes" %>
            </button>
          </div>
        </div>

        <div class="form-pane">
          <!-- Section nav -->
          <div class="form-pane-nav">
            <div class="form-pane-nav-label">Sections</div>
            <%= for {idx, label, icon} <- @visible_sections do %>
              <div
                phx-click="cust_section"
                phx-value-s={idx}
                phx-target={@myself}
                class={"form-pane-nav-item#{if @cust_section == idx, do: " active"}"}
              >
                <span class="form-pane-nav-num"><%= idx %></span>
                <span><%= icon %> <%= label %></span>
              </div>
            <% end %>
          </div>

          <!-- Content panel -->
          <div class="form-pane-content">

            <!-- Section 1: Personal -->
            <div style={"display:#{if @cust_section == 1, do: "block", else: "none"}"}>
              <div class="form-pane-section-title">👤 Personal Information</div>
              <div class="form-grid" style="margin-bottom:16px;">
                <div class="field">
                  <label>Processor (SYS ID) <span style="color:var(--danger)">*</span></label>
                  <select name="cust[sys_id]">
                    <%= for sys <- @sys_records do %>
                      <option value={sys.sys_id} selected={@form_data["sys_id"] == sys.sys_id}>
                        <%= sys.sys_id %> — <%= sys.description %>
                      </option>
                    <% end %>
                  </select>
                </div>
                <div class="field">
                  <label>Organisation (BANK ID) <span style="color:var(--danger)">*</span></label>
                  <select name="cust[bank_id]">
                    <%= for {label, val} <- @bank_options |> Enum.reject(fn {l, _} -> l == "-- All Banks --" end) do %>
                      <option value={val} selected={@form_data["bank_id"] == val}><%= label %></option>
                    <% end %>
                  </select>
                </div>
              </div>
              <div class="form-grid-3" style="margin-bottom:16px;">
                <div class="field">
                  <label>First Name <span style="color:var(--danger)">*</span></label>
                  <input type="text" name="cust[first_name]" value={@form_data["first_name"]}
                    placeholder="e.g. Ahmed"/>
                </div>
                <div class="field">
                  <label>Last Name <span style="color:var(--danger)">*</span></label>
                  <input type="text" name="cust[last_name]" value={@form_data["last_name"]}
                    placeholder="e.g. Al-Mansoori"/>
                </div>
                <div class="field">
                  <label>Customer Tier</label>
                  <select name="cust[customer_tier]">
                    <option value="RETAIL"    selected={@form_data["customer_tier"] == "RETAIL"}>Retail</option>
                    <option value="PREMIUM"   selected={@form_data["customer_tier"] == "PREMIUM"}>Premium</option>
                    <option value="BUSINESS"  selected={@form_data["customer_tier"] == "BUSINESS"}>Business</option>
                    <option value="CORPORATE" selected={@form_data["customer_tier"] == "CORPORATE"}>Corporate</option>
                  </select>
                  <p class="hint">Business/Corporate enables the Corporate section.</p>
                </div>
              </div>
              <div class="form-grid">
                <div class="field">
                  <label>Date of Birth</label>
                  <input type="date" name="cust[date_of_birth]" value={@form_data["date_of_birth"]}/>
                </div>
                <div class="field">
                  <label>Nationality</label>
                  <select name="cust[nationality]">
                    <%= for {label, val} <- @nationalities do %>
                      <option value={val} selected={@form_data["nationality"] == val}><%= label %></option>
                    <% end %>
                  </select>
                </div>
              </div>
            </div>

            <!-- Section 2: Contact -->
            <div style={"display:#{if @cust_section == 2, do: "block", else: "none"}"}>
              <div class="form-pane-section-title">📱 Contact Details</div>
              <div class="field" style="margin-bottom:16px;">
                <label>Email Address</label>
                <input type="email" name="cust[email]" value={@form_data["email"]}
                  placeholder="e.g. ahmed@example.com"/>
              </div>
              <div class="form-grid">
                <div class="field">
                  <label>Country Dial Code</label>
                  <select name="cust[mobile_country]">
                    <%= for {label, val} <- @dial_codes do %>
                      <option value={val} selected={@form_data["mobile_country"] == val}><%= label %></option>
                    <% end %>
                  </select>
                </div>
                <div class="field">
                  <label>Mobile Number</label>
                  <input type="text" name="cust[mobile_number]" value={@form_data["mobile_number"]}
                    placeholder="e.g. 501234567" style="font-family:var(--font-mono);"/>
                  <p class="hint">Enter number without country code.</p>
                </div>
              </div>
            </div>

            <!-- Section 3: Address -->
            <div style={"display:#{if @cust_section == 3, do: "block", else: "none"}"}>
              <div class="form-pane-section-title">🏠 Address</div>
              <div class="field" style="margin-bottom:16px;">
                <label>Address Line 1</label>
                <input type="text" name="cust[address_line1]" value={@form_data["address_line1"]}
                  placeholder="e.g. Villa 42, Al Wasl Road"/>
              </div>
              <div class="field" style="margin-bottom:16px;">
                <label>Address Line 2</label>
                <input type="text" name="cust[address_line2]" value={@form_data["address_line2"]}
                  placeholder="Building / Apartment / Area (optional)"/>
              </div>
              <div class="form-grid-3">
                <div class="field">
                  <label>City</label>
                  <input type="text" name="cust[city]" value={@form_data["city"]}
                    placeholder="e.g. Dubai"/>
                </div>
                <div class="field">
                  <label>Postal Code</label>
                  <input type="text" name="cust[postal_code]" value={@form_data["postal_code"]}
                    placeholder="e.g. 00000"/>
                </div>
                <div class="field">
                  <label>Country</label>
                  <select name="cust[country]">
                    <%= for {label, val} <- @countries_iso2 do %>
                      <option value={val} selected={@form_data["country"] == val}><%= label %></option>
                    <% end %>
                  </select>
                </div>
              </div>
            </div>

            <!-- Section 4: Identity / KYC -->
            <div style={"display:#{if @cust_section == 4, do: "block", else: "none"}"}>
              <div class="form-pane-section-title">🪪 Identity Documents & KYC</div>
              <div class="form-grid-3" style="margin-bottom:16px;">
                <div class="field">
                  <label>ID Type</label>
                  <select name="cust[id_type]">
                    <%= for {label, val} <- @id_types do %>
                      <option value={val} selected={@form_data["id_type"] == val}><%= label %></option>
                    <% end %>
                  </select>
                </div>
                <div class="field">
                  <label>ID Number</label>
                  <input type="text" name="cust[id_number]" value={@form_data["id_number"]}
                    placeholder="e.g. 784-XXXX-XXXXXXX-X"
                    style="font-family:var(--font-mono);"/>
                </div>
                <div class="field">
                  <label>ID Expiry Date</label>
                  <input type="date" name="cust[id_expiry]" value={@form_data["id_expiry"]}/>
                </div>
              </div>
              <div class="field">
                <label>KYC Status</label>
                <select name="cust[kyc_status]">
                  <option value="PENDING"  selected={@form_data["kyc_status"] == "PENDING"}>Pending</option>
                  <option value="VERIFIED" selected={@form_data["kyc_status"] == "VERIFIED"}>Verified</option>
                  <option value="REJECTED" selected={@form_data["kyc_status"] == "REJECTED"}>Rejected</option>
                </select>
                <p class="hint">You can also update KYC status from the Customer detail view with dedicated action buttons.</p>
              </div>
            </div>

            <!-- Section 5: Corporate Details (BUSINESS/CORPORATE only) -->
            <div style={"display:#{if @cust_section == 5, do: "block", else: "none"}"}>
              <div class="form-pane-section-title">🏢 Corporate Details</div>
              <%= if @is_corp do %>
                <div class="form-grid" style="margin-bottom:16px;">
                  <div class="field">
                    <label>Company Name <span style="color:var(--danger)">*</span></label>
                    <input type="text" name="cust[company_name]" value={@form_data["company_name"]}
                      placeholder="e.g. Al-Futtaim Group LLC"/>
                    <p class="hint">Legal name of the registered entity.</p>
                  </div>
                  <div class="field">
                    <label>Registration Number <span style="color:var(--danger)">*</span></label>
                    <input type="text" name="cust[registration_number]" value={@form_data["registration_number"]}
                      placeholder="e.g. 12345 Dubai"
                      style="font-family:var(--font-mono);"/>
                  </div>
                </div>
                <div class="form-grid">
                  <div class="field">
                    <label>Registration Country</label>
                    <select name="cust[registration_country]">
                      <%= for {label, val} <- @countries_iso2 do %>
                        <option value={val} selected={@form_data["registration_country"] == val}><%= label %></option>
                      <% end %>
                    </select>
                  </div>
                  <div class="field">
                    <label>Registration Date</label>
                    <input type="date" name="cust[registration_date]" value={@form_data["registration_date"]}/>
                  </div>
                </div>
              <% else %>
                <div style="padding:48px;text-align:center;color:var(--text-muted);">
                  <div style="font-size:32px;margin-bottom:12px;">🏢</div>
                  <div style="font-size:14px;font-weight:500;margin-bottom:6px;">Corporate Fields Not Applicable</div>
                  <div style="font-size:13px;">
                    This section only applies to <strong>Business</strong> or <strong>Corporate</strong> tier customers.<br/>
                    Change the Customer Tier in Section 1 to enable these fields.
                  </div>
                </div>
              <% end %>
            </div>

          </div><!-- /form-pane-content -->
        </div><!-- /form-pane -->

        <div class="card-footer">
          <button type="button" phx-click="cust_back" phx-target={@myself} class="btn btn-secondary">
            Cancel
          </button>
          <div style="display:flex;gap:8px;margin-left:auto;">
            <%= if @cust_section > 1 do %>
              <button type="button" phx-click="cust_section"
                phx-value-s={@cust_section - 1} phx-target={@myself}
                class="btn btn-secondary">← Previous</button>
            <% end %>
            <%= if @cust_section < length(@visible_sections) do %>
              <button type="button" phx-click="cust_section"
                phx-value-s={@cust_section + 1} phx-target={@myself}
                class="btn btn-secondary">Next →</button>
            <% end %>
            <button type="submit" class="btn btn-primary">
              <%= if @is_new, do: "💾 Create Customer", else: "💾 Save Changes" %>
            </button>
          </div>
        </div>
      </div><!-- /card -->
    </form>
    """
  end
end
