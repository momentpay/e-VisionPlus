defmodule VmuCoreWeb.Live.Admin.ApprovalInboxComponent do
  @moduledoc """
  Unified 4-eyes approval inbox (ASM-P3.3).

  One place for a checker to work every pending item, instead of hunting
  per-module queues:

  - **TRAMS adjustments** — `AdjustmentCommand.pending/1`; approve enforces
    maker ≠ checker (in the command) AND the checker's authority limit for
    the delta (`Authz.within_authority?`, ASM-P3.2) before invoking.
  - **TRAMS maintenance** — `MaintenanceCommand.pending/1`; non-financial,
    so maker ≠ checker only.

  Visibility requires `approvals:view` (SUPERVISOR / RISK / ADMIN); action
  buttons additionally require `approvals:approve`, re-checked server-side.
  Command modules keep their signatures (ADR-A4) — the authenticated
  operator's username is what gets recorded as `approved_by`.
  """

  use Phoenix.LiveComponent
  import VmuCoreWeb.AdminUI

  alias VmuCore.ASM.Authz
  alias VmuCore.TRAMS.{AdjustmentCommand, MaintenanceCommand}

  @impl true
  def mount(socket) do
    {:ok, assign(socket, adjustments: [], maintenance: [], notice: nil,
                 notice_kind: :info, current_operator: nil, can_approve: false)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     socket
     |> assign(can_approve:
          Authz.can?(socket.assigns.current_operator, "approvals", "approve"))
     |> load_pending()}
  end

  # ---------------------------------------------------------------------------
  # Events — every mutation re-checks permission + authority server-side
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("approve_adjustment", %{"id" => id}, socket) do
    with_approver(socket, fn operator ->
      adjustment = Enum.find(socket.assigns.adjustments, &(&1.adjustment_id == id))

      cond do
        is_nil(adjustment) ->
          put_notice(socket, "Adjustment no longer pending.", :error)

        not Authz.within_authority?(operator, adjustment.delta) ->
          put_notice(socket,
            "Amount #{adjustment.delta} exceeds your approval authority " <>
            "(#{inspect(Authz.authority_limit(operator))}).", :error)

        true ->
          case AdjustmentCommand.approve(id, operator.username) do
            {:ok, _} ->
              socket |> put_notice("Adjustment approved and posted.", :success) |> load_pending()

            {:error, :maker_cannot_approve} ->
              put_notice(socket, "4-eyes: you requested this adjustment — a different operator must approve.", :error)

            {:error, reason} ->
              put_notice(socket, "Approve failed: #{inspect(reason)}", :error)
          end
      end
    end)
  end

  def handle_event("reject_adjustment", %{"id" => id}, socket) do
    with_approver(socket, fn operator ->
      case AdjustmentCommand.reject(id, operator.username) do
        {:ok, _} -> socket |> put_notice("Adjustment rejected.", :success) |> load_pending()
        {:error, reason} -> put_notice(socket, "Reject failed: #{inspect(reason)}", :error)
      end
    end)
  end

  def handle_event("approve_maintenance", %{"id" => id}, socket) do
    with_approver(socket, fn operator ->
      case MaintenanceCommand.approve(id, operator.username) do
        {:ok, _} ->
          socket |> put_notice("Maintenance action approved and applied.", :success) |> load_pending()

        {:error, :maker_cannot_approve} ->
          put_notice(socket, "4-eyes: you requested this action — a different operator must approve.", :error)

        {:error, reason} ->
          put_notice(socket, "Approve failed: #{inspect(reason)}", :error)
      end
    end)
  end

  def handle_event("reject_maintenance", %{"id" => id}, socket) do
    with_approver(socket, fn operator ->
      case MaintenanceCommand.reject(id, operator.username) do
        {:ok, _} -> socket |> put_notice("Maintenance action rejected.", :success) |> load_pending()
        {:error, reason} -> put_notice(socket, "Reject failed: #{inspect(reason)}", :error)
      end
    end)
  end

  def handle_event("refresh", _, socket) do
    {:noreply, load_pending(socket)}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="component-panel">
      <.page_header title="Approval Inbox"
                    subtitle="Pending 4-eyes items across modules — maker ≠ checker and authority limits enforced">
        <:actions>
          <button class="btn-sm" phx-click="refresh" phx-target={@myself}>↻ Refresh</button>
        </:actions>
      </.page_header>

      <%= if @notice do %>
        <.alert kind={@notice_kind} message={@notice} />
      <% end %>

      <%= if not @can_approve do %>
        <.alert kind={:warning}
                message="You can view this queue but your role cannot approve — items must be actioned by SUPERVISOR / RISK / ADMIN." />
      <% end %>

      <%# TRAMS adjustments %>
      <h3 style="margin:1rem 0 0.5rem">TRAM Adjustments (<%= length(@adjustments) %>)</h3>
      <div class="table-wrapper">
        <table class="data-table">
          <thead>
            <tr>
              <th>Requested</th><th>Transaction</th><th>Old → New</th><th>Delta</th>
              <th>Direction</th><th>Reason</th><th>Maker</th><th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= if @adjustments == [] do %>
              <tr><td colspan="8" style="text-align:center;color:#888">Nothing pending.</td></tr>
            <% end %>
            <%= for adj <- @adjustments do %>
              <tr>
                <td style="white-space:nowrap"><%= Calendar.strftime(adj.inserted_at, "%Y-%m-%d %H:%M") %></td>
                <td><code style="font-size:0.75em"><%= String.slice(to_string(adj.transaction_id), 0, 8) %>…</code></td>
                <td><%= adj.old_amount %> → <%= adj.new_amount %></td>
                <td style="text-align:right"><%= adj.delta %></td>
                <td><span class={"badge badge-#{if adj.direction == "CREDIT", do: "success", else: "warning"}"}><%= adj.direction %></span></td>
                <td><%= adj.reason_code %></td>
                <td><code><%= adj.requested_by %></code></td>
                <td>
                  <%= if @can_approve do %>
                    <button class="btn-sm btn-success" phx-click="approve_adjustment"
                            phx-value-id={adj.adjustment_id} phx-target={@myself}>Approve</button>
                    <button class="btn-sm btn-warning" phx-click="reject_adjustment"
                            phx-value-id={adj.adjustment_id} phx-target={@myself}>Reject</button>
                  <% else %>
                    <span class="text-muted">—</span>
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <%# TRAMS maintenance %>
      <h3 style="margin:1.5rem 0 0.5rem">TRAM Maintenance (<%= length(@maintenance) %>)</h3>
      <div class="table-wrapper">
        <table class="data-table">
          <thead>
            <tr>
              <th>Requested</th><th>Transaction</th><th>Action</th><th>Reason</th>
              <th>Changes</th><th>Maker</th><th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= if @maintenance == [] do %>
              <tr><td colspan="7" style="text-align:center;color:#888">Nothing pending.</td></tr>
            <% end %>
            <%= for m <- @maintenance do %>
              <tr>
                <td style="white-space:nowrap"><%= Calendar.strftime(m.inserted_at, "%Y-%m-%d %H:%M") %></td>
                <td><code style="font-size:0.75em"><%= String.slice(to_string(m.transaction_id), 0, 8) %>…</code></td>
                <td><%= m.action_type %></td>
                <td><%= m.reason_code %></td>
                <td style="font-size:0.8em"><%= inspect(m.after_values) %></td>
                <td><code><%= m.requested_by %></code></td>
                <td>
                  <%= if @can_approve do %>
                    <button class="btn-sm btn-success" phx-click="approve_maintenance"
                            phx-value-id={m.id} phx-target={@myself}>Approve</button>
                    <button class="btn-sm btn-warning" phx-click="reject_maintenance"
                            phx-value-id={m.id} phx-target={@myself}>Reject</button>
                  <% else %>
                    <span class="text-muted">—</span>
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <p class="text-muted" style="margin-top:0.75rem; font-size:0.85em">
        CMS temp limits, fee waivers, and financial adjustments use inline
        supervisor sign-off at the point of entry (Account module) — the
        supervisor named there is validated as a real, distinct, authorized
        operator within authority.
      </p>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_pending(socket) do
    assign(socket,
      adjustments: AdjustmentCommand.pending(100),
      maintenance: MaintenanceCommand.pending(100))
  end

  defp with_approver(socket, fun) do
    operator = socket.assigns.current_operator

    if socket.assigns.can_approve and not is_nil(operator) do
      {:noreply, fun.(operator)}
    else
      {:noreply, put_notice(socket, "Your role cannot approve items in this queue.", :error)}
    end
  end

  defp put_notice(socket, msg, kind), do: assign(socket, notice: msg, notice_kind: kind)
end
