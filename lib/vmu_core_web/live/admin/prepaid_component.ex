defmodule VmuCoreWeb.Live.Admin.PrepaidComponent do
  @moduledoc """
  Admin LiveComponent: Prepaid account list/detail (Way4 parity plan
  Phase 1 item 5, P5, 2026-07-27) — the first ops UI for closed-loop
  stored-value accounts, distinct from Debit (real network-issued card,
  `DebitComponent`) and Credit (`AccountComponent`).

  - Account list with search, and a "+ New Account" form (opens a new
    CIF customer + `CMS.PrepaidAccount` together — same inline-customer
    convention `DebitComponent`/`HcsComponent` already use)
  - Account detail: derived balance (`PrepaidLedger.balance/1`, never a
    stored field), full ledger history (LOAD/SPEND/EXPIRE/REFUND rows —
    not just loads, so an expiry sweep's effect is visible here too),
    card roster, load/issue actions. Card activate/block/unblock reuse
    `CTA.CardLifecycle` directly (same nil-guarded denormal sync D5
    already proved works for Debit).

  Deliberately NOT in this pass: card replace/renew, the hot-card
  blocklist — same flagged gaps as `DebitComponent`.

  Visibility requires `prepaid:view`; create/load/issue require
  `prepaid:edit`.
  """

  use Phoenix.LiveComponent
  import Ecto.Query
  import VmuCoreWeb.AdminUI

  alias VmuCore.{Repo, CMS.PrepaidAccount, CMS.PrepaidAccountOpening, CMS.PrepaidLedgerEntry,
                 CMS.PrepaidLedger, CTA.CardLifecycle, CTA.Cards}
  alias VmuCore.Shared.Customer
  alias VmuCore.ASM.Authz
  alias Decimal, as: D

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       mode: :list,
       search: "",
       accounts: [],
       notice: nil,
       notice_kind: :info,
       active_action: :none,
       account: nil,
       balance: nil,
       ledger_entries: [],
       cards: [],
       can_edit: false
     )
     |> load_accounts()}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    operator = socket.assigns[:current_operator]

    {:ok, assign(socket, can_edit: operator && Authz.can?(operator, "prepaid", "edit"))}
  end

  # ---------------------------------------------------------------------------
  # List events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(search: q) |> load_accounts()}
  end

  def handle_event("view_account", %{"id" => id}, socket) do
    {:noreply, load_detail(socket, id)}
  end

  def handle_event("back_to_list", _, socket) do
    {:noreply, socket |> assign(mode: :list, active_action: :none, notice: nil) |> load_accounts()}
  end

  def handle_event("open_action", %{"a" => action}, socket) do
    {:noreply, assign(socket, active_action: String.to_atom(action), notice: nil)}
  end

  def handle_event("action_close", _, socket) do
    {:noreply, assign(socket, active_action: :none)}
  end

  # ---------------------------------------------------------------------------
  # Create account
  # ---------------------------------------------------------------------------

  def handle_event("create_account_save", %{"account" => params}, socket) do
    if socket.assigns.can_edit do
      cond do
        params["first_name"] in [nil, ""] or params["last_name"] in [nil, ""] ->
          {:noreply, assign(socket, notice: "Customer name is required.", notice_kind: :error)}

        true ->
          customer_result =
            %Customer{}
            |> Customer.changeset(%{
              sys_id: params["sys_id"], bank_id: params["bank_id"],
              first_name: params["first_name"], last_name: params["last_name"]
            })
            |> Repo.insert()

          with {:ok, customer} <- customer_result,
               {:ok, account} <-
                 PrepaidAccountOpening.open(%{
                   customer_id: customer.customer_id, sys_id: params["sys_id"],
                   bank_id: params["bank_id"], logo_id: params["logo_id"],
                   block_id: params["block_id"]
                 }) do
            {:noreply, socket
                        |> assign(mode: :list, notice: "Prepaid account opened for #{params["first_name"]} #{params["last_name"]}.", notice_kind: :success)
                        |> load_accounts()
                        |> then(&load_detail(&1, account.prepaid_account_id))}
          else
            {:error, changeset} ->
              {:noreply, assign(socket, notice: "Create failed — #{inspect(changeset.errors)}", notice_kind: :error)}
          end
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot create prepaid accounts.", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Load account
  # ---------------------------------------------------------------------------

  def handle_event("load_account_save", %{"load" => params}, socket) do
    if socket.assigns.can_edit do
      amount = parse_decimal(params["amount"])
      channel = params["channel"]

      cond do
        is_nil(amount) or D.compare(amount, D.new(0)) != :gt ->
          {:noreply, assign(socket, notice: "Amount must be a positive number.", notice_kind: :error)}

        channel in ["EXTERNAL_BANK_TRANSFER", "CASH_DEPOSIT"] and blank?(params["external_reference"]) ->
          {:noreply, assign(socket, notice: "A reference is required for this channel.", notice_kind: :error)}

        true ->
          operator = socket.assigns.current_operator

          case PrepaidLedger.load(%{
                 prepaid_account_id: socket.assigns.account.prepaid_account_id, amount: amount,
                 channel: channel, posted_by: operator.username,
                 external_reference: blank_to_nil(params["external_reference"]),
                 expiry_date: parse_date(params["expiry_date"])
               }) do
            {:ok, _result} ->
              {:noreply, socket
                          |> load_detail(socket.assigns.account.prepaid_account_id)
                          |> assign(active_action: :none, notice: "Account loaded: #{money(amount)}.", notice_kind: :success)}

            {:error, reason} ->
              {:noreply, assign(socket, notice: "Load failed — #{inspect(reason)}", notice_kind: :error)}
          end
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot load prepaid accounts.", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Card issuance / lifecycle
  # ---------------------------------------------------------------------------

  def handle_event("issue_card_save", %{"card" => params}, socket) do
    if socket.assigns.can_edit do
      card_type = params["card_type"] || "PRIMARY"

      case CardLifecycle.issue_new_prepaid(socket.assigns.account, card_type: card_type) do
        {:ok, _card} ->
          {:noreply, socket
                      |> load_detail(socket.assigns.account.prepaid_account_id)
                      |> assign(active_action: :none, notice: "#{card_type} card issued (INACTIVE).", notice_kind: :success)}

        {:error, reason} ->
          {:noreply, assign(socket, notice: "Card issuance failed — #{inspect(reason)}", notice_kind: :error)}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot issue cards.", notice_kind: :error)}
    end
  end

  def handle_event("card_activate", %{"id" => card_id}, socket) do
    if socket.assigns.can_edit do
      case CardLifecycle.activate(card_id, operator: socket.assigns.current_operator) do
        {:ok, _card} ->
          {:noreply, socket |> load_detail(socket.assigns.account.prepaid_account_id) |> assign(notice: "Card activated.", notice_kind: :success)}

        {:error, reason} ->
          {:noreply, assign(socket, notice: "Activation failed — #{inspect(reason)}", notice_kind: :error)}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot activate cards.", notice_kind: :error)}
    end
  end

  def handle_event("card_block", %{"id" => card_id}, socket) do
    if socket.assigns.can_edit do
      case CardLifecycle.block(card_id, "ADMIN", operator: socket.assigns.current_operator) do
        {:ok, _card} ->
          {:noreply, socket |> load_detail(socket.assigns.account.prepaid_account_id) |> assign(notice: "Card blocked.", notice_kind: :success)}

        {:error, reason} ->
          {:noreply, assign(socket, notice: "Block failed — #{inspect(reason)}", notice_kind: :error)}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot block cards.", notice_kind: :error)}
    end
  end

  def handle_event("card_unblock", %{"id" => card_id}, socket) do
    if socket.assigns.can_edit do
      case CardLifecycle.unblock(card_id, operator: socket.assigns.current_operator) do
        {:ok, _card} ->
          {:noreply, socket |> load_detail(socket.assigns.account.prepaid_account_id) |> assign(notice: "Card unblocked.", notice_kind: :success)}

        {:error, reason} ->
          {:noreply, assign(socket, notice: "Unblock failed — #{inspect(reason)}", notice_kind: :error)}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot unblock cards.", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — data loading
  # ---------------------------------------------------------------------------

  defp load_accounts(socket) do
    search = String.trim(socket.assigns[:search] || "")

    query =
      if search == "" do
        from(p in PrepaidAccount, order_by: [desc: p.inserted_at])
      else
        from(p in PrepaidAccount, join: c in Customer, on: c.customer_id == p.customer_id,
          where: ilike(c.first_name, ^"%#{search}%") or ilike(c.last_name, ^"%#{search}%"),
          order_by: [desc: p.inserted_at])
      end

    accounts =
      Repo.all(query)
      |> Enum.map(fn account ->
        customer = Repo.get(Customer, account.customer_id)
        account
        |> Map.put(:customer_name, customer && "#{customer.first_name} #{customer.last_name}")
        |> Map.put(:balance, PrepaidLedger.balance(account.prepaid_account_id))
      end)

    assign(socket, accounts: accounts, mode: :list)
  end

  defp load_detail(socket, prepaid_account_id) do
    account = Repo.get!(PrepaidAccount, prepaid_account_id)
    customer = Repo.get(Customer, account.customer_id)
    account = Map.put(account, :customer_name, customer && "#{customer.first_name} #{customer.last_name}")

    assign(socket,
      mode: :detail,
      account: account,
      active_action: :none,
      notice: nil,
      balance: PrepaidLedger.balance(prepaid_account_id),
      ledger_entries:
        Repo.all(
          from l in PrepaidLedgerEntry,
            where: l.prepaid_account_id == ^prepaid_account_id,
            order_by: [desc: l.inserted_at]
        ),
      cards: Cards.by_prepaid_account(prepaid_account_id)
    )
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil
  defp parse_decimal(str) do
    case D.parse(str) do
      {d, ""} -> d
      _ -> nil
    end
  end

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil
  defp parse_date(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp money(nil), do: "—"
  defp money(%D{} = d), do: d |> D.round(2) |> D.to_string()
  defp money(v), do: to_string(v)

  defp status_cls("ACTIVE"),    do: "badge-green"
  defp status_cls("SUSPENDED"), do: "badge-yellow"
  defp status_cls("CLOSED"),    do: "badge-gray"
  defp status_cls("DORMANT"),   do: "badge-gray"
  defp status_cls("INACTIVE"),  do: "badge-blue"
  defp status_cls("BLOCKED"),   do: "badge-red"
  defp status_cls("EXPIRED"),   do: "badge-red"
  defp status_cls(_),           do: "badge-gray"

  defp entry_type_cls("LOAD"),       do: "badge-green"
  defp entry_type_cls("REFUND"),     do: "badge-green"
  defp entry_type_cls("SPEND"),      do: "badge-blue"
  defp entry_type_cls("FEE"),        do: "badge-yellow"
  defp entry_type_cls("EXPIRE"),     do: "badge-red"
  defp entry_type_cls("ADJUSTMENT"), do: "badge-gray"
  defp entry_type_cls(_),            do: "badge-gray"

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(%{mode: :list} = assigns) do
    ~H"""
    <div class="component-panel">
      <.page_header title="Prepaid Cards" subtitle="Closed-loop stored-value accounts (not Debit)">
        <:actions>
          <button :if={@can_edit} class="btn-sm btn-primary" phx-click="open_action" phx-value-a="create_account" phx-target={@myself}>+ New Account</button>
        </:actions>
      </.page_header>

      <%= if @notice do %><.alert kind={@notice_kind} message={@notice} /><% end %>

      <%= if @active_action == :create_account do %>
        <div class="action-panel" style="margin-bottom:16px;">
          <div class="action-panel-title">
            <span>💳 New Prepaid Account</span>
            <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
          </div>
          <form phx-submit="create_account_save" phx-target={@myself}>
            <div class="form-grid-2">
              <div class="form-group"><label class="form-label">First Name *</label>
                <input class="input" type="text" name="account[first_name]" required/></div>
              <div class="form-group"><label class="form-label">Last Name *</label>
                <input class="input" type="text" name="account[last_name]" required/></div>
              <div class="form-group"><label class="form-label">SYS ID *</label>
                <input class="input" type="text" name="account[sys_id]" maxlength="4" required/></div>
              <div class="form-group"><label class="form-label">Bank ID *</label>
                <input class="input" type="text" name="account[bank_id]" maxlength="4" required/></div>
              <div class="form-group"><label class="form-label">Logo ID (PREPAID product) *</label>
                <input class="input" type="text" name="account[logo_id]" maxlength="4" required/></div>
              <div class="form-group"><label class="form-label">Block ID *</label>
                <input class="input" type="text" name="account[block_id]" maxlength="4" required/></div>
            </div>
            <div style="display:flex;gap:8px;margin-top:12px;">
              <button type="submit" class="btn btn-primary">Open Account</button>
              <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
            </div>
          </form>
        </div>
      <% end %>

      <form phx-change="search" phx-target={@myself} style="margin-bottom:12px;">
        <input class="input" type="text" name="q" value={@search} placeholder="Search customer name…" style="max-width:320px;"/>
      </form>

      <div class="table-wrap">
        <table class="data-table">
          <thead>
            <tr><th>Customer</th><th>Stored-Value Balance</th><th>Currency</th><th>Status</th><th></th></tr>
          </thead>
          <tbody>
            <%= if @accounts == [] do %>
              <tr><td colspan="5" class="empty-row" style="text-align:center;">No prepaid accounts found.</td></tr>
            <% end %>
            <%= for a <- @accounts do %>
              <tr>
                <td><%= a.customer_name || "—" %></td>
                <td class="mono"><%= money(a.balance) %></td>
                <td><%= a.currency %></td>
                <td><span class={"badge #{status_cls(a.status)}"}><%= a.status %></span></td>
                <td><button class="btn btn-xs" phx-click="view_account" phx-value-id={a.prepaid_account_id} phx-target={@myself}>View</button></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  def render(%{mode: :detail} = assigns) do
    ~H"""
    <div class="component-panel">
      <.page_header title={"#{@account.customer_name} — Prepaid Account"} subtitle="Account detail">
        <:actions>
          <button class="btn-sm" phx-click="back_to_list" phx-target={@myself}>← Back to list</button>
        </:actions>
      </.page_header>

      <%= if @notice do %><.alert kind={@notice_kind} message={@notice} /><% end %>

      <div class="form-pane-section-title" style="display:flex;justify-content:space-between;align-items:center;">
        <span>Stored-Value Balance</span>
        <button :if={@can_edit} class="btn btn-sm btn-primary" phx-click="open_action" phx-value-a="load_account" phx-target={@myself}>+ Load Account</button>
      </div>

      <%= if @active_action == :load_account do %>
        <div class="action-panel" style="margin-bottom:16px;">
          <div class="action-panel-title">
            <span>💰 Load Prepaid Account</span>
            <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
          </div>
          <form phx-submit="load_account_save" phx-target={@myself}>
            <div class="form-grid-2">
              <div class="form-group"><label class="form-label">Amount *</label>
                <input class="input" type="text" name="load[amount]" placeholder="100.00" required/></div>
              <div class="form-group"><label class="form-label">Channel</label>
                <select class="input" name="load[channel]">
                  <option value="INTERNAL_TRANSFER">Internal Transfer</option>
                  <option value="ADMIN_MANUAL">Admin Manual</option>
                  <option value="EXTERNAL_BANK_TRANSFER">External Bank Transfer</option>
                  <option value="CASH_DEPOSIT">Cash Deposit</option>
                </select></div>
              <div class="form-group"><label class="form-label">Reference (required for external channels)</label>
                <input class="input" type="text" name="load[external_reference]"/></div>
              <div class="form-group"><label class="form-label">Expiry Date (optional — blank means this load never expires)</label>
                <input class="input" type="date" name="load[expiry_date]"/></div>
            </div>
            <div style="display:flex;gap:8px;margin-top:12px;">
              <button type="submit" class="btn btn-primary">Load</button>
              <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
            </div>
          </form>
        </div>
      <% end %>

      <div class="table-wrap">
        <table class="data-table">
          <tbody>
            <tr><td>Stored-Value Balance</td><td class="mono"><%= money(@balance) %> <%= @account.currency %></td></tr>
            <tr><td>Status</td><td><span class={"badge #{status_cls(@account.status)}"}><%= @account.status %></span></td></tr>
            <tr><td>Opened</td><td><%= @account.opened_at %></td></tr>
          </tbody>
        </table>
      </div>

      <div class="form-pane-section-title" style="margin-top:20px;">
        Ledger History (<%= length(@ledger_entries) %>)
      </div>
      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>Date</th><th>Type</th><th>Amount</th><th>Remaining</th><th>Expiry</th><th>Channel / Ref</th></tr></thead>
          <tbody>
            <%= if @ledger_entries == [] do %>
              <tr><td colspan="6" class="empty-row" style="text-align:center;">No ledger activity yet.</td></tr>
            <% end %>
            <%= for e <- @ledger_entries do %>
              <tr>
                <td><%= Calendar.strftime(e.inserted_at, "%Y-%m-%d %H:%M") %></td>
                <td><span class={"badge #{entry_type_cls(e.entry_type)}"}><%= e.entry_type %></span></td>
                <td class="mono"><%= money(e.amount) %></td>
                <td class="mono"><%= if e.remaining_amount, do: money(e.remaining_amount), else: "—" %></td>
                <td><%= e.expiry_date || "—" %></td>
                <td><%= e.channel || e.external_reference || "—" %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <div class="form-pane-section-title" style="display:flex;justify-content:space-between;align-items:center;margin-top:20px;">
        <span>Cards (<%= length(@cards) %>)</span>
        <button :if={@can_edit} class="btn btn-sm btn-primary" phx-click="open_action" phx-value-a="issue_card" phx-target={@myself}>+ Issue Card</button>
      </div>

      <%= if @active_action == :issue_card do %>
        <div class="action-panel" style="margin-bottom:16px;">
          <div class="action-panel-title">
            <span>💳 Issue Card</span>
            <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
          </div>
          <form phx-submit="issue_card_save" phx-target={@myself}>
            <div class="form-grid-2">
              <div class="form-group"><label class="form-label">Card Type</label>
                <select class="input" name="card[card_type]">
                  <option value="PRIMARY">Primary</option>
                  <option value="VIRTUAL">Virtual</option>
                </select></div>
            </div>
            <div style="display:flex;gap:8px;margin-top:12px;">
              <button type="submit" class="btn btn-primary">Issue Card</button>
              <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
            </div>
          </form>
        </div>
      <% end %>

      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>PAN (last 4)</th><th>Type</th><th>Status</th><th>Expiry</th><th></th></tr></thead>
          <tbody>
            <%= if @cards == [] do %>
              <tr><td colspan="5" class="empty-row" style="text-align:center;">No cards issued.</td></tr>
            <% end %>
            <%= for c <- @cards do %>
              <tr>
                <td class="mono">•••• <%= c.last_four %></td>
                <td><%= c.card_type %></td>
                <td><span class={"badge #{status_cls(c.status)}"}><%= c.status %></span></td>
                <td><%= c.expiry %></td>
                <td>
                  <div :if={@can_edit} style="display:flex;gap:6px;">
                    <button :if={c.status == "INACTIVE"} class="btn btn-xs" phx-click="card_activate" phx-value-id={c.card_id} phx-target={@myself}>Activate</button>
                    <button :if={c.status == "ACTIVE"} class="btn btn-xs" phx-click="card_block" phx-value-id={c.card_id} phx-target={@myself}>Block</button>
                    <button :if={c.status == "BLOCKED"} class="btn btn-xs" phx-click="card_unblock" phx-value-id={c.card_id} phx-target={@myself}>Unblock</button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
