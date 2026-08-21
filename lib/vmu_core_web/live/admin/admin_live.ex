defmodule VmuCoreWeb.Live.Admin.AdminLive do
  @moduledoc """
  Root LiveView for the VisionPlus hierarchy-based admin UI.

  Route:  /visionplus/admin          → system parameters
          /visionplus/admin/:module  → system | organization | logo

  The shell renders the sidebar and topbar; the active module is delegated
  to a child LiveComponent so each module has its own isolated state.
  """
  use Phoenix.LiveView, layout: false

  import VmuCoreWeb.AdminUI

  alias VmuCore.ASM.Authz

  alias VmuCoreWeb.Live.Admin.{
    SystemComponent,
    OrganizationComponent,
    LogoComponent,
    BlockComponent,
    CustomerComponent,
    AccountComponent,
    ExceptionQueueComponent,
    AuthHistoryComponent,
    TramInquiryComponent,
    OperatorComponent,
    ApprovalInboxComponent,
    AuditLogComponent,
    ModuleConfigComponent,
    DpsComponent,
    CmsEodComponent,
    CmsResegmentationComponent,
    ColComponent,
    CollectionsMiComponent,
    HcsComponent,
    DebitComponent,
    PrepaidComponent,
    WalletComponent,
    KycMethodsComponent,
    KycRequestsComponent,
    ServiceAccountsComponent
  }

  @modules %{
    "system"       => %{label: "System Parameters",      icon: "⚙️",  section: :sys},
    "organization" => %{label: "Organizations",           icon: "🏦",  section: :org},
    "logo"         => %{label: "Products / Logos",        icon: "💳",  section: :logo},
    "block"        => %{label: "Sub-Product Blocks",      icon: "🧩",  section: :block},
    "module_config" => %{label: "Module Configuration",   icon: "🧰",  section: :sys},
    "customer"     => %{label: "Customers (CIF)",         icon: "👤",  section: :customer},
    "account"      => %{label: "Accounts (CMS)",          icon: "💳",  section: :account},
    "exceptions"   => %{label: "Exception Queue",         icon: "🚨",  section: :fas},
    "auth_history" => %{label: "Auth History",            icon: "🔍",  section: :fas},
    "tram_inquiry" => %{label: "TRAM Inquiry",            icon: "🧾",  section: :fas},
    "dps"          => %{label: "Disputes (DPS)",          icon: "⚖️",  section: :fas},
    "cms_eod"      => %{label: "EOD Job Status",          icon: "🌙",  section: :account},
    "cms_resegmentation" => %{label: "Cycle Resegmentation", icon: "🔄", section: :account},
    "col"          => %{label: "Collections & Recovery",  icon: "📮",  section: :account},
    "collections_mi" => %{label: "Collections MI",        icon: "📊",  section: :account},
    "hcs"          => %{label: "Corporate Cards (HCS)",   icon: "🏢",  section: :account},
    "debit"        => %{label: "Debit Cards",              icon: "🏦",  section: :account},
    "prepaid"      => %{label: "Prepaid Cards",             icon: "💳",  section: :account},
    "wallet"       => %{label: "Digital Wallet",            icon: "👛",  section: :account},
    "kyc_methods"  => %{label: "KYC Methods",               icon: "🪪",  section: :account},
    "kyc_requests" => %{label: "KYC Requests",              icon: "📋",  section: :account},
    "operators"    => %{label: "Operators",               icon: "🔐",  section: :security},
    "service_accounts" => %{label: "Service Accounts",    icon: "🔑",  section: :security},
    "approvals"    => %{label: "Approval Inbox",          icon: "✅",  section: :security},
    "audit_log"    => %{label: "Audit Trail",             icon: "📜",  section: :security}
  }

  @impl true
  def mount(_params, _session, socket) do
    # :current_operator is assigned by the OperatorAuth on_mount hook (ASM-P1)
    operator = socket.assigns.current_operator

    {:ok, assign(socket,
      page_title: "VisionPlus Admin",
      active_module: "system",
      deep_link_id: nil,
      modules: @modules,
      # "module_config" has no RolePermission rows of its own (Module Configuration
      # Framework v1 gate) — whoever can view "system" can view module config too.
      visible_modules: expand_module_config_visibility(Authz.permitted_modules(operator)),
      can_approve_exceptions: Authz.can?(operator, "exceptions", "approve")
    )}
  end

  @impl true
  def handle_params(%{"module" => mod} = params, _uri, socket) when is_map_key(@modules, mod) do
    # Koṣa domain-model alignment (2026-07-28) — the Arrangements panels
    # link here with ?view=<id> so "View in X" opens that record's detail
    # page directly instead of landing on the bare module list.
    {:noreply, assign(socket, active_module: mod, deep_link_id: Map.get(params, "view"))}
  end
  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, active_module: "system", deep_link_id: nil)}
  end

  defp expand_module_config_visibility(visible) do
    if MapSet.member?(visible, "system"), do: MapSet.put(visible, "module_config"), else: visible
  end

  @impl true
  def handle_info({:navigate, mod}, socket) do
    {:noreply, push_patch(socket, to: "/visionplus/admin/#{mod}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()}/>
      <title>VisionPlus Admin</title>
      <link rel="stylesheet" href="/assets/admin.css"/>
      <script src="/assets/phoenix.min.js"></script>
      <script src="/assets/phoenix_live_view.js"></script>
      <script>
        const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
        const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
          params: {_csrf_token: csrfToken}
        })
        liveSocket.connect()
      </script>
    </head>
    <body>
    <div class="admin-layout">

      <%# ── Sidebar ──────────────────────────────────────────── %>
      <nav class="admin-sidebar">
        <div class="sidebar-logo">
          <div class="product-name">VisionPlus</div>
          <div class="product-tag">Admin Console</div>
        </div>

        <div class="sidebar-section">
          <div class="sidebar-section-label">Parameter Hierarchy</div>

          <.sidebar_nav_item :if={"system" in @visible_modules}       mod="system"       label="System Parameters"   icon="⚙️"  active={@active_module} />
          <.sidebar_nav_item :if={"organization" in @visible_modules} mod="organization" label="Organizations"        icon="🏦"  active={@active_module} />
          <.sidebar_nav_item :if={"logo" in @visible_modules}         mod="logo"         label="Products / Logos"     icon="💳"  active={@active_module} />
          <.sidebar_nav_item :if={"block" in @visible_modules}        mod="block"        label="Sub-Product Blocks"   icon="🧩"  active={@active_module} />
          <.sidebar_nav_item :if={"module_config" in @visible_modules} mod="module_config" label="Module Configuration" icon="🧰"  active={@active_module} />
        </div>

        <div class="sidebar-divider"/>

        <div class="sidebar-section">
          <div class="sidebar-section-label">Operations</div>

          <.sidebar_nav_item :if={"customer" in @visible_modules} mod="customer" label="Customers (CIF)" icon="👤" active={@active_module} />
          <.sidebar_nav_item :if={"account" in @visible_modules}  mod="account"  label="Accounts (CMS)"  icon="💳" active={@active_module} />
          <.sidebar_nav_item :if={"cms_eod" in @visible_modules}  mod="cms_eod"  label="EOD Job Status"  icon="🌙" active={@active_module} />
          <.sidebar_nav_item :if={"cms_resegmentation" in @visible_modules}  mod="cms_resegmentation"  label="Cycle Resegmentation"  icon="🔄" active={@active_module} />
          <.sidebar_nav_item :if={"col" in @visible_modules}      mod="col"      label="Collections & Recovery" icon="📮" active={@active_module} />
          <.sidebar_nav_item :if={"collections_mi" in @visible_modules} mod="collections_mi" label="Collections MI" icon="📊" active={@active_module} />
          <.sidebar_nav_item :if={"hcs" in @visible_modules} mod="hcs" label="Corporate Cards (HCS)" icon="🏢" active={@active_module} />
          <.sidebar_nav_item :if={"debit" in @visible_modules} mod="debit" label="Debit Cards" icon="🏦" active={@active_module} />
          <.sidebar_nav_item :if={"prepaid" in @visible_modules} mod="prepaid" label="Prepaid Cards" icon="💳" active={@active_module} />
          <.sidebar_nav_item :if={"wallet" in @visible_modules} mod="wallet" label="Digital Wallet" icon="👛" active={@active_module} />
          <.sidebar_nav_item :if={"kyc_methods" in @visible_modules} mod="kyc_methods" label="KYC Methods" icon="🪪" active={@active_module} />
          <.sidebar_nav_item :if={"kyc_requests" in @visible_modules} mod="kyc_requests" label="KYC Requests" icon="📋" active={@active_module} />
        </div>

        <div class="sidebar-divider"/>

        <div class="sidebar-section">
          <div class="sidebar-section-label">FAS Observability</div>

          <.sidebar_nav_item :if={"exceptions" in @visible_modules}   mod="exceptions"   label="Exception Queue" icon="🚨" active={@active_module} />
          <.sidebar_nav_item :if={"auth_history" in @visible_modules} mod="auth_history" label="Auth History"    icon="🔍" active={@active_module} />
          <.sidebar_nav_item :if={"tram_inquiry" in @visible_modules} mod="tram_inquiry" label="TRAM Inquiry"    icon="🧾" active={@active_module} />
          <.sidebar_nav_item :if={"dps" in @visible_modules}          mod="dps"          label="Disputes (DPS)"  icon="⚖️" active={@active_module} />
        </div>

        <% security_visible = Enum.any?(~w[operators approvals audit_log], &(&1 in @visible_modules)) %>
        <div :if={security_visible} class="sidebar-divider"/>

        <div :if={security_visible} class="sidebar-section">
          <div class="sidebar-section-label">Security &amp; Control</div>

          <.sidebar_nav_item :if={"approvals" in @visible_modules} mod="approvals" label="Approval Inbox" icon="✅" active={@active_module} />
          <.sidebar_nav_item :if={"audit_log" in @visible_modules} mod="audit_log" label="Audit Trail" icon="📜" active={@active_module} />
          <.sidebar_nav_item :if={"operators" in @visible_modules} mod="operators" label="Operators" icon="🔐" active={@active_module} />
          <.sidebar_nav_item :if={"service_accounts" in @visible_modules} mod="service_accounts" label="Service Accounts" icon="🔑" active={@active_module} />
        </div>

        <div class="sidebar-divider"/>

        <div class="sidebar-section">
          <div class="sidebar-section-label">Legacy</div>
          <a class="sidebar-item" href="/visionplus">
            <span class="icon">🖥️</span> Terminal UI
          </a>
          <a class="sidebar-item" href="/dashboard">
            <span class="icon">📊</span> Dashboard
          </a>
        </div>

        <div class="sidebar-footer">
          VisionPlus vmu_core
        </div>
      </nav>

      <%# ── Topbar ───────────────────────────────────────────── %>
      <header class="admin-topbar">
        <div class="topbar-breadcrumb">
          <span>VisionPlus</span>
          <span class="sep">/</span>
          <span class="current"><%= Map.get(@modules, @active_module, %{label: @active_module})[:label] %></span>
        </div>
        <div class="topbar-actions">
          <span class="text-sm text-muted">SYS: PROC</span>
          <span class="text-sm" style="margin-left:1rem">
            👤 <%= @current_operator.display_name %>
            <span class="text-muted">(<%= @current_operator.role %>)</span>
          </span>
          <a href="/visionplus/admin/logout" class="text-sm" style="margin-left:0.75rem">Sign out</a>
        </div>
      </header>

      <%# ── Main content ──────────────────────────────────────── %>
      <main class="admin-main">
        <%= cond do %>
          <% @active_module not in @visible_modules -> %>
            <%# Server-side gate (ASM-P2) — deep links can't bypass the sidebar %>
            <div class="component-panel">
              <h2>🔒 Access denied</h2>
              <p class="text-muted">
                Your role (<%= @current_operator.role %>) does not have access to this module.
              </p>
            </div>
          <% true -> %>
            <%= case @active_module do %>
              <% "system" -> %>
                <.live_component module={SystemComponent} id="sys-component"
                                 current_operator={@current_operator} />
              <% "organization" -> %>
                <.live_component module={OrganizationComponent} id="org-component"
                                 current_operator={@current_operator} />
              <% "logo" -> %>
                <.live_component module={LogoComponent} id="logo-component"
                                 current_operator={@current_operator} />
              <% "block" -> %>
                <.live_component module={BlockComponent} id="block-component"
                                 current_operator={@current_operator} />
              <% "module_config" -> %>
                <.live_component module={ModuleConfigComponent} id="module-config-component"
                                 current_operator={@current_operator} />
              <% "customer" -> %>
                <.live_component module={CustomerComponent} id="customer-component"
                                 current_operator={@current_operator} />
              <% "account" -> %>
                <.live_component module={AccountComponent} id="account-component"
                                 current_operator={@current_operator} deep_link_id={@deep_link_id} />
              <% "cms_eod" -> %>
                <.live_component module={CmsEodComponent} id="cms-eod-component"
                                 current_operator={@current_operator} />
              <% "cms_resegmentation" -> %>
                <.live_component module={CmsResegmentationComponent} id="cms-resegmentation-component"
                                 current_operator={@current_operator} />
              <% "col" -> %>
                <.live_component module={ColComponent} id="col-component"
                                 current_operator={@current_operator} />
              <% "collections_mi" -> %>
                <.live_component module={CollectionsMiComponent} id="collections-mi-component"
                                 current_operator={@current_operator} />
              <% "hcs" -> %>
                <.live_component module={HcsComponent} id="hcs-component"
                                 current_operator={@current_operator} deep_link_id={@deep_link_id} />
              <% "debit" -> %>
                <.live_component module={DebitComponent} id="debit-component"
                                 current_operator={@current_operator} deep_link_id={@deep_link_id} />
              <% "prepaid" -> %>
                <.live_component module={PrepaidComponent} id="prepaid-component"
                                 current_operator={@current_operator} deep_link_id={@deep_link_id} />
              <% "wallet" -> %>
                <.live_component module={WalletComponent} id="wallet-component"
                                 current_operator={@current_operator} deep_link_id={@deep_link_id} />
              <% "kyc_methods" -> %>
                <.live_component module={KycMethodsComponent} id="kyc-methods-component"
                                 current_operator={@current_operator} />
              <% "kyc_requests" -> %>
                <.live_component module={KycRequestsComponent} id="kyc-requests-component"
                                 current_operator={@current_operator} />
              <% "exceptions" -> %>
                <.live_component module={ExceptionQueueComponent} id="exceptions-component"
                                 can_approve={@can_approve_exceptions} />
              <% "auth_history" -> %>
                <.live_component module={AuthHistoryComponent} id="auth-history-component" />
              <% "tram_inquiry" -> %>
                <.live_component module={TramInquiryComponent} id="tram-inquiry-component" />
              <% "dps" -> %>
                <.live_component module={DpsComponent} id="dps-component"
                                 current_operator={@current_operator} />
              <% "operators" -> %>
                <.live_component module={OperatorComponent} id="operators-component"
                                 current_operator={@current_operator} />
              <% "service_accounts" -> %>
                <.live_component module={ServiceAccountsComponent} id="service-accounts-component"
                                 current_operator={@current_operator} />
              <% "approvals" -> %>
                <.live_component module={ApprovalInboxComponent} id="approvals-component"
                                 current_operator={@current_operator} />
              <% "audit_log" -> %>
                <.live_component module={AuditLogComponent} id="audit-log-component" />
              <% _ -> %>
                <p>Unknown module.</p>
            <% end %>
        <% end %>
      </main>

    </div>
    </body>
    </html>
    """
  end

  # ── Private components ──────────────────────────────────────────────────────

  defp sidebar_nav_item(assigns) do
    ~H"""
    <a
      class={"sidebar-item#{if @mod == @active, do: " active", else: ""}"}
      href={"/visionplus/admin/#{@mod}"}
    >
      <span class="icon"><%= @icon %></span>
      <%= @label %>
    </a>
    """
  end

end
