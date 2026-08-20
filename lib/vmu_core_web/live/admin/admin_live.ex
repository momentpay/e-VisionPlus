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
    GlComponent,
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

  # ---------------------------------------------------------------------------
  # Navigation taxonomy — the SINGLE source of truth for admin navigation.
  #
  # Three levels: nav module (top-level business domain, shown in the top
  # dock once Phase 2 lands) -> group (sidebar sub-heading) -> item (a leaf
  # screen). This replaces the old flat 5-section grouping, which was an ASM
  # permission heuristic ("who touches this during a shift"), with a
  # business-domain IA derived from docs/compare/Kosa_Handbook_Alignment_Assessment.md
  # and standard card-platform taxonomy (Way4/VisionPlus).
  #
  # Adding a *live* module means adding one row to @modules plus one render
  # branch below. The sidebar is generated from this map, so a module can no
  # longer be registered yet invisible — which is exactly what happened to
  # "gl" when the sidebar was a hand-written list duplicating these labels
  # and icons.
  #
  # `module` (the @modules map key) must also exist in
  # `VmuCore.ASM.RolePermission.modules()` and be granted to at least one
  # role, or it will be filtered out of `visible_modules` and stay hidden.
  # See docs/shared/Admin_Menu_Standard.md.
  #
  # `order` is a single integer spaced by 10s, increasing continuously across
  # all of a nav module's groups (not reset per group) — that's enough to
  # sort deterministically by plain `order` and then cluster into groups by
  # adjacency, with no separate "group order" field to keep in sync.
  # ---------------------------------------------------------------------------
  @nav_modules [
    %{id: "overview",        label: "Overview",                 icon: "🏠", order: 10},
    %{id: "party",           label: "Party & Customer",          icon: "👤", order: 20},
    %{id: "cards_accounts",  label: "Cards & Accounts",          icon: "💳", order: 30},
    %{id: "platform_config", label: "Platform Configuration",    icon: "⚙️", order: 40},
    %{id: "authorization",   label: "Authorization & Switching", icon: "🔀", order: 50},
    %{id: "transactions",    label: "Transactions & Settlement", icon: "🔁", order: 60},
    %{id: "collections",     label: "Collections & Recovery",    icon: "📮", order: 70},
    %{id: "disputes",        label: "Disputes & Chargebacks",    icon: "⚖️", order: 80},
    %{id: "risk",            label: "Risk, Fraud & Compliance",  icon: "🛡️", order: 90},
    %{id: "finance",         label: "Finance & General Ledger",  icon: "📒", order: 100},
    %{id: "merchant",        label: "Merchant & Acquiring",      icon: "🏪", order: 110},
    %{id: "loyalty",         label: "Loyalty & Rewards",         icon: "🎁", order: 120},
    %{id: "security",        label: "Security & Access",         icon: "🔐", order: 130}
  ]

  @modules %{
    # -- Party & Customer --
    "customer"      => %{label: "Customers (CIF)",        icon: "👤",  nav_module: "party", group: "Customer Management", order: 10},
    "kyc_methods"   => %{label: "KYC Methods",             icon: "🪪",  nav_module: "party", group: "Onboarding & KYC",    order: 20},
    "kyc_requests"  => %{label: "KYC Requests",            icon: "📋",  nav_module: "party", group: "Onboarding & KYC",    order: 30},

    # -- Cards & Accounts --
    "account"       => %{label: "Accounts (CMS)",          icon: "💳",  nav_module: "cards_accounts", group: "Accounts",              order: 10},
    "debit"         => %{label: "Debit Cards",             icon: "🏦",  nav_module: "cards_accounts", group: "Card Products",         order: 20},
    "prepaid"       => %{label: "Prepaid Cards",           icon: "💳",  nav_module: "cards_accounts", group: "Card Products",         order: 30},
    "hcs"           => %{label: "Corporate Cards (HCS)",   icon: "🏢",  nav_module: "cards_accounts", group: "Card Products",         order: 40},
    "wallet"        => %{label: "Digital Wallet",          icon: "👛",  nav_module: "cards_accounts", group: "Card Products",         order: 50},
    "logo"          => %{label: "Products / Logos",        icon: "💳",  nav_module: "cards_accounts", group: "Product Configuration", order: 60},
    "block"         => %{label: "Sub-Product Blocks",      icon: "🧩",  nav_module: "cards_accounts", group: "Product Configuration", order: 70},

    # -- Platform Configuration --
    "system"        => %{label: "System Parameters",       icon: "⚙️",  nav_module: "platform_config", group: "Hierarchy", order: 10},
    "organization"  => %{label: "Organizations",           icon: "🏦",  nav_module: "platform_config", group: "Hierarchy", order: 20},
    "module_config" => %{label: "Module Configuration",    icon: "🧰",  nav_module: "platform_config", group: "Framework", order: 30},

    # -- Authorization & Switching --
    "exceptions"    => %{label: "Exception Queue",         icon: "🚨",  nav_module: "authorization", group: "Live Authorization", order: 10},
    "auth_history"  => %{label: "Auth History",            icon: "🔍",  nav_module: "authorization", group: "Live Authorization", order: 20},

    # -- Transactions & Settlement --
    "tram_inquiry"  => %{label: "TRAM Inquiry",            icon: "🧾",  nav_module: "transactions", group: "Inquiry", order: 10},

    # -- Collections & Recovery --
    "col"           => %{label: "Collections & Recovery",  icon: "📮",  nav_module: "collections", group: "Servicing",              order: 10},
    "collections_mi" => %{label: "Collections MI",         icon: "📊",  nav_module: "collections", group: "Management Information", order: 20},

    # -- Disputes & Chargebacks --
    "dps"           => %{label: "Disputes (DPS)",          icon: "⚖️",  nav_module: "disputes", group: "Disputes", order: 10},

    # -- Finance & General Ledger --
    "gl"            => %{label: "General Ledger",          icon: "📒",  nav_module: "finance", group: "Ledger",         order: 10},
    "cms_eod"       => %{label: "EOD Job Status",          icon: "🌙",  nav_module: "finance", group: "Period Control", order: 20},
    "cms_resegmentation" => %{label: "Cycle Resegmentation", icon: "🔄", nav_module: "finance", group: "Period Control", order: 30},

    # -- Security & Access --
    "approvals"     => %{label: "Approval Inbox",          icon: "✅",  nav_module: "security", group: "Approvals & Audit", order: 10},
    "audit_log"     => %{label: "Audit Trail",             icon: "📜",  nav_module: "security", group: "Approvals & Audit", order: 20},
    "operators"     => %{label: "Operators",               icon: "🔐",  nav_module: "security", group: "Identity & Access", order: 30},
    "service_accounts" => %{label: "Service Accounts",     icon: "🔑",  nav_module: "security", group: "Identity & Access", order: 40}
  }

  # Coming-soon placeholders: real gaps already named in
  # docs/compare/Kosa_Handbook_Alignment_Assessment.md, given a home in the
  # navigation ahead of being built. Not permission-gated (there is nothing
  # behind them yet to protect) and not rendered until Phase 2 of the top-nav
  # rollout wires them into the sidebar as inert "Soon" items.
  #
  # `order` is always >= 900 so a coming-soon item always sorts after any
  # live item sharing its group, without needing to coordinate numbering
  # with the @modules list above.
  @coming_soon [
    %{id: "overview_dashboard",    label: "Dashboard",                icon: "📈", nav_module: "overview",      group: nil,                     order: 900},

    %{id: "party_360",             label: "Party 360",                icon: "🧿", nav_module: "party",         group: "Customer Management",   order: 900},
    %{id: "customer_arrangements", label: "Customer Arrangements",    icon: "📑", nav_module: "party",         group: "Arrangements",          order: 900},

    %{id: "stip_thresholds",       label: "STIP Thresholds",          icon: "🧮", nav_module: "authorization", group: "Stand-In & Rules",      order: 900},
    %{id: "gateway_rules",         label: "Gateway Rule Engine",      icon: "🧷", nav_module: "authorization", group: "Stand-In & Rules",      order: 910},

    %{id: "clearing_batches",      label: "Clearing Batches",         icon: "🗂️", nav_module: "transactions",  group: "Clearing & Settlement", order: 900},
    %{id: "settlement_runs",       label: "Settlement Runs",          icon: "💸", nav_module: "transactions",  group: "Clearing & Settlement", order: 910},
    %{id: "reconciliation_3way",   label: "Three-Way Reconciliation", icon: "🧩", nav_module: "transactions",  group: "Reconciliation",        order: 900},

    %{id: "chargebacks",           label: "Chargeback Cases",         icon: "🔁", nav_module: "disputes",      group: "Chargebacks",           order: 900},

    %{id: "sanctions_review",      label: "Sanctions Review",         icon: "🕵️", nav_module: "risk",          group: "Screening",             order: 900},
    %{id: "fraud_case_mgmt",       label: "Fraud Case Management",    icon: "🚩", nav_module: "risk",          group: "Fraud Operations",      order: 900},
    %{id: "credit_scoring_admin",  label: "Application Scoring",      icon: "🧮", nav_module: "risk",          group: "Credit Decisioning",    order: 900},

    %{id: "accounting_periods",    label: "Accounting Periods",       icon: "📅", nav_module: "finance",       group: "Period Control",        order: 900},

    %{id: "merchants",             label: "Merchants",                icon: "🏪", nav_module: "merchant",      group: nil,                     order: 900},
    %{id: "terminals",             label: "Terminals",                icon: "🖲️", nav_module: "merchant",      group: nil,                     order: 910},
    %{id: "mdr_config",            label: "MDR Configuration",        icon: "💱", nav_module: "merchant",      group: nil,                     order: 920},

    %{id: "loyalty_schemes",       label: "Schemes & Plans",          icon: "🎯", nav_module: "loyalty",       group: nil,                     order: 900},
    %{id: "points_ledger",         label: "Points Ledger",            icon: "🧾", nav_module: "loyalty",       group: nil,                     order: 910},
    %{id: "redemptions",           label: "Redemptions",              icon: "🎁", nav_module: "loyalty",       group: nil,                     order: 920}
  ]

  @doc "Ordered top-level nav modules."
  def nav_modules, do: @nav_modules

  @doc """
  Live modules of one nav module that this operator may see, grouped and
  ordered for the sidebar.
  """
  def items_for_nav_module(nav_module_id, visible) do
    @modules
    |> Enum.filter(fn {mod, meta} -> meta.nav_module == nav_module_id and mod in visible end)
    |> Enum.sort_by(fn {_mod, meta} -> meta.order end)
  end

  @doc """
  Live items of one nav module, clustered into `{group_label, items}` pairs
  in display order — the shape the sidebar template renders directly. Groups
  are inferred from item adjacency after sorting by `order` rather than
  tracked separately, since `order` already increases continuously across a
  nav module's groups (see the @modules moduledoc above).
  """
  def grouped_items_for_nav_module(nav_module_id, visible) do
    nav_module_id
    |> items_for_nav_module(visible)
    |> Enum.chunk_by(fn {_mod, meta} -> meta.group end)
    |> Enum.map(fn [{_mod, %{group: group}} | _] = chunk -> {group, chunk} end)
  end

  @doc "Coming-soon placeholders for one nav module, in display order."
  def coming_soon_for_nav_module(nav_module_id) do
    @coming_soon
    |> Enum.filter(&(&1.nav_module == nav_module_id))
    |> Enum.sort_by(& &1.order)
  end

  @doc "The full live-module registry. Used by the consistency guard test."
  def menu_registry, do: @modules

  @doc "The full coming-soon placeholder list. Used by the consistency guard test."
  def coming_soon_registry, do: @coming_soon

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

        <%!-- Generated from @modules — never hand-list items here. A module that
            is registered but has no role permission simply does not appear;
            see docs/shared/Admin_Menu_Standard.md. Nav-module headings are
            shown even though the top dock itself lands in Phase 2, so the
            sidebar already reflects the new IA. --%>
        <%= for %{id: nav_id, label: nav_label} <- nav_modules(),
                groups = grouped_items_for_nav_module(nav_id, @visible_modules),
                groups != [] do %>
          <div class="sidebar-section">
            <div class="sidebar-section-label"><%= nav_label %></div>

            <%= for {group_label, items} <- groups do %>
              <div :if={group_label} class="sidebar-group-label"><%= group_label %></div>
              <.sidebar_nav_item :for={{mod, meta} <- items}
                mod={mod} label={meta.label} icon={meta.icon} active={@active_module} />
            <% end %>
          </div>
          <div class="sidebar-divider"/>
        <% end %>

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
              <% "gl" -> %>
                <.live_component module={GlComponent} id="gl-component"
                  current_operator={@current_operator} />

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
