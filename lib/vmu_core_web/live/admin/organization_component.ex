defmodule VmuCoreWeb.Live.Admin.OrganizationComponent do
  @moduledoc """
  Organization (BANK) parameter CRUD LiveComponent.

  Lists all BankParameter records with actions to create new organisations
  or edit existing ones. Each organisation inherits from SYS and owns
  one or more LOGOs (card products).
  """
  use Phoenix.LiveComponent

  import Ecto.Query, warn: false
  import VmuCoreWeb.AdminUI

  alias VmuCore.{Repo}
  alias VmuCore.Shared.{BankParameter, SysParameter, ParameterWriter}

  # ── Option lists ────────────────────────────────────────────────────────────

  @countries [
    {"-- Select Country --", ""},
    {"ARE — United Arab Emirates", "ARE"}, {"SAU — Saudi Arabia", "SAU"},
    {"BHR — Bahrain", "BHR"}, {"KWT — Kuwait", "KWT"}, {"QAT — Qatar", "QAT"},
    {"OMN — Oman", "OMN"}, {"EGY — Egypt", "EGY"}, {"JOR — Jordan", "JOR"},
    {"LBN — Lebanon", "LBN"}, {"PAK — Pakistan", "PAK"}, {"IND — India", "IND"},
    {"BGD — Bangladesh", "BGD"}, {"LKA — Sri Lanka", "LKA"}, {"NPL — Nepal", "NPL"},
    {"PHL — Philippines", "PHL"}, {"IDN — Indonesia", "IDN"}, {"MYS — Malaysia", "MYS"},
    {"SGP — Singapore", "SGP"}, {"THA — Thailand", "THA"}, {"VNM — Vietnam", "VNM"},
    {"CHN — China", "CHN"}, {"HKG — Hong Kong SAR", "HKG"}, {"TWN — Taiwan", "TWN"},
    {"KOR — South Korea", "KOR"}, {"JPN — Japan", "JPN"}, {"AUS — Australia", "AUS"},
    {"NZL — New Zealand", "NZL"}, {"ZAF — South Africa", "ZAF"}, {"NGA — Nigeria", "NGA"},
    {"GHA — Ghana", "GHA"}, {"KEN — Kenya", "KEN"}, {"TZA — Tanzania", "TZA"},
    {"USA — United States", "USA"}, {"CAN — Canada", "CAN"}, {"GBR — United Kingdom", "GBR"},
    {"DEU — Germany", "DEU"}, {"FRA — France", "FRA"}, {"CHE — Switzerland", "CHE"},
    {"NLD — Netherlands", "NLD"}, {"BEL — Belgium", "BEL"}, {"ESP — Spain", "ESP"},
    {"ITA — Italy", "ITA"}, {"PRT — Portugal", "PRT"}, {"TUR — Turkey", "TUR"},
    {"BRA — Brazil", "BRA"}, {"ARG — Argentina", "ARG"}, {"MEX — Mexico", "MEX"},
    {"COL — Colombia", "COL"}, {"CHL — Chile", "CHL"}, {"PER — Peru", "PER"}
  ]

  @currencies [
    {"-- Select Currency --", ""},
    {"AED — UAE Dirham", "AED"}, {"SAR — Saudi Riyal", "SAR"}, {"BHD — Bahraini Dinar", "BHD"},
    {"KWD — Kuwaiti Dinar", "KWD"}, {"QAR — Qatari Riyal", "QAR"}, {"OMR — Omani Rial", "OMR"},
    {"EGP — Egyptian Pound", "EGP"}, {"JOD — Jordanian Dinar", "JOD"}, {"PKR — Pakistani Rupee", "PKR"},
    {"INR — Indian Rupee", "INR"}, {"BDT — Bangladeshi Taka", "BDT"}, {"LKR — Sri Lanka Rupee", "LKR"},
    {"PHP — Philippine Peso", "PHP"}, {"IDR — Indonesian Rupiah", "IDR"}, {"MYR — Malaysian Ringgit", "MYR"},
    {"SGD — Singapore Dollar", "SGD"}, {"THB — Thai Baht", "THB"}, {"VND — Vietnamese Dong", "VND"},
    {"CNY — Chinese Yuan", "CNY"}, {"HKD — Hong Kong Dollar", "HKD"}, {"TWD — Taiwan Dollar", "TWD"},
    {"KRW — South Korean Won", "KRW"}, {"JPY — Japanese Yen", "JPY"}, {"AUD — Australian Dollar", "AUD"},
    {"NZD — New Zealand Dollar", "NZD"}, {"ZAR — South African Rand", "ZAR"}, {"NGN — Nigerian Naira", "NGN"},
    {"GHS — Ghanaian Cedi", "GHS"}, {"KES — Kenyan Shilling", "KES"}, {"TZS — Tanzanian Shilling", "TZS"},
    {"USD — US Dollar", "USD"}, {"CAD — Canadian Dollar", "CAD"}, {"GBP — British Pound", "GBP"},
    {"EUR — Euro", "EUR"}, {"CHF — Swiss Franc", "CHF"}, {"TRY — Turkish Lira", "TRY"},
    {"BRL — Brazilian Real", "BRL"}, {"MXN — Mexican Peso", "MXN"}, {"ARS — Argentine Peso", "ARS"}
  ]

  @timezones [
    {"Asia/Dubai (UTC+4)", "Asia/Dubai"}, {"Asia/Riyadh (UTC+3)", "Asia/Riyadh"},
    {"Asia/Bahrain (UTC+3)", "Asia/Bahrain"}, {"Asia/Kuwait (UTC+3)", "Asia/Kuwait"},
    {"Asia/Qatar (UTC+3)", "Asia/Qatar"}, {"Asia/Muscat (UTC+4)", "Asia/Muscat"},
    {"Africa/Cairo (UTC+2/+3)", "Africa/Cairo"}, {"Asia/Amman (UTC+2/+3)", "Asia/Amman"},
    {"Asia/Beirut (UTC+2/+3)", "Asia/Beirut"}, {"Asia/Karachi (UTC+5)", "Asia/Karachi"},
    {"Asia/Kolkata (UTC+5:30)", "Asia/Kolkata"}, {"Asia/Dhaka (UTC+6)", "Asia/Dhaka"},
    {"Asia/Colombo (UTC+5:30)", "Asia/Colombo"}, {"Asia/Manila (UTC+8)", "Asia/Manila"},
    {"Asia/Jakarta (UTC+7)", "Asia/Jakarta"}, {"Asia/Kuala_Lumpur (UTC+8)", "Asia/Kuala_Lumpur"},
    {"Asia/Singapore (UTC+8)", "Asia/Singapore"}, {"Asia/Bangkok (UTC+7)", "Asia/Bangkok"},
    {"Asia/Ho_Chi_Minh (UTC+7)", "Asia/Ho_Chi_Minh"}, {"Asia/Shanghai (UTC+8)", "Asia/Shanghai"},
    {"Asia/Hong_Kong (UTC+8)", "Asia/Hong_Kong"}, {"Asia/Tokyo (UTC+9)", "Asia/Tokyo"},
    {"Asia/Seoul (UTC+9)", "Asia/Seoul"}, {"Australia/Sydney (UTC+10/11)", "Australia/Sydney"},
    {"Africa/Johannesburg (UTC+2)", "Africa/Johannesburg"}, {"Africa/Lagos (UTC+1)", "Africa/Lagos"},
    {"Africa/Nairobi (UTC+3)", "Africa/Nairobi"}, {"Europe/London (UTC+0/+1)", "Europe/London"},
    {"Europe/Berlin (UTC+1/+2)", "Europe/Berlin"}, {"Europe/Zurich (UTC+1/+2)", "Europe/Zurich"},
    {"America/New_York (UTC-5/-4)", "America/New_York"}, {"America/Chicago (UTC-6/-5)", "America/Chicago"},
    {"America/Los_Angeles (UTC-8/-7)", "America/Los_Angeles"}, {"America/Sao_Paulo (UTC-3)", "America/Sao_Paulo"},
    {"UTC", "UTC"}
  ]

  @regimes [
    {"-- Select Regulatory Regime --", ""},
    {"CBUAE — Central Bank of UAE", "CBUAE"}, {"CBB — Central Bank of Bahrain", "CBB"},
    {"SAMA — Saudi Arabian Monetary Authority", "SAMA"}, {"CBK — Central Bank of Kuwait", "CBK"},
    {"QCB — Qatar Central Bank", "QCB"}, {"CBO — Central Bank of Oman", "CBO"},
    {"CBE — Central Bank of Egypt", "CBE"}, {"CBJ — Central Bank of Jordan", "CBJ"},
    {"BDL — Banque du Liban", "BDL"}, {"SBP — State Bank of Pakistan", "SBP"},
    {"RBI — Reserve Bank of India", "RBI"}, {"BB — Bangladesh Bank", "BB"},
    {"MAS — Monetary Authority of Singapore", "MAS"}, {"BNM — Bank Negara Malaysia", "BNM"},
    {"BOT — Bank of Thailand", "BOT"}, {"BSP — Bangko Sentral ng Pilipinas", "BSP"},
    {"BI — Bank Indonesia", "BI"}, {"PBOC — People's Bank of China", "PBOC"},
    {"HKMA — Hong Kong Monetary Authority", "HKMA"}, {"BOJ — Bank of Japan", "BOJ"},
    {"BOK — Bank of Korea", "BOK"}, {"RBA — Reserve Bank of Australia", "RBA"},
    {"RBNZ — Reserve Bank of New Zealand", "RBNZ"}, {"SARB — South African Reserve Bank", "SARB"},
    {"CBN — Central Bank of Nigeria", "CBN"}, {"BOG — Bank of Ghana", "BOG"},
    {"CBK_KE — Central Bank of Kenya", "CBK_KE"}, {"FED — US Federal Reserve", "FED"},
    {"BoE — Bank of England", "BoE"}, {"ECB — European Central Bank", "ECB"},
    {"BIS — Bank for International Settlements", "BIS"}, {"OTHER", "OTHER"}
  ]

  # ── Mount / Update ──────────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(mode: :list, editing: nil, result: nil, form_data: %{}, org_section: 1)
     |> load_data()}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  defp load_data(socket) do
    orgs = Repo.all(BankParameter)
    syss = Repo.all(SysParameter)
    assign(socket, orgs: orgs, sys_records: syss)
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("org_new", _params, socket) do
    sys_id = case socket.assigns.sys_records do
      [s | _] -> s.sys_id
      _       -> ""
    end
    fd = %{
      "bank_id" => "", "sys_id" => sys_id, "description" => "", "org_name" => "",
      "country_code" => "ARE", "base_currency" => "AED", "billing_timezone" => "Asia/Dubai",
      "regulatory_regime" => "CBUAE", "org_type" => "BANK", "swift_bic" => "",
      "gl_mapping_profile" => ""
    }
    {:noreply, assign(socket, mode: :form, editing: nil, form_data: fd, result: nil, org_section: 1)}
  end

  def handle_event("org_edit", %{"id" => bank_id}, socket) do
    org = Enum.find(socket.assigns.orgs, &(&1.bank_id == bank_id))
    fd  = if org, do: org_to_form(org), else: %{}
    {:noreply, assign(socket, mode: :form, editing: org, form_data: fd, result: nil, org_section: 1)}
  end

  def handle_event("org_cancel", _params, socket) do
    {:noreply, socket |> assign(mode: :list, editing: nil, result: nil) |> load_data()}
  end

  def handle_event("org_section", %{"s" => s}, socket) do
    {:noreply, assign(socket, org_section: String.to_integer(s))}
  end

  def handle_event("org_change", %{"org" => params}, socket) do
    {:noreply, assign(socket, form_data: params)}
  end

  def handle_event("org_save", %{"org" => params}, socket) do
    case socket.assigns.editing do
      nil ->
        attrs = build_org_attrs(params)
        case %BankParameter{}
             |> BankParameter.changeset(attrs)
             |> Repo.insert() do
          {:ok, _record} ->
            VmuCore.Shared.ParameterEngine.refresh_all()
            {:noreply, socket |> load_data() |> assign(mode: :list, result: {:ok, "Organisation created."})}

          {:error, cs} ->
            msg = Enum.map_join(cs.errors, "; ", fn {f, {m, _}} -> "#{f}: #{m}" end)
            {:noreply, assign(socket, result: {:error, "Save failed — #{msg}"})}
        end

      org ->
        attrs = build_org_attrs(params)
        case ParameterWriter.update_bank(org, attrs) do
          {:ok, _} ->
            {:noreply, socket |> load_data() |> assign(mode: :list, result: {:ok, "Organisation updated."})}

          {:error, cs} ->
            msg = Enum.map_join(cs.errors, "; ", fn {f, {m, _}} -> "#{f}: #{m}" end)
            {:noreply, assign(socket, result: {:error, "Save failed — #{msg}"})}
        end
    end
  end

  def handle_event("org_delete", %{"id" => bank_id}, socket) do
    org = Enum.find(socket.assigns.orgs, &(&1.bank_id == bank_id))
    if org do
      Repo.delete(org)
      VmuCore.Shared.ParameterEngine.refresh_all()
    end
    {:noreply, socket |> load_data() |> assign(result: {:ok, "Organisation #{bank_id} deleted."})}
  end

  defp org_to_form(%BankParameter{} = o) do
    %{
      "bank_id"            => o.bank_id,
      "sys_id"             => o.sys_id,
      "description"        => o.description,
      "org_name"           => o.org_name,
      "country_code"       => o.country_code,
      "base_currency"      => o.base_currency,
      "billing_timezone"   => o.billing_timezone,
      "regulatory_regime"  => o.regulatory_regime,
      "org_type"           => o.org_type || "BANK",
      "swift_bic"          => o.swift_bic,
      "gl_mapping_profile" => o.gl_mapping_profile
    }
  end

  defp build_org_attrs(p) do
    %{
      bank_id:           p["bank_id"],
      sys_id:            p["sys_id"],
      description:       p["description"],
      org_name:          p["org_name"],
      country_code:      p["country_code"],
      base_currency:     p["base_currency"],
      billing_timezone:  p["billing_timezone"],
      regulatory_regime: p["regulatory_regime"],
      org_type:          p["org_type"],
      swift_bic:         p["swift_bic"],
      gl_mapping_profile: p["gl_mapping_profile"]
    }
  end

  # ── Render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns,
      countries:  @countries,
      currencies: @currencies,
      timezones:  @timezones,
      regimes:    @regimes,
      org_types:  BankParameter.org_type_options()
    )
    ~H"""
    <div>
      <.page_header title="Organisations" subtitle="Bank and financial institution records — BANK level in the VisionPlus parameter hierarchy">
        <:actions>
          <button :if={@mode == :list} phx-click="org_new" phx-target={@myself} class="btn btn-primary">
            + New Organisation
          </button>
        </:actions>
      </.page_header>

      <%= if @result do %>
        <% {kind, msg} = @result %>
        <.alert kind={kind} message={msg} />
      <% end %>

      <%= if @mode == :list do %>
        <.render_list orgs={@orgs} myself={@myself} />
      <% else %>
        <.render_form
          form_data={@form_data}
          editing={@editing}
          myself={@myself}
          sys_records={@sys_records}
          countries={@countries}
          currencies={@currencies}
          timezones={@timezones}
          regimes={@regimes}
          org_types={@org_types}
          org_section={@org_section}
        />
      <% end %>
    </div>
    """
  end

  # ── List view ───────────────────────────────────────────────────────────────

  defp render_list(assigns) do
    org_count    = length(assigns.orgs)
    countries    = assigns.orgs |> Enum.map(& &1.country_code) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()
    currencies   = assigns.orgs |> Enum.map(& &1.base_currency) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()
    assigns = assign(assigns, org_count: org_count, org_countries: countries, org_currencies: currencies)
    ~H"""
    <!-- Summary tiles -->
    <div class="stat-grid" style="grid-template-columns: repeat(3, 1fr); max-width: 600px; margin-bottom: 20px;">
      <div class="stat-card">
        <div class="stat-label">Total Organisations</div>
        <div class="stat-value"><%= @org_count %></div>
        <div class="stat-sub">BANK records</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Countries</div>
        <div class="stat-value"><%= @org_countries %></div>
        <div class="stat-sub">unique jurisdictions</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Currencies</div>
        <div class="stat-value"><%= @org_currencies %></div>
        <div class="stat-sub">functional currencies</div>
      </div>
    </div>

    <%= if @orgs == [] do %>
      <.empty_state icon="🏦" title="No Organisations Yet"
        message="Create your first organisation to start the parameter hierarchy.">
        <:actions>
          <button phx-click="org_new" phx-target={@myself} class="btn btn-primary">
            + New Organisation
          </button>
        </:actions>
      </.empty_state>
    <% else %>
      <div class="card">
        <table class="data-table">
          <colgroup>
            <col style="width:90px"/>
            <col style="width:90px"/>
            <col/>
            <col style="width:110px"/>
            <col style="width:110px"/>
            <col style="width:200px"/>
            <col style="width:130px"/>
            <col style="width:150px"/>
          </colgroup>
          <thead>
            <tr>
              <th>BANK ID</th>
              <th>SYS ID</th>
              <th>Organisation Name</th>
              <th>Country</th>
              <th>Currency</th>
              <th>Regulatory Regime</th>
              <th>Type</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for org <- @orgs do %>
              <tr>
                <td><span class="mono"><%= org.bank_id %></span></td>
                <td><span class="mono"><%= org.sys_id %></span></td>
                <td>
                  <div style="font-weight:500;"><%= org.org_name || org.description %></div>
                  <div class="text-sm text-muted"><%= if org.org_name, do: org.description %></div>
                </td>
                <td><span class="badge badge-gray"><%= org.country_code %></span></td>
                <td><span class="font-mono"><%= org.base_currency %></span></td>
                <td><span class="badge badge-blue"><%= org.regulatory_regime %></span></td>
                <td><span class="badge badge-gray"><%= org.org_type || "BANK" %></span></td>
                <td>
                  <div class="actions">
                    <button phx-click="org_edit" phx-target={@myself}
                      phx-value-id={org.bank_id} class="btn btn-sm btn-secondary">
                      Edit
                    </button>
                    <button phx-click="org_delete" phx-target={@myself}
                      phx-value-id={org.bank_id} class="btn btn-sm btn-danger"
                      data-confirm={"Delete organisation #{org.bank_id}? This cannot be undone."}>
                      Delete
                    </button>
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

  # ── Form view (2-pane: left section nav + right fields) ─────────────────────

  @sections [
    {1, "Identity",          "🏦"},
    {2, "Classification",    "🏷️"},
    {3, "Locale & Currency", "🌐"},
    {4, "Settlement & GL",   "⚖️"}
  ]

  defp render_form(assigns) do
    is_new = is_nil(assigns.editing)
    assigns = assign(assigns,
      is_new:     is_new,
      form_title: if(is_new, do: "New Organisation", else: "Edit Organisation"),
      sections:   @sections
    )
    ~H"""
    <form phx-change="org_change" phx-submit="org_save" phx-target={@myself}>
      <div class="card">
        <!-- Card header -->
        <div class="card-header">
          <div>
            <div class="card-title"><%= @form_title %></div>
            <div class="card-subtitle">
              Fill in all required fields. BANK ID and SYS ID are fixed 4-character codes.
            </div>
          </div>
          <div style="display:flex;gap:8px;align-items:center;">
            <button type="button" phx-click="org_cancel" phx-target={@myself} class="btn btn-secondary btn-sm">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary btn-sm">
              <%= if @is_new, do: "Create Organisation", else: "Save Changes" %>
            </button>
          </div>
        </div>

        <!-- Two-pane layout -->
        <div class="form-pane">

          <!-- Left: section navigation -->
          <div class="form-pane-nav">
            <div class="form-pane-nav-label">Sections</div>
            <%= for {idx, label, icon} <- @sections do %>
              <div
                phx-click="org_section"
                phx-value-s={idx}
                phx-target={@myself}
                class={"form-pane-nav-item#{if @org_section == idx, do: " active"}"}
              >
                <span class="form-pane-nav-num"><%= idx %></span>
                <span><%= icon %> <%= label %></span>
              </div>
            <% end %>
          </div>

          <!-- Right: active section fields -->
          <div class="form-pane-content">

            <!-- Section 1: Identity -->
            <div style={"display:#{if @org_section == 1, do: "block", else: "none"}"}>
              <div class="form-pane-section-title">🏦 Identity</div>
              <div class="form-grid">
                <div class="field">
                  <label>BANK ID <span style="color:var(--danger)">*</span></label>
                  <input type="text" name="org[bank_id]" value={@form_data["bank_id"]}
                    maxlength="4" placeholder="e.g. MMBD"
                    style="font-family:var(--font-mono);letter-spacing:.12em;text-transform:uppercase;font-size:16px;"
                    disabled={!@is_new}/>
                  <p class="hint">4-character code — cannot be changed after creation.</p>
                </div>
                <div class="field">
                  <label>Processor (SYS ID) <span style="color:var(--danger)">*</span></label>
                  <select name="org[sys_id]">
                    <%= for sys <- @sys_records do %>
                      <option value={sys.sys_id} selected={@form_data["sys_id"] == sys.sys_id}>
                        <%= sys.sys_id %> — <%= sys.description %>
                      </option>
                    <% end %>
                  </select>
                  <p class="hint">Parent processor / system record this org belongs to.</p>
                </div>
              </div>
              <div class="form-grid" style="margin-top:16px;">
                <div class="field form-grid-full" style="grid-column:1/-1;">
                  <label>Organisation Name <span style="color:var(--danger)">*</span></label>
                  <input type="text" name="org[org_name]" value={@form_data["org_name"]}
                    placeholder="e.g. Emirates NBD Bank PJSC"/>
                  <p class="hint">Full legal name of the institution.</p>
                </div>
                <div class="field form-grid-full" style="grid-column:1/-1;">
                  <label>Short Description / Reference Code <span style="color:var(--danger)">*</span></label>
                  <input type="text" name="org[description]" value={@form_data["description"]}
                    placeholder="e.g. Emirates NBD — Main Entity"/>
                  <p class="hint">Used in dropdown labels and log entries. Keep concise.</p>
                </div>
              </div>
            </div>

            <!-- Section 2: Classification -->
            <div style={"display:#{if @org_section == 2, do: "block", else: "none"}"}>
              <div class="form-pane-section-title">🏷️ Classification</div>
              <div class="form-grid">
                <div class="field">
                  <label>Organisation Type <span style="color:var(--danger)">*</span></label>
                  <select name="org[org_type]">
                    <%= for {label, val} <- @org_types do %>
                      <option value={val} selected={@form_data["org_type"] == val}><%= label %></option>
                    <% end %>
                  </select>
                  <p class="hint">Legal / business category of this institution.</p>
                </div>
                <div class="field">
                  <label>Regulatory Regime <span style="color:var(--danger)">*</span></label>
                  <select name="org[regulatory_regime]">
                    <%= for {label, code} <- @regimes do %>
                      <option value={code} selected={@form_data["regulatory_regime"] == code}><%= label %></option>
                    <% end %>
                  </select>
                  <p class="hint">Primary regulator that supervises this organisation.</p>
                </div>
              </div>
              <div style="margin-top:24px;padding:16px;background:#f8fafc;border:1px solid var(--border);border-radius:var(--radius);">
                <div style="font-size:12px;font-weight:600;color:var(--text-secondary);margin-bottom:8px;">About Organisation Types</div>
                <div style="font-size:12px;color:var(--text-muted);line-height:1.6;">
                  <strong>BANK</strong> — Full-service commercial bank with deposit-taking license.<br/>
                  <strong>CREDIT_UNION</strong> — Member-owned cooperative financial institution.<br/>
                  <strong>FINTECH</strong> — Non-bank issuer operating under an e-money or payment license.<br/>
                  <strong>ISSUER</strong> — Entity licensed specifically for card issuance via a network sponsor.
                </div>
              </div>
            </div>

            <!-- Section 3: Locale & Currency -->
            <div style={"display:#{if @org_section == 3, do: "block", else: "none"}"}>
              <div class="form-pane-section-title">🌐 Locale, Currency & Timezone</div>
              <div class="form-grid-3">
                <div class="field">
                  <label>Country of Incorporation <span style="color:var(--danger)">*</span></label>
                  <select name="org[country_code]">
                    <%= for {label, code} <- @countries do %>
                      <option value={code} selected={@form_data["country_code"] == code}><%= label %></option>
                    <% end %>
                  </select>
                  <p class="hint">ISO 3166-1 alpha-3.</p>
                </div>
                <div class="field">
                  <label>Functional Currency <span style="color:var(--danger)">*</span></label>
                  <select name="org[base_currency]">
                    <%= for {label, code} <- @currencies do %>
                      <option value={code} selected={@form_data["base_currency"] == code}><%= label %></option>
                    <% end %>
                  </select>
                  <p class="hint">ISO 4217 — primary booking currency.</p>
                </div>
                <div class="field">
                  <label>Billing Timezone <span style="color:var(--danger)">*</span></label>
                  <select name="org[billing_timezone]">
                    <%= for {label, tz} <- @timezones do %>
                      <option value={tz} selected={@form_data["billing_timezone"] == tz}><%= label %></option>
                    <% end %>
                  </select>
                  <p class="hint">IANA tz — used for EOD cutoff and statement dates.</p>
                </div>
              </div>
              <div style="margin-top:24px;padding:14px 16px;background:#eff6ff;border:1px solid #bfdbfe;border-radius:var(--radius);">
                <div style="font-size:12px;color:#1e40af;line-height:1.6;">
                  <strong>Note:</strong> The functional currency determines how monetary amounts are stored
                  and reported for accounts under this organisation. Changing it after accounts are created
                  requires a full balance restatement process.
                </div>
              </div>
            </div>

            <!-- Section 4: Settlement & GL -->
            <div style={"display:#{if @org_section == 4, do: "block", else: "none"}"}>
              <div class="form-pane-section-title">⚖️ Settlement & General Ledger</div>
              <div class="form-grid">
                <div class="field">
                  <label>SWIFT BIC</label>
                  <input type="text" name="org[swift_bic]" value={@form_data["swift_bic"]}
                    maxlength="11" placeholder="e.g. EBILAEAD"
                    style="font-family:var(--font-mono);letter-spacing:.06em;text-transform:uppercase;"/>
                  <p class="hint">8 or 11-character BIC for outgoing settlement messages (ISO 9362).</p>
                </div>
                <div class="field">
                  <label>GL Mapping Profile</label>
                  <input type="text" name="org[gl_mapping_profile]" value={@form_data["gl_mapping_profile"]}
                    maxlength="30" placeholder="e.g. PROFILE_AE_CREDIT"/>
                  <p class="hint">Identifier linking to the bank's chart-of-accounts configuration.</p>
                </div>
              </div>
              <div style="margin-top:24px;padding:14px 16px;background:#f0fdf4;border:1px solid #bbf7d0;border-radius:var(--radius);">
                <div style="font-size:12px;color:#14532d;line-height:1.6;">
                  <strong>SWIFT BIC</strong> is used when VisionPlus generates MT940/MT950 settlement
                  messages or ISO 20022 payment instructions. Leave blank if this organisation does not
                  participate in SWIFT-based settlement.<br/><br/>
                  <strong>GL Mapping Profile</strong> is referenced by the TRAMS clearing engine to
                  post financial entries to the correct GL accounts. Must match a profile configured
                  in the core banking integration layer.
                </div>
              </div>
            </div>

          </div><!-- /form-pane-content -->
        </div><!-- /form-pane -->

        <!-- Footer -->
        <div class="card-footer">
          <button type="button" phx-click="org_cancel" phx-target={@myself} class="btn btn-secondary">
            Cancel
          </button>
          <div style="display:flex;gap:8px;align-items:center;margin-left:auto;">
            <%= if @org_section > 1 do %>
              <button type="button" phx-click="org_section" phx-value-s={@org_section - 1}
                phx-target={@myself} class="btn btn-secondary">
                ← Previous
              </button>
            <% end %>
            <%= if @org_section < 4 do %>
              <button type="button" phx-click="org_section" phx-value-s={@org_section + 1}
                phx-target={@myself} class="btn btn-secondary">
                Next →
              </button>
            <% end %>
            <button type="submit" class="btn btn-primary">
              <%= if @is_new, do: "💾 Create Organisation", else: "💾 Save Changes" %>
            </button>
          </div>
        </div>

      </div><!-- /card -->
    </form>
    """
  end
end
