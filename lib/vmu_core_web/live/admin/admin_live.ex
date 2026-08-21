defmodule VmuCoreWeb.Live.Admin.AdminLive do
  @moduledoc """
  Root LiveView for the VisionPlus admin console.

  Route:  /visionplus/admin           → the operator's first permitted screen
          /visionplus/admin/:module   → one leaf screen, or a nav module's
                                        placeholder page when it has no live
                                        screens yet

  The shell renders the module dock, the contextual sidebar and the
  breadcrumb; the active screen is delegated to a child LiveComponent so each
  keeps its own isolated state.

  Navigation data lives in `VmuCoreWeb.Admin.Nav` — this module renders it and
  does not decide it. Adding a screen means one row there plus one render
  branch here; see `docs/shared/Admin_Menu_Standard.md`.
  """
  use Phoenix.LiveView, layout: false

  import VmuCoreWeb.AdminUI
  import VmuCoreWeb.Icons

  alias VmuCore.ASM.Authz
  alias VmuCoreWeb.Admin.Nav

  alias VmuCoreWeb.Live.Admin.{
    PortfolioDashboardComponent,
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
    ServiceAccountsComponent,
    WpsComponent
  }

  # Materialised at compile time so `handle_params/3` can guard on them —
  # function calls are not allowed in guards, module attributes are.
  @live_ids Nav.live_ids()
  @nav_ids Nav.nav_module_ids()

  @doc "The live-screen registry. Used by the menu consistency guard test."
  defdelegate menu_registry, to: Nav, as: :registry

  @doc "Ordered top-level nav modules."
  defdelegate nav_modules, to: Nav

  @impl true
  def mount(_params, _session, socket) do
    # :current_operator is assigned by the OperatorAuth on_mount hook (ASM-P1)
    operator = socket.assigns.current_operator

    visible = expand_module_config_visibility(Authz.permitted_modules(operator))

    {:ok,
     assign(socket,
       page_title: "VisionPlus Admin",
       active_module: landing_module(visible),
       deep_link_id: nil,
       visible_modules: visible,
       can_approve_exceptions: Authz.can?(operator, "exceptions", "approve")
     )}
  end

  @impl true
  def handle_params(%{"module" => mod} = params, _uri, socket) when mod in @live_ids do
    # Koṣa domain-model alignment (2026-07-28) — the Arrangements panels
    # link here with ?view=<id> so "View in X" opens that record's detail
    # page directly instead of landing on the bare module list.
    {:noreply, assign(socket, active_module: mod, deep_link_id: Map.get(params, "view"))}
  end

  # A nav module the operator has no live screen in (e.g. "loyalty") links to
  # its own id and lands on the placeholder page rather than a dead route.
  def handle_params(%{"module" => mod}, _uri, socket) when mod in @nav_ids do
    {:noreply, assign(socket, active_module: mod, deep_link_id: nil)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     assign(socket,
       active_module: landing_module(socket.assigns.visible_modules),
       deep_link_id: nil
     )}
  end

  # Where a bare /visionplus/admin goes. "system" for anyone who can see it —
  # which is the historical behaviour and what most operators get — otherwise
  # the first screen this operator actually has, so a narrow role does not
  # land on "access denied" every time they open the console.
  defp landing_module(visible) do
    if "system" in visible do
      "system"
    else
      Enum.find(Nav.live_items(), &(&1.id in visible))
      |> case do
        %{id: id} -> id
        nil -> "system"
      end
    end
  end

  defp expand_module_config_visibility(visible) do
    # "module_config" has no RolePermission rows of its own (Module
    # Configuration Framework v1 gate) — whoever can view "system" can view
    # module config too.
    if MapSet.member?(visible, "system"), do: MapSet.put(visible, "module_config"), else: visible
  end

  @impl true
  def handle_info({:navigate, mod}, socket) do
    {:noreply, push_patch(socket, to: "/visionplus/admin/#{mod}")}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:active_nav, Nav.nav_module_for(assigns.active_module))
      |> assign(:landing?, Nav.nav_module_landing?(assigns.active_module))

    assigns = assign(assigns, :nav_module, Nav.nav_module(assigns.active_nav))

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()}/>
      <meta :if={ag_grid_license_key()} name="ag-grid-license" content={ag_grid_license_key()}/>
      <title>VisionPlus Admin</title>
      <link rel="stylesheet" href="/assets/admin.css"/>
      <link rel="stylesheet" href="/assets/css/ag_grid.css"/>
      <script>
        // Applied before first paint so the page never flashes the wrong
        // theme on load. The toggle in the header writes the same key.
        // Deliberately inline and dependency-free — it must not wait on
        // the app.js bundle below.
        (function () {
          try {
            var t = localStorage.getItem("vp-theme");
            if (!t) t = matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
            document.documentElement.setAttribute("data-theme", t);
          } catch (e) {
            document.documentElement.setAttribute("data-theme", "light");
          }
        })();

        function vpToggleTheme() {
          var el = document.documentElement;
          var next = el.getAttribute("data-theme") === "dark" ? "light" : "dark";
          el.setAttribute("data-theme", next);
          try { localStorage.setItem("vp-theme", next); } catch (e) {}
        }
      </script>
      <%!-- Bundled by esbuild (assets/js/app.js) -- phoenix, phoenix_live_view,
          the hooks registry (AgGrid, AgChart) and AG Grid/AG Charts
          Enterprise themselves. Run `mix assets.build` after editing
          anything under assets/js. --%>
      <script defer type="text/javascript" src="/assets/js/app.js"></script>
    </head>
    <body>
    <.sprite />

    <%!-- ── Module dock (level 1) ─────────────────────────────────
        Every nav module is shown, including ones with no live screen yet, so
        the dock reads as the platform's shape rather than only its finished
        parts. A module with nothing built lands on its placeholder page. --%>
    <header class="app-header">
      <a class="brand" href="/visionplus/admin">
        <span class="brand-mark">VisionPlus</span>
        <span class="brand-tag">Issuing</span>
      </a>

      <nav class="module-dock" aria-label="Business modules">
        <.dock_item :for={nav <- Nav.nav_modules()}
          nav={nav}
          target={Nav.dock_target(nav.id, @visible_modules)}
          active={nav.id == @active_nav} />
      </nav>

      <div class="header-actions">
        <button type="button" class="icon-btn" onclick="vpToggleTheme()"
                title="Toggle light / dark theme" aria-label="Toggle light / dark theme">
          <.icon name="moon" />
        </button>

        <span class="operator-chip">
          <span class="operator-avatar"><%= initials(@current_operator.display_name) %></span>
          <span class="operator-meta">
            <span class="operator-name"><%= @current_operator.display_name %></span>
            <span class="operator-role"><%= @current_operator.role %></span>
          </span>
        </span>

        <a href="/visionplus/admin/logout" class="icon-btn" title="Sign out" aria-label="Sign out">
          <.icon name="logout" />
        </a>
      </div>
    </header>

    <div class="app-body">

      <%!-- ── Contextual sidebar (levels 2 and 3) ────────────────
          Shows only the active module's groups. Generated from
          VmuCoreWeb.Admin.Nav — never hand-listed here. --%>
      <aside class="sidebar" data-accent={@nav_module.accent}
             aria-label={"#{@nav_module.label} navigation"}>
        <div class="sidebar-module">
          <span class="sidebar-module-tile"><.icon name={@nav_module.icon} /></span>
          <span class="sidebar-module-meta">
            <span class="sidebar-module-eyebrow">Module</span>
            <span class="sidebar-module-name"><%= @nav_module.label %></span>
          </span>
        </div>

        <nav class="sidebar-nav">
          <details :for={{group, items} <- Nav.sidebar_groups(@active_nav, @visible_modules)}
                   class="nav-group" open>
            <summary>
              <span><%= group %></span>
              <.icon name="chevron-down" />
            </summary>
            <ul class="nav-items">
              <li :for={item <- items}>
                <.nav_item item={item} active={item.id == @active_module} />
              </li>
            </ul>
          </details>
        </nav>

        <div class="sidebar-footer">
          <a href="/visionplus"><.icon name="cpu-chip" /> Terminal UI</a>
          <a href="/dashboard"><.icon name="signal" /> LiveDashboard</a>
        </div>
      </aside>

      <%!-- ── Main content ──────────────────────────────────────── --%>
      <main class="admin-main">
        <div class="content-breadcrumb">
          <span><%= @nav_module.label %></span>
          <%= unless @landing? do %>
            <span class="sep">/</span>
            <span class="current"><%= screen_label(@active_module) %></span>
          <% end %>
        </div>

        <%= cond do %>
          <% @landing? -> %>
            <.coming_soon_panel nav={@nav_module} />
          <% @active_module not in @visible_modules -> %>
            <%!-- Server-side gate (ASM-P2) — deep links can't bypass the sidebar --%>
            <div class="component-panel">
              <h2>Access denied</h2>
              <p class="text-muted">
                Your role (<%= @current_operator.role %>) does not have access to this module.
              </p>
            </div>
          <% true -> %>
            <%= case @active_module do %>
              <% "portfolio_dashboard" -> %>
                <.live_component module={PortfolioDashboardComponent} id="portfolio-dashboard-component"
                                 current_operator={@current_operator} />
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

              # All five WPS screens are one component — they are five views of
              # one workflow keyed on the same employer selection. `screen`
              # picks the view; the nav still lists them separately so an
              # operator finds "Disbursement Exceptions" by name.
              <% screen when screen in ~w[wps_employers wps_files wps_exceptions wps_refunds wps_reports] -> %>
                <.live_component module={WpsComponent} id="wps-component"
                                 screen={screen}
                                 current_operator={@current_operator}
                                 deep_link_id={@deep_link_id} />
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

  attr :nav, :map, required: true
  attr :target, :string, required: true
  attr :active, :boolean, required: true

  defp dock_item(assigns) do
    ~H"""
    <a
      class={"dock-item#{if @active, do: " active", else: ""}"}
      data-accent={@nav.accent}
      href={"/visionplus/admin/#{@target}"}
      title={@nav.description}
      aria-current={@active && "page"}
    >
      <span class="dock-tile"><.icon name={@nav.icon} /></span>
      <span class="dock-label"><%= @nav.short_label %></span>
      <span class="dock-bar" aria-hidden="true"></span>
    </a>
    """
  end

  attr :item, :map, required: true
  attr :active, :boolean, required: true

  # Planned but not built: rendered inert rather than as a link to nowhere.
  defp nav_item(%{item: %{status: :planned}} = assigns) do
    ~H"""
    <span class="nav-item soon" aria-disabled="true" title={"#{@item.label} — not yet available"}>
      <.icon name={@item.icon} />
      <%= @item.label %>
      <span class="badge-soon">Soon</span>
    </span>
    """
  end

  defp nav_item(assigns) do
    ~H"""
    <a
      class={"nav-item#{if @active, do: " active", else: ""}"}
      href={"/visionplus/admin/#{@item.id}"}
      aria-current={@active && "page"}
    >
      <.icon name={@item.icon} />
      <%= @item.label %>
    </a>
    """
  end

  attr :nav, :map, required: true

  defp coming_soon_panel(assigns) do
    assigns = assign(assigns, :items, Nav.planned_for(assigns.nav.id))

    ~H"""
    <div data-accent={@nav.accent}>
      <.empty_state
        icon=""
        title={"#{@nav.label} — coming soon"}
        message={"#{@nav.description}. No screens are built in this module yet; these are planned, in priority order:"} />

      <ul class="coming-soon-list">
        <li :for={item <- @items}>
          <.icon name={item.icon} />
          <span><%= item.label %></span>
          <span class="coming-soon-group"><%= item.group %></span>
        </li>
      </ul>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp screen_label(id) do
    case Nav.registry()[id] do
      %{label: label} -> label
      nil -> id
    end
  end

  # Up to two initials for the header avatar. Falls back to "?" rather than
  # crashing on an operator whose display name is blank.
  defp initials(name) when is_binary(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
    |> String.upcase()
    |> case do
      "" -> "?"
      s -> s
    end
  end

  defp initials(_), do: "?"

  # AG Grid Enterprise license key (row grouping, Excel export, server-side
  # row model, sidebar tool panel). Unset in dev — the grid still works,
  # AG Grid just shows its own watermark, which is expected until a real
  # key is provisioned. Never hardcode one here.
  defp ag_grid_license_key, do: System.get_env("AG_GRID_LICENSE_KEY")
end
