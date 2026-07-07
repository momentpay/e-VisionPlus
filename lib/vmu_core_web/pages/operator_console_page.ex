defmodule VmuCoreWeb.Pages.OperatorConsolePage do
  @moduledoc """
  LiveDashboard custom page — VisionPlus Operator Console.

  Dual-mode interface:
    ⌨  Command mode  — terminal-style prompt with command history
    ☰  Menu mode     — guided forms, role-gated, confirmation prompts

  Operators choose their preferred style; the preference persists for the
  session (resets on page reload — ETS-backed persistence is a follow-up).

  Role hierarchy enforced by ASM.OperatorPortal:
    agent → supervisor → manager → sysadmin
  """

  use Phoenix.LiveDashboard.PageBuilder
  import Ecto.Query
  require Logger

  alias VmuCore.ASM.OperatorPortal
  alias VmuCore.Shared.ParameterEngine
  alias VmuCore.{Repo, CMS.Account}
  alias VmuCore.FAS.Authorization

  @roles ~w(agent supervisor manager sysadmin)
  @role_order [:agent, :supervisor, :manager, :sysadmin]

  # ---------------------------------------------------------------------------
  # PageBuilder callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def menu_link(_, _), do: {:ok, "Console"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, fresh_assigns(socket)}
  end

  # ---------------------------------------------------------------------------
  # Events — session
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("login", %{"name" => name, "id" => id, "role" => role}, socket)
      when role in @roles do
    op = %{name: name, id: id, role: String.to_existing_atom(role)}
    {:noreply,
     socket
     |> assign(operator: op)
     |> push_log({:system, "Signed in as #{name} [#{role}]. Type 'help' for available commands."})}
  end

  def handle_event("logout", _, socket) do
    {:noreply, fresh_assigns(socket)}
  end

  def handle_event("toggle_mode", %{"to" => mode}, socket) do
    {:noreply, assign(socket, mode: String.to_existing_atom(mode))}
  end

  # ---------------------------------------------------------------------------
  # Events — command mode
  # ---------------------------------------------------------------------------

  def handle_event("cmd_run", %{"cmd" => raw}, socket) do
    cmd = String.trim(raw)
    socket = socket |> assign(cmd_input: "") |> push_log({:input, cmd})
    {tag, output} = exec(cmd, socket.assigns.operator)
    {:noreply, push_log(socket, {tag, output})}
  end

  # ---------------------------------------------------------------------------
  # Events — menu mode tab navigation
  # ---------------------------------------------------------------------------

  def handle_event("menu_tab", %{"tab" => tab}, socket) do
    {:noreply,
     assign(socket,
       menu_tab:      String.to_existing_atom(tab),
       menu_result:   nil,
       lookup_result: nil
     )}
  end

  # ---------------------------------------------------------------------------
  # Events — menu tab: Accounts
  # ---------------------------------------------------------------------------

  def handle_event("lookup", %{"id" => id}, socket) do
    result = OperatorPortal.get_account_summary(String.trim(id), socket.assigns.operator)
    {:noreply, assign(socket, lookup_id: id, lookup_result: result)}
  end

  def handle_event("list_accounts", _, socket) do
    accounts =
      Repo.all(
        from a in Account,
          order_by: [desc: a.inserted_at],
          limit: 20,
          select: %{
            account_id:     a.account_id,
            account_status: a.account_status,
            credit_limit:   a.credit_limit,
            open_to_buy:    a.open_to_buy
          }
      )

    {:noreply, assign(socket, lookup_result: {:list, accounts})}
  end

  # ---------------------------------------------------------------------------
  # Events — menu tab: Fee Waivers
  # ---------------------------------------------------------------------------

  def handle_event("waiver", params, socket) do
    %{"acct" => acct, "amount" => amt, "reason" => reason} = params

    result =
      try do
        OperatorPortal.waive_fee(acct, Decimal.new(amt), reason, socket.assigns.operator)
      rescue
        e -> {:error, Exception.message(e)}
      end

    {:noreply, assign(socket, menu_result: result)}
  end

  # ---------------------------------------------------------------------------
  # Events — menu tab: Limits
  # ---------------------------------------------------------------------------

  def handle_event("limit_change", params, socket) do
    %{"acct" => acct, "limit" => lim, "reason" => reason} = params

    result =
      try do
        OperatorPortal.adjust_limit(acct, Decimal.new(lim), reason, socket.assigns.operator)
      rescue
        e -> {:error, Exception.message(e)}
      end

    {:noreply, assign(socket, menu_result: result)}
  end

  # ---------------------------------------------------------------------------
  # Events — menu tab: Account Actions
  # ---------------------------------------------------------------------------

  def handle_event("acct_action", params, socket) do
    %{"acct" => acct, "action" => action, "reason" => reason} = params

    result =
      case action do
        "block"   -> OperatorPortal.block_account(acct, reason, socket.assigns.operator)
        "unblock" -> OperatorPortal.unblock_account(acct, reason, socket.assigns.operator)
        "close"   -> OperatorPortal.close_account(acct, reason, socket.assigns.operator)
        _         -> {:error, :unknown_action}
      end

    {:noreply, assign(socket, menu_result: result)}
  end

  # ---------------------------------------------------------------------------
  # Events — menu tab: Parameters
  # ---------------------------------------------------------------------------

  def handle_event("param_refresh", _, socket) do
    result =
      if socket.assigns.operator.role == :sysadmin do
        ParameterEngine.refresh_all()
        {:ok, "Parameters refreshed — ETS cache reloaded from DB"}
      else
        {:error, :insufficient_role}
      end

    {:noreply, assign(socket, menu_result: result)}
  end

  # ---------------------------------------------------------------------------
  # Events — menu tab: Audit Log
  # ---------------------------------------------------------------------------

  def handle_event("audit_lookup", %{"acct" => acct}, socket) do
    log = load_audit_log(acct)
    {:noreply, assign(socket, audit_acct: acct, audit_log: log)}
  end

  # ---------------------------------------------------------------------------
  # Render — top-level dispatcher
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div style="font-family: 'JetBrains Mono', 'Fira Code', monospace; padding: 1rem;">
      <%= if is_nil(@operator) do %>
        <%= render_login(assigns) %>
      <% else %>
        <%= render_header(assigns) %>
        <div style="margin-top: 0.75rem;">
          <%= if @mode == :command do %>
            <%= render_command_mode(assigns) %>
          <% else %>
            <%= render_menu_mode(assigns) %>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Render — login
  # ---------------------------------------------------------------------------

  defp render_login(assigns) do
    ~H"""
    <div style="max-width: 440px; margin: 4rem auto; padding: 2rem;
                border: 1px solid #e5e7eb; border-radius: 10px; background: #f9fafb;">
      <div style="font-size: 1.4rem; font-weight: bold; margin-bottom: 0.25rem;">
        🔐 Operator Sign-In
      </div>
      <p style="color: #9ca3af; font-size: 0.78rem; margin: 0.2rem 0 1.5rem;">
        Local admin console — production requires FAPI 2.0 token authentication.
      </p>
      <form phx-submit="login" style="display: flex; flex-direction: column; gap: 0.8rem;">
        <input name="name" placeholder="Display name  (e.g. Ahmed Al Rashid)"
          required autocomplete="off" style={inp()} />
        <input name="id" placeholder="Operator ID  (e.g. OP001)"
          required autocomplete="off" style={inp()} />
        <select name="role" style={inp()}>
          <option value="agent">Agent — view only</option>
          <option value="supervisor">Supervisor — + fee waivers, block / unblock</option>
          <option value="manager">Manager — + limit change, closure</option>
          <option value="sysadmin">Sysadmin — full access, parameter updates</option>
        </select>
        <button type="submit"
          style="padding: 0.6rem; background: #1d4ed8; color: white; border: none;
                 border-radius: 5px; cursor: pointer; font-weight: bold; font-family: monospace;">
          Sign In →
        </button>
      </form>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Render — header bar (shown when logged in)
  # ---------------------------------------------------------------------------

  defp render_header(assigns) do
    ~H"""
    <div style="display: flex; align-items: center; gap: 0.75rem; padding: 0.6rem 1rem;
                background: #1e293b; border-radius: 7px; color: #f1f5f9;">
      <span style="font-weight: bold; letter-spacing: 0.04em; font-size: 0.95rem;">
        VisionPlus Console
      </span>

      <%!-- Mode toggle --%>
      <div style="display: flex; gap: 0; margin-left: 0.5rem;
                  border: 1px solid #334155; border-radius: 5px; overflow: hidden;">
        <button phx-click="toggle_mode" phx-value-to="command"
          style={"padding: 0.3rem 0.8rem; border: none; cursor: pointer; font-family: monospace; font-size: 0.8rem; " <>
                 if(@mode == :command,
                   do:   "background: #3b82f6; color: white; font-weight: bold;",
                   else: "background: #1e293b; color: #64748b;")}>
          ⌨ CMD
        </button>
        <button phx-click="toggle_mode" phx-value-to="menu"
          style={"padding: 0.3rem 0.8rem; border: none; cursor: pointer; font-family: monospace; font-size: 0.8rem; " <>
                 if(@mode == :menu,
                   do:   "background: #3b82f6; color: white; font-weight: bold;",
                   else: "background: #1e293b; color: #64748b;")}>
          ☰ MENU
        </button>
      </div>

      <span style="margin-left: auto;"></span>

      <%!-- Role badge --%>
      <span style={"padding: 0.2rem 0.55rem; border-radius: 4px; font-size: 0.75rem;
                   font-weight: bold; background: #{role_color(@operator.role)}; color: white;"}>
        {@operator.role |> to_string() |> String.upcase()}
      </span>

      <span style="color: #cbd5e1; font-size: 0.85rem;">👤 {@operator.name}</span>

      <button phx-click="logout"
        style="padding: 0.25rem 0.55rem; background: transparent; color: #94a3b8;
               border: 1px solid #334155; border-radius: 4px; cursor: pointer; font-size: 0.75rem;">
        Sign Out
      </button>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Render — command mode
  # ---------------------------------------------------------------------------

  defp render_command_mode(assigns) do
    ~H"""
    <div style="background: #0f172a; border-radius: 8px; padding: 1rem 1.25rem;
                min-height: 480px; display: flex; flex-direction: column;">

      <%!-- Output log (scrollable) --%>
      <div style="flex: 1; overflow-y: auto; max-height: 400px;
                  margin-bottom: 0.75rem; display: flex; flex-direction: column; gap: 0.2rem;">
        <%= for {tag, text} <- @cmd_log do %>
          <div style={"font-size: 0.83rem; line-height: 1.5; " <> log_style(tag)}>
            <%= case tag do %>
              <% :input -> %>
                <span style="color: #475569; user-select: none;">
                  vmu[{to_string(@operator.role)}]&gt;
                </span>
                <span style="color: #e2e8f0;"> {text}</span>
              <% :ok -> %>
                <span style="color: #4ade80;">✅ </span>
                <span style="color: #86efac; white-space: pre-wrap;">{text}</span>
              <% :error -> %>
                <span style="color: #f87171;">❌ </span>
                <span style="color: #fca5a5;">{text}</span>
              <% :info -> %>
                <span style="color: #93c5fd; white-space: pre-wrap;">{text}</span>
              <% :system -> %>
                <span style="color: #334155;"># </span>
                <span style="color: #64748b;">{text}</span>
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- Input prompt --%>
      <form phx-submit="cmd_run"
        style="display: flex; align-items: center; gap: 0.5rem;
               border-top: 1px solid #1e293b; padding-top: 0.75rem;">
        <span style="color: #3b82f6; white-space: nowrap; font-size: 0.83rem; user-select: none;">
          vmu[{to_string(@operator.role)}]&gt;
        </span>
        <input name="cmd" value={@cmd_input} autofocus autocomplete="off" spellcheck="false"
          style="flex: 1; background: transparent; border: none; outline: none;
                 color: #f1f5f9; font-family: inherit; font-size: 0.83rem; caret-color: #3b82f6;" />
      </form>
    </div>

    <%!-- Quick-reference chips below terminal --%>
    <div style="margin-top: 0.5rem; display: flex; gap: 0.35rem; flex-wrap: wrap; align-items: center;">
      <span style="color: #6b7280; font-size: 0.73rem;">Quick:</span>
      <%= for cmd <- quick_cmds(@operator.role) do %>
        <code style="background: #f1f5f9; border: 1px solid #e2e8f0; padding: 0.1rem 0.4rem;
                     border-radius: 3px; font-size: 0.72rem; color: #475569;">{cmd}</code>
      <% end %>
      <span style="color: #9ca3af; font-size: 0.73rem; margin-left: 0.5rem;">
        · type <code style="color: #6b7280;">help</code> for full list
      </span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Render — menu mode (container + sidebar)
  # ---------------------------------------------------------------------------

  defp render_menu_mode(assigns) do
    ~H"""
    <div style="display: flex; gap: 1rem; align-items: flex-start;">

      <%!-- Sidebar tab nav --%>
      <nav style="display: flex; flex-direction: column; gap: 0.3rem; min-width: 170px;">
        <%= for {tab_id, icon, label, min_role} <- menu_tabs() do %>
          <% active  = @menu_tab == tab_id %>
          <% allowed = role_gte?(@operator.role, min_role) %>
          <button phx-click={if allowed, do: "menu_tab"} phx-value-tab={tab_id}
            style={"text-align: left; padding: 0.5rem 0.75rem; border: none;
                   border-radius: 5px; font-family: monospace; font-size: 0.82rem;
                   cursor: #{if allowed, do: "pointer", else: "not-allowed"};
                   background: #{cond do
                     active   -> "#1d4ed8"
                     allowed  -> "#f3f4f6"
                     true     -> "#fafafa"
                   end};
                   color: #{cond do
                     active   -> "white"
                     allowed  -> "#374151"
                     true     -> "#d1d5db"
                   end};"}>
            {icon} {label}
            <%= if not allowed do %>
              <span style="font-size: 0.65rem; opacity: 0.6;"> [{to_string(min_role)}+]</span>
            <% end %>
          </button>
        <% end %>
      </nav>

      <%!-- Content panel --%>
      <div style="flex: 1; background: #f9fafb; border: 1px solid #e5e7eb;
                  border-radius: 8px; padding: 1.5rem; min-height: 500px;">
        <%= case @menu_tab do %>
          <% :accounts   -> %><%= render_tab_accounts(assigns) %>
          <% :waivers    -> %><%= render_tab_waivers(assigns) %>
          <% :limits     -> %><%= render_tab_limits(assigns) %>
          <% :actions    -> %><%= render_tab_actions(assigns) %>
          <% :parameters -> %><%= render_tab_parameters(assigns) %>
          <% :audit      -> %><%= render_tab_audit(assigns) %>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Menu tab: Accounts
  # ---------------------------------------------------------------------------

  defp render_tab_accounts(assigns) do
    ~H"""
    <h3 style={tab_title()}>🔍 Account Lookup</h3>
    <div style="display: flex; gap: 0.5rem; margin-bottom: 1rem;">
      <form phx-submit="lookup" style="display: flex; gap: 0.5rem; flex: 1;">
        <input name="id" value={@lookup_id} placeholder="Account UUID"
          style={inp()} autocomplete="off" />
        <button type="submit" style={btn()}>Look up</button>
      </form>
      <button phx-click="list_accounts" style={btn_secondary()}>List recent (20)</button>
    </div>

    <%= case @lookup_result do %>
      <% nil -> %><p style="color: #9ca3af; font-size: 0.85rem;">Enter an account UUID above.</p>
      <% {:ok, s} -> %>
        <div style="background: white; border: 1px solid #e5e7eb; border-radius: 6px; padding: 1rem; font-size: 0.85rem;">
          <table style="border-collapse: collapse; width: 100%;">
            <tr>
              <td style={kl()}>Account ID</td>
              <td><code style="font-size: 0.8rem;">{s.account_id}</code></td>
            </tr>
            <tr>
              <td style={kl()}>Status</td>
              <td>
                <span style={"padding: 0.15rem 0.5rem; border-radius: 3px; font-weight: bold; font-size: 0.8rem; " <>
                             status_badge_style(s.account_status)}>
                  {s.account_status}
                </span>
              </td>
            </tr>
            <tr><td style={kl()}>Credit Limit</td><td>{s.credit_limit} AED</td></tr>
            <tr><td style={kl()}>Open-to-Buy</td><td>{s.open_to_buy} AED</td></tr>
            <tr><td style={kl()}>DPD Bucket</td>  <td>{s.delinquency_bucket} days</td></tr>
            <tr><td style={kl()}>Cycle Day</td>   <td>{s.cycle_code}</td></tr>
          </table>
          <p style="margin: 0.75rem 0 0; color: #9ca3af; font-size: 0.75rem;">
            PAN token: <code style="font-size: 0.72rem;">{s.pan_token}</code>
          </p>
        </div>
      <% {:list, accounts} -> %>
        <table style="width: 100%; border-collapse: collapse; font-size: 0.82rem;">
          <thead>
            <tr style="background: #f3f4f6;">
              <th style={th()}>Account ID</th>
              <th style={th()}>Status</th>
              <th style={th()}>Limit (AED)</th>
              <th style={th()}>OTB (AED)</th>
            </tr>
          </thead>
          <tbody>
            <%= for a <- accounts do %>
              <tr style="border-top: 1px solid #e5e7eb;">
                <td style={td()}><code style="font-size: 0.75rem;">{a.account_id}</code></td>
                <td style={td()}>
                  <span style={"font-size: 0.75rem; " <> status_badge_style(a.account_status)}>
                    {a.account_status}
                  </span>
                </td>
                <td style={td()}>{a.credit_limit}</td>
                <td style={td()}>{a.open_to_buy}</td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% {:error, reason} -> %>
        <div style={err_box()}>{inspect(reason)}</div>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # Menu tab: Fee Waivers
  # ---------------------------------------------------------------------------

  defp render_tab_waivers(assigns) do
    ~H"""
    <h3 style={tab_title()}>💰 Fee Waiver <span style="color:#9ca3af; font-weight: normal; font-size: 0.75rem;">(Supervisor+)</span></h3>
    <p style="color: #6b7280; font-size: 0.82rem; margin-top: 0;">
      Posts a GL reversal and credits the account's open-to-buy.
    </p>
    <form phx-submit="waiver" style="display: flex; flex-direction: column; gap: 0.7rem; max-width: 460px;">
      <input name="acct"   placeholder="Account UUID" required style={inp()} autocomplete="off" />
      <input name="amount" placeholder="Amount (AED, e.g. 50.00)" required style={inp()} />
      <input name="reason" placeholder="Reason  (e.g. Late fee — first offence waiver)" required style={inp()} />
      <button type="submit" style={btn()}>Post Fee Waiver</button>
    </form>
    <%= render_menu_result(assigns) %>
    """
  end

  # ---------------------------------------------------------------------------
  # Menu tab: Credit Limits
  # ---------------------------------------------------------------------------

  defp render_tab_limits(assigns) do
    ~H"""
    <h3 style={tab_title()}>📊 Credit Limit Adjustment <span style="color:#9ca3af; font-weight: normal; font-size: 0.75rem;">(Manager+)</span></h3>
    <p style="color: #6b7280; font-size: 0.82rem; margin-top: 0;">
      Updates the credit limit and refreshes the AccountStateCoordinator in memory.
    </p>
    <form phx-submit="limit_change" style="display: flex; flex-direction: column; gap: 0.7rem; max-width: 460px;">
      <input name="acct"   placeholder="Account UUID" required style={inp()} autocomplete="off" />
      <input name="limit"  placeholder="New credit limit (AED, e.g. 10000.00)" required style={inp()} />
      <input name="reason" placeholder="Reason  (e.g. Annual review — upgraded tier)" required style={inp()} />
      <button type="submit" style={btn()}>Set Credit Limit</button>
    </form>
    <%= render_menu_result(assigns) %>
    """
  end

  # ---------------------------------------------------------------------------
  # Menu tab: Account Actions (block / unblock / close)
  # ---------------------------------------------------------------------------

  defp render_tab_actions(assigns) do
    ~H"""
    <h3 style={tab_title()}>⚠️ Account Actions</h3>

    <form phx-submit="acct_action" style="display: flex; flex-direction: column; gap: 0.7rem; max-width: 460px;">
      <input name="acct" placeholder="Account UUID" required style={inp()} autocomplete="off" />

      <div style="display: flex; flex-direction: column; gap: 0.4rem;">
        <label style="font-size: 0.8rem; color: #6b7280;">Action</label>
        <div style="display: flex; flex-direction: column; gap: 0.3rem;">
          <% allowed_supervisor = role_gte?(@operator.role, :supervisor) %>
          <% allowed_manager    = role_gte?(@operator.role, :manager) %>
          <label style={"display: flex; align-items: center; gap: 0.5rem; font-size: 0.85rem; " <>
                        unless(allowed_supervisor, do: "color: #9ca3af;", else: "")}>
            <input type="radio" name="action" value="block"
              disabled={not allowed_supervisor} checked />
            Block account — halt future authorizations
            <span style="color: #9ca3af; font-size: 0.72rem;">[supervisor+]</span>
          </label>
          <label style={"display: flex; align-items: center; gap: 0.5rem; font-size: 0.85rem; " <>
                        unless(allowed_supervisor, do: "color: #9ca3af;", else: "")}>
            <input type="radio" name="action" value="unblock"
              disabled={not allowed_supervisor} />
            Unblock / Reactivate account
            <span style="color: #9ca3af; font-size: 0.72rem;">[supervisor+]</span>
          </label>
          <label style={"display: flex; align-items: center; gap: 0.5rem; font-size: 0.85rem; " <>
                        unless(allowed_manager, do: "color: #9ca3af;", else: "")}>
            <input type="radio" name="action" value="close"
              disabled={not allowed_manager} />
            Close account — permanent, zeroes OTB
            <span style="color: #dc2626; font-size: 0.72rem;">[manager+ · irreversible]</span>
          </label>
        </div>
      </div>

      <input name="reason" placeholder="Reason (required)" required style={inp()} />

      <button type="submit"
        style="padding: 0.5rem 1rem; background: #dc2626; color: white; border: none;
               border-radius: 5px; cursor: pointer; font-family: monospace; font-weight: bold;">
        Execute Action
      </button>
    </form>
    <%= render_menu_result(assigns) %>
    """
  end

  # ---------------------------------------------------------------------------
  # Menu tab: Parameter Engine
  # ---------------------------------------------------------------------------

  defp render_tab_parameters(assigns) do
    ~H"""
    <h3 style={tab_title()}>⚙️ Parameter Engine <span style="color:#9ca3af; font-weight: normal; font-size: 0.75rem;">(Sysadmin)</span></h3>
    <p style="color: #6b7280; font-size: 0.82rem; margin-top: 0;">
      Reload SYS / BANK / LOGO / BLOCK parameters from PostgreSQL into the ETS cache
      without restarting the application. All in-flight authorization decisions will
      use the new values immediately after the refresh.
    </p>
    <button phx-click="param_refresh"
      style={"padding: 0.5rem 1.2rem; border: none; border-radius: 5px; cursor: pointer;
             font-family: monospace; font-weight: bold; " <>
             if(@operator.role == :sysadmin,
               do:   "background: #1d4ed8; color: white;",
               else: "background: #e5e7eb; color: #9ca3af; cursor: not-allowed;")}>
      ↺ Refresh All Parameters
    </button>
    <%= render_menu_result(assigns) %>
    <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 1.5rem 0;" />
    <p style="color: #9ca3af; font-size: 0.78rem;">
      Individual parameter updates (<code>param set</code>) require
      <code>ParameterEngine.put/6</code> — not yet implemented.
      Use the Parameters LiveDashboard page to inspect current ETS values.
    </p>
    """
  end

  # ---------------------------------------------------------------------------
  # Menu tab: Audit Log
  # ---------------------------------------------------------------------------

  defp render_tab_audit(assigns) do
    ~H"""
    <h3 style={tab_title()}>📋 Operator Audit Log</h3>
    <form phx-submit="audit_lookup" style="display: flex; gap: 0.5rem; margin-bottom: 1rem;">
      <input name="acct" value={@audit_acct}
        placeholder="Account UUID  (leave blank for 30 most-recent entries)"
        style={inp()} autocomplete="off" />
      <button type="submit" style={btn()}>Load</button>
    </form>
    <%= if @audit_log == [] do %>
      <p style="color: #9ca3af; font-size: 0.85rem;">No records found.</p>
    <% else %>
      <table style="width: 100%; border-collapse: collapse; font-size: 0.8rem;">
        <thead>
          <tr style="background: #f3f4f6;">
            <th style={th()}>Time (UTC)</th>
            <th style={th()}>Operator</th>
            <th style={th()}>Role</th>
            <th style={th()}>Action</th>
            <th style={th()}>Subject</th>
          </tr>
        </thead>
        <tbody>
          <%= for row <- @audit_log do %>
            <tr style="border-top: 1px solid #e5e7eb;">
              <td style={td()}>{row.performed_at}</td>
              <td style={td()}>{row.operator_id}</td>
              <td style={td()}>{row.operator_role}</td>
              <td style={td()}><code style="background:#f3f4f6; padding: 0.1rem 0.3rem; border-radius:2px;">{row.action}</code></td>
              <td style={td()}><code style="font-size: 0.73rem;">{row.subject}</code></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # Shared menu result banner
  # ---------------------------------------------------------------------------

  defp render_menu_result(assigns) do
    ~H"""
    <%= if @menu_result do %>
      <div style={"margin-top: 1rem; padding: 0.65rem 0.9rem; border-radius: 5px; font-size: 0.85rem; " <>
                  result_style(@menu_result)}>
        <%= case @menu_result do %>
          <% :ok          -> %>✅ Done
          <% {:ok, msg}   -> %>✅ {msg}
          <% {:error, :insufficient_role} -> %>❌ Insufficient role — this action requires higher privileges
          <% {:error, reason} -> %>❌ {inspect(reason)}
        <% end %>
      </div>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # Command executor
  # ---------------------------------------------------------------------------

  defp exec("", _op), do: {:info, ""}

  defp exec("help", op) do
    lines = [
      "Commands available to #{op.role}:",
      "",
      "  help                              — this message",
      "  view account <uuid>               — account summary  [agent+]",
      "  list accounts                     — 20 most-recent accounts  [agent+]",
      "  auth <pan> <amount>               — run live auth test  [agent+]",
      "  audit <uuid>                      — operator actions on account  [agent+]",
      "  audit                             — 30 most-recent entries  [agent+]",
    ] ++
    (if role_gte?(op.role, :supervisor), do: [
      "  waive <uuid> <amount> <reason>    — fee waiver  [supervisor+]",
      "  block <uuid>                      — block account  [supervisor+]",
      "  unblock <uuid>                    — reactivate account  [supervisor+]",
    ], else: []) ++
    (if role_gte?(op.role, :manager), do: [
      "  limit <uuid> <amount> <reason>    — set credit limit  [manager+]",
      "  close <uuid> <reason>             — close account  [manager+]",
    ], else: []) ++
    (if op.role == :sysadmin, do: [
      "  param refresh                     — reload ETS cache from DB  [sysadmin]",
    ], else: [])

    {:info, Enum.join(lines, "\n")}
  end

  defp exec("view account " <> id, op) do
    case OperatorPortal.get_account_summary(String.trim(id), op) do
      {:ok, s} ->
        text = [
          "Account:      #{s.account_id}",
          "Status:       #{s.account_status}",
          "Credit Limit: #{s.credit_limit} AED",
          "Open-to-Buy:  #{s.open_to_buy} AED",
          "DPD Bucket:   #{s.delinquency_bucket}",
          "Cycle Day:    #{s.cycle_code}",
        ] |> Enum.join("\n")
        {:ok, text}
      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp exec("list accounts", _op) do
    accounts =
      Repo.all(
        from a in Account,
          order_by: [desc: a.inserted_at],
          limit: 20,
          select: %{account_id: a.account_id, account_status: a.account_status,
                    credit_limit: a.credit_limit, open_to_buy: a.open_to_buy}
      )

    text =
      accounts
      |> Enum.map_join("\n", fn a ->
        "#{a.account_id}  #{String.pad_trailing(a.account_status, 10)}  " <>
        "limit=#{a.credit_limit}  otb=#{a.open_to_buy}"
      end)

    {:ok, "#{length(accounts)} accounts:\n#{text}"}
  end

  defp exec("auth " <> rest, _op) do
    case String.split(String.trim(rest), ~r/\s+/, parts: 2) do
      [pan, amt] ->
        try do
          case Authorization.process(%{pan: pan, amount: Decimal.new(amt), channel: :pos, mcc: "5411"}) do
            {:ok, rc, code} -> {:ok,   "APPROVED  RC=#{rc}  Approval=#{code}"}
            {:error, rc}    -> {:error, "DECLINED  RC=#{rc}"}
          end
        rescue
          e -> {:error, Exception.message(e)}
        end
      _ ->
        {:error, "Usage: auth <pan> <amount>"}
    end
  end

  defp exec("audit " <> id, _op) do
    rows = load_audit_log(String.trim(id))
    format_audit_rows(rows, String.trim(id))
  end

  defp exec("audit", _op) do
    rows = load_audit_log("")
    format_audit_rows(rows, "recent")
  end

  defp exec("waive " <> rest, op) do
    case String.split(String.trim(rest), ~r/\s+/, parts: 3) do
      [acct, amt | reason_parts] ->
        reason = Enum.join(reason_parts, " ") |> String.trim("\"")
        try do
          case OperatorPortal.waive_fee(acct, Decimal.new(amt), reason, op) do
            :ok             -> {:ok,   "Fee waiver posted: #{amt} AED on #{acct}"}
            {:error, r}     -> {:error, inspect(r)}
          end
        rescue
          e -> {:error, "Invalid amount — #{Exception.message(e)}"}
        end
      _ ->
        {:error, "Usage: waive <uuid> <amount> <reason>"}
    end
  end

  defp exec("block " <> id, op) do
    case OperatorPortal.block_account(String.trim(id), "Blocked via console", op) do
      :ok         -> {:ok,   "Account #{String.trim(id)} blocked"}
      {:error, r} -> {:error, inspect(r)}
    end
  end

  defp exec("unblock " <> id, op) do
    case OperatorPortal.unblock_account(String.trim(id), "Unblocked via console", op) do
      :ok         -> {:ok,   "Account #{String.trim(id)} reactivated"}
      {:error, r} -> {:error, inspect(r)}
    end
  end

  defp exec("limit " <> rest, op) do
    case String.split(String.trim(rest), ~r/\s+/, parts: 3) do
      [acct, lim | reason_parts] ->
        reason = Enum.join(reason_parts, " ")
        try do
          case OperatorPortal.adjust_limit(acct, Decimal.new(lim), reason, op) do
            :ok         -> {:ok,   "Credit limit set to #{lim} AED on #{acct}"}
            {:error, r} -> {:error, inspect(r)}
          end
        rescue
          e -> {:error, "Invalid amount — #{Exception.message(e)}"}
        end
      _ ->
        {:error, "Usage: limit <uuid> <new_amount> <reason>"}
    end
  end

  defp exec("close " <> rest, op) do
    case String.split(String.trim(rest), ~r/\s+/, parts: 2) do
      [acct, reason] ->
        case OperatorPortal.close_account(acct, reason, op) do
          :ok         -> {:ok,   "Account #{acct} closed"}
          {:error, r} -> {:error, inspect(r)}
        end
      _ ->
        {:error, "Usage: close <uuid> <reason>"}
    end
  end

  defp exec("param refresh", op) do
    if op.role == :sysadmin do
      ParameterEngine.refresh_all()
      {:ok, "Parameters refreshed — ETS cache reloaded from DB"}
    else
      {:error, "Insufficient role — sysadmin required"}
    end
  end

  defp exec(cmd, _op) do
    {:error, "Unknown command: '#{cmd}'  — type 'help' to see available commands"}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fresh_assigns(socket) do
    assign(socket,
      operator:      nil,
      mode:          :command,
      cmd_input:     "",
      cmd_log:       [{:system, "VisionPlus Operator Console ready. Type 'help' for available commands."}],
      menu_tab:      :accounts,
      menu_result:   nil,
      lookup_id:     "",
      lookup_result: nil,
      audit_acct:    "",
      audit_log:     []
    )
  end

  defp push_log(socket, entry) do
    log = socket.assigns.cmd_log ++ [entry]
    log = if length(log) > 200, do: Enum.drop(log, length(log) - 200), else: log
    assign(socket, cmd_log: log)
  end

  defp load_audit_log(account_id) do
    base = from a in "cms_operator_audit",
             order_by: [desc: a.performed_at],
             limit: 30,
             select: %{
               performed_at: a.performed_at,
               operator_id:  a.operator_id,
               operator_role: a.operator_role,
               action:       a.action,
               subject:      a.subject
             }

    q =
      if account_id == "" do
        base
      else
        from a in base, where: a.subject == ^account_id
      end

    Repo.all(q)
  end

  defp format_audit_rows([], subject), do: {:info, "No audit records found for #{subject}"}
  defp format_audit_rows(rows, _subject) do
    text =
      rows
      |> Enum.map_join("\n", fn r ->
        "#{r.performed_at}  #{String.pad_trailing(r.operator_role, 12)} #{r.action}  #{r.subject}"
      end)

    {:ok, "#{length(rows)} audit entries:\n#{text}"}
  end

  defp menu_tabs do
    [
      {:accounts,   "🔍", "Accounts",    :agent},
      {:waivers,    "💰", "Fee Waivers", :supervisor},
      {:limits,     "📊", "Limits",      :manager},
      {:actions,    "⚠️", "Actions",      :supervisor},
      {:parameters, "⚙️", "Parameters",  :sysadmin},
      {:audit,      "📋", "Audit Log",   :agent}
    ]
  end

  defp quick_cmds(:agent),      do: ["help", "view account <uuid>", "list accounts", "auth <pan> <amount>"]
  defp quick_cmds(:supervisor), do: ["waive <uuid> <amount> <reason>", "block <uuid>", "unblock <uuid>"]
  defp quick_cmds(:manager),    do: ["limit <uuid> <amount> <reason>", "close <uuid> <reason>"]
  defp quick_cmds(:sysadmin),   do: ["param refresh"]

  defp role_gte?(op_role, min_role) do
    Enum.find_index(@role_order, &(&1 == op_role)) >=
    Enum.find_index(@role_order, &(&1 == min_role))
  end

  defp role_color(:agent),      do: "#6b7280"
  defp role_color(:supervisor), do: "#2563eb"
  defp role_color(:manager),    do: "#7c3aed"
  defp role_color(:sysadmin),   do: "#dc2626"
  defp role_color(_),           do: "#374151"

  defp log_style(:input),  do: "color: #e2e8f0;"
  defp log_style(:ok),     do: "color: #86efac;"
  defp log_style(:error),  do: "color: #fca5a5;"
  defp log_style(:info),   do: "color: #93c5fd;"
  defp log_style(:system), do: "color: #475569;"

  defp result_style(:ok),                        do: "background: #dcfce7; color: #166534;"
  defp result_style({:ok, _}),                   do: "background: #dcfce7; color: #166534;"
  defp result_style({:error, :insufficient_role}), do: "background: #fee2e2; color: #991b1b;"
  defp result_style({:error, _}),                do: "background: #fee2e2; color: #991b1b;"
  defp result_style(_),                          do: "background: #f3f4f6; color: #374151;"

  defp status_badge_style("ACTIVE"),     do: "background: #dcfce7; color: #166534; padding: 0.1rem 0.4rem; border-radius: 3px;"
  defp status_badge_style("BLOCKED"),    do: "background: #fee2e2; color: #991b1b; padding: 0.1rem 0.4rem; border-radius: 3px;"
  defp status_badge_style("DELINQUENT"), do: "background: #fef3c7; color: #92400e; padding: 0.1rem 0.4rem; border-radius: 3px;"
  defp status_badge_style("CLOSED"),     do: "background: #f3f4f6; color: #6b7280; padding: 0.1rem 0.4rem; border-radius: 3px;"
  defp status_badge_style(_),            do: "background: #e0e7ff; color: #3730a3; padding: 0.1rem 0.4rem; border-radius: 3px;"

  # Style helpers
  defp tab_title, do: "margin: 0 0 0.75rem; font-size: 1rem; font-weight: bold;"
  defp err_box,   do: "padding: 0.6rem; background: #fee2e2; border-radius: 5px; color: #991b1b; font-size: 0.85rem;"
  defp inp,       do: "padding: 0.45rem 0.6rem; border: 1px solid #d1d5db; border-radius: 4px; font-family: monospace; font-size: 0.82rem; width: 100%; box-sizing: border-box;"
  defp btn,       do: "padding: 0.45rem 1rem; background: #1d4ed8; color: white; border: none; border-radius: 4px; cursor: pointer; font-family: monospace; font-weight: bold; white-space: nowrap;"
  defp btn_secondary, do: "padding: 0.45rem 0.8rem; background: #f3f4f6; color: #374151; border: 1px solid #d1d5db; border-radius: 4px; cursor: pointer; font-family: monospace; white-space: nowrap;"
  defp th,  do: "padding: 0.4rem 0.6rem; text-align: left; font-weight: 600; font-size: 0.8rem;"
  defp td,  do: "padding: 0.35rem 0.6rem;"
  defp kl,  do: "padding: 0.25rem 1.25rem 0.25rem 0; color: #6b7280; white-space: nowrap; vertical-align: top;"
end
