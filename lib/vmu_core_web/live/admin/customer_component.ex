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

  alias VmuCore.{Repo}
  alias VmuCore.Shared.{Customer, BankParameter, SysParameter}

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
       linked_accounts: []
     )
     |> load_options()
     |> load_customers()}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
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

  @impl true
  def handle_event("cust_search", %{"q" => q}, socket) do
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
  end

  def handle_event("cust_edit", %{"id" => id}, socket) do
    cust = Enum.find(socket.assigns.customers, &(to_string(&1.customer_id) == id))
    fd   = if cust, do: cust_to_form(cust), else: %{}
    {:noreply, assign(socket, mode: :form, editing: cust, form_data: fd, result: nil, cust_section: 1)}
  end

  def handle_event("cust_view", %{"id" => id}, socket) do
    # PII view audit (ASM-P4.2, FR-ASM-015): who opened which customer, when
    VmuCore.ASM.AuditLog.record(
      Map.get(socket.assigns, :current_operator), "customer_pii_view", id)

    cust = Enum.find(socket.assigns.customers, &(to_string(&1.customer_id) == id))
    if cust do
      accounts = Customer.list_accounts_for(cust.customer_id)
      {:noreply, assign(socket, mode: :detail, viewing: cust, linked_accounts: accounts, result: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cust_back", _params, socket) do
    {:noreply, socket |> assign(mode: :list, viewing: nil, editing: nil) |> load_customers()}
  end

  def handle_event("cust_edit_from_detail", _params, socket) do
    cust = socket.assigns.viewing
    fd   = cust_to_form(cust)
    {:noreply, assign(socket, mode: :form, editing: cust, form_data: fd, result: nil, cust_section: 1)}
  end

  def handle_event("cust_section", %{"s" => s}, socket) do
    {:noreply, assign(socket, cust_section: String.to_integer(s))}
  end

  def handle_event("cust_change", %{"cust" => params}, socket) do
    {:noreply, assign(socket, form_data: params)}
  end

  def handle_event("cust_save", %{"cust" => params}, socket) do
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
        {:noreply, socket
          |> load_customers()
          |> assign(mode: :detail, editing: nil, viewing: saved,
                    linked_accounts: accounts, result: {:ok, "Customer #{action}."})}

      {:error, cs} ->
        msg = Enum.map_join(cs.errors, "; ", fn {f, {m, _}} -> "#{f}: #{m}" end)
        {:noreply, assign(socket, result: {:error, "Save failed — #{msg}"})}
    end
  end

  def handle_event("cust_delete", %{"id" => id}, socket) do
    cust = Enum.find(socket.assigns.customers, &(to_string(&1.customer_id) == id))
    if cust, do: Repo.delete(cust)
    {:noreply, socket |> load_customers() |> assign(mode: :list, result: {:ok, "Customer deleted."})}
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
          {:noreply, socket
            |> load_customers()
            |> assign(viewing: updated, linked_accounts: accounts,
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
    <div>
      <.page_header title="Customers (CIF)" subtitle="Customer Information File — individual and corporate cardholders">
        <:actions>
          <%= if @mode == :list do %>
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
              phx-value-q={@search}
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
          <button phx-click="cust_new" phx-target={@myself} class="btn btn-primary">
            + New Customer
          </button>
        </:actions>
      </.empty_state>
    <% else %>
      <div class="card">
        <table class="data-table">
          <colgroup>
            <col style="width:200px"/>
            <col style="width:90px"/>
            <col style="width:110px"/>
            <col/>
            <col style="width:160px"/>
            <col style="width:110px"/>
            <col style="width:100px"/>
            <col style="width:160px"/>
          </colgroup>
          <thead>
            <tr>
              <th>Name</th>
              <th>Bank</th>
              <th>Customer ID</th>
              <th>Email / Mobile</th>
              <th>ID Document</th>
              <th>KYC Status</th>
              <th>Tier</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for c <- @customers do %>
              <tr>
                <td>
                  <div style="font-weight:500;"><%= full_name(c) %></div>
                  <div class="text-sm text-muted"><%= date_s(c.date_of_birth) %></div>
                </td>
                <td><span class="mono"><%= c.bank_id %></span></td>
                <td><span class="mono text-xs" style="color:var(--text-muted)"><%= short_id(c.customer_id) %></span></td>
                <td>
                  <div class="text-sm"><%= c.email %></div>
                  <div class="text-sm text-muted">
                    <%= if c.mobile_number, do: "+#{c.mobile_country} #{c.mobile_number}" %>
                  </div>
                </td>
                <td>
                  <div class="text-sm"><%= c.id_type %></div>
                  <div class="text-sm text-muted"><%= c.id_number %></div>
                </td>
                <td>
                  <span class={"badge #{kyc_badge_class(c.kyc_status)}"}>
                    <%= c.kyc_status || "PENDING" %>
                  </span>
                </td>
                <td>
                  <span class={"badge #{tier_badge_class(c.customer_tier)}"}>
                    <%= c.customer_tier || "RETAIL" %>
                  </span>
                </td>
                <td>
                  <div class="actions">
                    <button phx-click="cust_view" phx-target={@myself}
                      phx-value-id={c.customer_id} class="btn btn-sm btn-secondary">
                      View
                    </button>
                    <button phx-click="cust_edit" phx-target={@myself}
                      phx-value-id={c.customer_id} class="btn btn-sm btn-secondary">
                      Edit
                    </button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
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
    <!-- Detail header card -->
    <div class="card" style="margin-bottom:20px;">
      <div class="card-body" style="display:grid;grid-template-columns:1fr auto;gap:24px;align-items:start;">
        <div style="display:flex;gap:20px;align-items:center;">
          <div style="width:56px;height:56px;border-radius:50%;background:var(--accent-light);display:flex;align-items:center;justify-content:center;font-size:22px;flex-shrink:0;">
            <%= if @is_corporate, do: "🏢", else: "👤" %>
          </div>
          <div>
            <div style="font-size:20px;font-weight:700;color:var(--text-primary);">
              <%= full_name(@cust) %>
            </div>
            <div style="font-size:12px;color:var(--text-muted);font-family:var(--font-mono);margin-top:2px;">
              CIF: <%= @cust.customer_id %>
            </div>
            <div style="margin-top:8px;display:flex;gap:8px;">
              <span class={"badge #{kyc_badge_class(@cust.kyc_status)}"}><%= @cust.kyc_status || "PENDING" %></span>
              <span class={"badge #{tier_badge_class(@cust.customer_tier)}"}><%= @cust.customer_tier || "RETAIL" %></span>
              <span class="badge badge-gray"><%= @cust.bank_id %></span>
            </div>
          </div>
        </div>
        <div style="display:flex;flex-direction:column;gap:8px;align-items:flex-end;">
          <button phx-click="cust_edit_from_detail" phx-target={@myself} class="btn btn-secondary">
            Edit Customer
          </button>
          <button phx-click="cust_delete" phx-target={@myself}
            phx-value-id={@cust.customer_id} class="btn btn-sm btn-danger"
            data-confirm={"Permanently delete customer #{full_name(@cust)}? This cannot be undone."}>
            Delete
          </button>
        </div>
      </div>
    </div>

    <!-- KYC workflow actions -->
    <div class="card" style="margin-bottom:20px;">
      <div class="card-header">
        <div class="card-title">KYC Verification Workflow</div>
        <div class="card-subtitle">Current status: <%= @cust.kyc_status || "PENDING" %></div>
      </div>
      <div class="card-body">
        <div style="display:flex;gap:12px;align-items:center;flex-wrap:wrap;">
          <%= if @cust.kyc_status != "VERIFIED" do %>
            <button phx-click="kyc_verify" phx-target={@myself}
              phx-value-id={@cust.customer_id}
              class="btn btn-primary"
              style="background:var(--success);border-color:var(--success);"
              data-confirm={"Mark #{full_name(@cust)} as KYC VERIFIED?"}>
              ✓ Verify Customer
            </button>
          <% end %>
          <%= if @cust.kyc_status != "REJECTED" do %>
            <button phx-click="kyc_reject" phx-target={@myself}
              phx-value-id={@cust.customer_id}
              class="btn btn-danger"
              data-confirm={"Mark #{full_name(@cust)} as KYC REJECTED?"}>
              ✗ Reject
            </button>
          <% end %>
          <%= if @cust.kyc_status != "PENDING" do %>
            <button phx-click="kyc_reset" phx-target={@myself}
              phx-value-id={@cust.customer_id}
              class="btn btn-secondary"
              data-confirm={"Reset KYC status for #{full_name(@cust)} back to PENDING?"}>
              ↺ Reset to Pending
            </button>
          <% end %>
        </div>
        <%= if @cust.kyc_verified_at do %>
          <div class="text-sm text-muted" style="margin-top:10px;">
            Verified at: <%= NaiveDateTime.to_string(@cust.kyc_verified_at) %>
          </div>
        <% end %>
      </div>
    </div>

    <!-- Detail info grid -->
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-bottom:20px;">
      <!-- Personal info -->
      <div class="card">
        <div class="card-header"><div class="card-title">Personal Information</div></div>
        <div class="card-body">
          <.kv_detail rows={[
            {"First Name",   @cust.first_name},
            {"Last Name",    @cust.last_name},
            {"Date of Birth", date_s(@cust.date_of_birth)},
            {"Nationality",  @cust.nationality},
            {"Customer Tier",@cust.customer_tier || "RETAIL"}
          ]}/>
        </div>
      </div>
      <!-- Contact info -->
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

    <div style="display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-bottom:20px;">
      <!-- Identity / KYC -->
      <div class="card">
        <div class="card-header"><div class="card-title">Identity Documents</div></div>
        <div class="card-body">
          <.kv_detail rows={[
            {"ID Type",   @cust.id_type},
            {"ID Number", @cust.id_number},
            {"Expiry",    date_s(@cust.id_expiry)},
            {"KYC Status",@cust.kyc_status || "PENDING"}
          ]}/>
        </div>
      </div>
      <!-- Corporate (conditional) or Linked accounts -->
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
        <div class="card">
          <div class="card-header"><div class="card-title">Linked Accounts</div></div>
          <div class="card-body">
            <%= if @linked_accounts == [] do %>
              <p class="text-sm text-muted">No accounts linked to this customer.</p>
            <% else %>
              <%= for acc <- @linked_accounts do %>
                <div style="padding:10px 0;border-bottom:1px solid var(--border);display:flex;justify-content:space-between;align-items:center;">
                  <div>
                    <span class="mono" style="font-size:12px;"><%= acc.account_id |> to_string() |> String.slice(0,12) %>…</span>
                    <span class="badge badge-gray" style="margin-left:8px;"><%= acc.logo_id %></span>
                  </div>
                  <span class={"badge #{if acc.account_status == "ACTIVE", do: "badge-green", else: "badge-gray"}"}>
                    <%= acc.account_status %>
                  </span>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
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
