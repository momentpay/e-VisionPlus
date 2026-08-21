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
  - **COL write-offs** (COL-P2) — `WriteOffCommand.pending/1`; approve
    enforces maker ≠ checker AND that the approver's ASM role is a member of
    `col.writeoff_approval_matrix` for the account's bank (a role-list gate,
    not an amount-authority gate — write-off approval is a policy decision).
  - **COL workout plans** (COL-P9) — `WorkoutCommand.pending/1`; role-list gate
    via `col.workout_approval_matrix`, same shape as write-offs.
  - **COL settlement offers** (COL-P9) — `SettlementCommand.pending/1`; gated by
    `col.settlement_authority_matrix`, tiered by the offer's discount size (a
    role's tier is its ceiling — mirrors the adjustment authority-limit check's
    shape but by discount percent instead of a dollar delta).
  - **HCS facility limit changes** (Way4 parity plan Phase 1 item 2,
    2026-07-25) — `FacilityLimitCommand.pending/1`; role-list gate via
    `hcs.facility_limit_approval_matrix`, same shape as COL's write-offs/
    workout plans.

  Visibility requires `approvals:view` (SUPERVISOR / RISK / ADMIN); action
  buttons additionally require `approvals:approve`, re-checked server-side.
  Command modules keep their signatures (ADR-A4) — the authenticated
  operator's username is what gets recorded as `approved_by`.
  """

  use Phoenix.LiveComponent
  import VmuCoreWeb.AdminUI
  import VmuCoreWeb.Components.AgGrid

  alias VmuCore.ASM.Authz
  alias VmuCore.TRAMS.{AdjustmentCommand, MaintenanceCommand}
  alias VmuCore.COL.{WriteOffCommand, WorkoutCommand, SettlementCommand}
  alias VmuCore.HCS.FacilityLimitCommand

  @impl true
  def mount(socket) do
    {:ok, assign(socket, adjustments: [], maintenance: [], col_writeoffs: [],
                 col_workouts: [], col_settlements: [], hcs_facility_limits: [], notice: nil,
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

  def handle_event("approve_writeoff", %{"id" => id}, socket) do
    with_approver(socket, fn operator ->
      case WriteOffCommand.approve(id, operator) do
        {:ok, _} ->
          socket |> put_notice("Write-off approved and posted.", :success) |> load_pending()

        {:error, :maker_cannot_approve} ->
          put_notice(socket, "4-eyes: you requested this write-off — a different operator must approve.", :error)

        {:error, {:role_not_authorized, allowed}} ->
          put_notice(socket,
            "Your role (#{operator.role}) is not authorized to approve write-offs for this " <>
            "account's bank. Allowed roles: #{Enum.join(allowed, ", ")}.", :error)

        {:error, {:not_pending, status}} ->
          put_notice(socket, "Write-off request is no longer pending (#{status}).", :error)

        {:error, :not_found} ->
          put_notice(socket, "Write-off request no longer exists.", :error)

        {:error, reason} ->
          put_notice(socket, "Approve failed: #{inspect(reason)}", :error)
      end
    end)
  end

  def handle_event("reject_writeoff", %{"id" => id}, socket) do
    with_approver(socket, fn operator ->
      case WriteOffCommand.reject(id, operator.username) do
        {:ok, _} -> socket |> put_notice("Write-off request rejected.", :success) |> load_pending()
        {:error, reason} -> put_notice(socket, "Reject failed: #{inspect(reason)}", :error)
      end
    end)
  end

  def handle_event("approve_workout", %{"id" => id}, socket) do
    with_approver(socket, fn operator ->
      case WorkoutCommand.approve(id, operator) do
        {:ok, _} ->
          socket |> put_notice("Workout plan approved and activated.", :success) |> load_pending()

        {:error, :maker_cannot_approve} ->
          put_notice(socket, "4-eyes: you requested this plan — a different operator must approve.", :error)

        {:error, {:role_not_authorized, allowed}} ->
          put_notice(socket,
            "Your role (#{operator.role}) is not authorized to approve workout plans for this " <>
            "account's bank. Allowed roles: #{Enum.join(allowed, ", ")}.", :error)

        {:error, reason} ->
          put_notice(socket, "Approve failed: #{inspect(reason)}", :error)
      end
    end)
  end

  def handle_event("reject_workout", %{"id" => id}, socket) do
    with_approver(socket, fn operator ->
      case WorkoutCommand.reject(id, operator.username) do
        {:ok, _} -> socket |> put_notice("Workout plan rejected.", :success) |> load_pending()
        {:error, reason} -> put_notice(socket, "Reject failed: #{inspect(reason)}", :error)
      end
    end)
  end

  def handle_event("approve_settlement", %{"id" => id}, socket) do
    with_approver(socket, fn operator ->
      case SettlementCommand.approve(id, operator) do
        {:ok, _} ->
          socket |> put_notice("Settlement offer approved.", :success) |> load_pending()

        {:error, :maker_cannot_approve} ->
          put_notice(socket, "4-eyes: you requested this offer — a different operator must approve.", :error)

        {:error, {:role_not_authorized, tiers}} ->
          put_notice(socket, "Your role (#{operator.role}) has no settlement authority tier configured. Tiers: #{inspect(tiers)}", :error)

        {:error, {:discount_exceeds_authority, discount, max_allowed}} ->
          put_notice(socket,
            "This offer's discount (#{discount}%) exceeds your authority (max #{max_allowed}% for #{operator.role}).", :error)

        {:error, reason} ->
          put_notice(socket, "Approve failed: #{inspect(reason)}", :error)
      end
    end)
  end

  def handle_event("reject_settlement", %{"id" => id}, socket) do
    with_approver(socket, fn operator ->
      case SettlementCommand.reject(id, operator.username) do
        {:ok, _} -> socket |> put_notice("Settlement offer rejected.", :success) |> load_pending()
        {:error, reason} -> put_notice(socket, "Reject failed: #{inspect(reason)}", :error)
      end
    end)
  end

  # Way4 parity plan Phase 1 item 2 (2026-07-25).
  def handle_event("approve_facility_limit", %{"id" => id}, socket) do
    with_approver(socket, fn operator ->
      case FacilityLimitCommand.approve(id, operator) do
        {:ok, _} ->
          socket |> put_notice("Facility limit change approved and applied.", :success) |> load_pending()

        {:error, :maker_cannot_approve} ->
          put_notice(socket,
            "4-eyes: you requested this change — a different operator must approve.", :error)

        {:error, {:role_not_authorized, allowed}} ->
          put_notice(socket,
            "Your role (#{operator.role}) is not authorized to approve facility limit changes " <>
            "for this company's bank. Allowed roles: #{Enum.join(allowed, ", ")}.", :error)

        {:error, reason} ->
          put_notice(socket, "Approve failed: #{inspect(reason)}", :error)
      end
    end)
  end

  def handle_event("reject_facility_limit", %{"id" => id}, socket) do
    with_approver(socket, fn operator ->
      case FacilityLimitCommand.reject(id, operator.username) do
        {:ok, _} -> socket |> put_notice("Facility limit change rejected.", :success) |> load_pending()
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
    <div id={@id} class="component-panel">
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
      <.ag_grid
        id="approval-inbox-adjustments-grid"
        empty_message="Nothing pending."
        columns={[
          %{field: "requested", header: "Requested", width: 150},
          %{field: "transaction", header: "Transaction", type: "mono", width: 130},
          %{field: "old_new", header: "Old → New", width: 160},
          %{field: "delta", header: "Delta", type: "money", width: 120},
          %{field: "direction", header: "Direction", type: "badge", classField: "direction_class", width: 110},
          %{field: "reason", header: "Reason", flex: 1},
          %{field: "maker", header: "Maker", type: "mono", width: 130},
          %{field: "actions", header: "", type: "actions", width: 140,
            actions: [
              %{label: "Approve", event: "approve_adjustment", param: "id",
                whenField: "can_approve", whenValue: true},
              %{label: "Reject", event: "reject_adjustment", param: "id",
                whenField: "can_approve", whenValue: true, danger: true}
            ]}
        ]}
        rows={Enum.map(@adjustments, &adjustment_row(&1, @can_approve))}
      />

      <%# TRAMS maintenance %>
      <h3 style="margin:1.5rem 0 0.5rem">TRAM Maintenance (<%= length(@maintenance) %>)</h3>
      <.ag_grid
        id="approval-inbox-maintenance-grid"
        empty_message="Nothing pending."
        columns={[
          %{field: "requested", header: "Requested", width: 150},
          %{field: "transaction", header: "Transaction", type: "mono", width: 130},
          %{field: "action", header: "Action", width: 140},
          %{field: "reason", header: "Reason", width: 140},
          %{field: "changes", header: "Changes", flex: 1},
          %{field: "maker", header: "Maker", type: "mono", width: 130},
          %{field: "actions", header: "", type: "actions", width: 140,
            actions: [
              %{label: "Approve", event: "approve_maintenance", param: "id",
                whenField: "can_approve", whenValue: true},
              %{label: "Reject", event: "reject_maintenance", param: "id",
                whenField: "can_approve", whenValue: true, danger: true}
            ]}
        ]}
        rows={Enum.map(@maintenance, &maintenance_row(&1, @can_approve))}
      />

      <%# COL write-offs %>
      <h3 style="margin:1.5rem 0 0.5rem">COL Write-offs (<%= length(@col_writeoffs) %>)</h3>
      <.ag_grid
        id="approval-inbox-writeoffs-grid"
        empty_message="Nothing pending."
        columns={[
          %{field: "requested", header: "Requested", width: 150},
          %{field: "account", header: "Account", type: "mono", width: 130},
          %{field: "dpd", header: "DPD", width: 100},
          %{field: "amount", header: "Amount", type: "money", width: 130},
          %{field: "ifrs9", header: "IFRS9", width: 100},
          %{field: "reason", header: "Reason", flex: 1},
          %{field: "requested_by", header: "Requested By", type: "mono", width: 130},
          %{field: "actions", header: "", type: "actions", width: 140,
            actions: [
              %{label: "Approve", event: "approve_writeoff", param: "id",
                whenField: "can_approve", whenValue: true},
              %{label: "Reject", event: "reject_writeoff", param: "id",
                whenField: "can_approve", whenValue: true, danger: true}
            ]}
        ]}
        rows={Enum.map(@col_writeoffs, &writeoff_row(&1, @can_approve))}
      />

      <%# COL workout plans %>
      <h3 style="margin:1.5rem 0 0.5rem">COL Workout Plans (<%= length(@col_workouts) %>)</h3>
      <.ag_grid
        id="approval-inbox-workouts-grid"
        empty_message="Nothing pending."
        columns={[
          %{field: "requested", header: "Requested", width: 150},
          %{field: "account", header: "Account", type: "mono", width: 130},
          %{field: "plan_type", header: "Type", width: 150},
          %{field: "terms", header: "Terms", width: 150},
          %{field: "period", header: "Period", width: 190},
          %{field: "reason", header: "Reason", flex: 1},
          %{field: "requested_by", header: "Requested By", type: "mono", width: 130},
          %{field: "actions", header: "", type: "actions", width: 140,
            actions: [
              %{label: "Approve", event: "approve_workout", param: "id",
                whenField: "can_approve", whenValue: true},
              %{label: "Reject", event: "reject_workout", param: "id",
                whenField: "can_approve", whenValue: true, danger: true}
            ]}
        ]}
        rows={Enum.map(@col_workouts, &workout_row(&1, @can_approve))}
      />

      <%# COL settlement offers %>
      <h3 style="margin:1.5rem 0 0.5rem">COL Settlement Offers (<%= length(@col_settlements) %>)</h3>
      <.ag_grid
        id="approval-inbox-settlements-grid"
        empty_message="Nothing pending."
        columns={[
          %{field: "requested", header: "Requested", width: 150},
          %{field: "account", header: "Account", type: "mono", width: 130},
          %{field: "outstanding", header: "Outstanding", type: "money", width: 130},
          %{field: "offer", header: "Offer", type: "money", width: 120},
          %{field: "discount", header: "Discount", width: 100},
          %{field: "expires", header: "Expires", width: 120},
          %{field: "requested_by", header: "Requested By", type: "mono", width: 130},
          %{field: "actions", header: "", type: "actions", width: 140,
            actions: [
              %{label: "Approve", event: "approve_settlement", param: "id",
                whenField: "can_approve", whenValue: true},
              %{label: "Reject", event: "reject_settlement", param: "id",
                whenField: "can_approve", whenValue: true, danger: true}
            ]}
        ]}
        rows={Enum.map(@col_settlements, &settlement_row(&1, @can_approve))}
      />

      <%!-- HCS facility limit changes (Way4 parity plan Phase 1 item 2). --%>
      <h3 style="margin:1.5rem 0 0.5rem">HCS Facility Limit Changes (<%= length(@hcs_facility_limits) %>)</h3>
      <.ag_grid
        id="approval-hcs-facility-limits-grid"
        paginate={false}
        empty_message="Nothing pending."
        columns={[
          %{field: "requested_at", header: "Requested", width: 150},
          %{field: "company_id", header: "Company", width: 120},
          %{field: "change", header: "Current → Requested", width: 200},
          %{field: "reason", header: "Reason", flex: 1},
          %{field: "requested_by", header: "Requested By", type: "mono", width: 160},
          %{field: "actions", header: "Actions", type: "actions", width: 180,
            actions: [
              %{label: "Approve", event: "approve_facility_limit", param: "row_id",
                whenField: "can_approve", whenValue: true},
              %{label: "Reject", event: "reject_facility_limit", param: "row_id", danger: true,
                whenField: "can_approve", whenValue: true}
            ]}
        ]}
        rows={Enum.map(@hcs_facility_limits, &facility_limit_row(&1, @can_approve))}
      />

      <p class="text-muted" style="margin-top:0.75rem; font-size:0.85em">
        CMS temp limits, fee waivers, and financial adjustments use inline
        supervisor sign-off at the point of entry (Account module) — the
        supervisor named there is validated as a real, distinct, authorized
        operator within authority. Approving a settlement offer authorizes it —
        recording the actual payment/forgiveness happens separately once the
        customer pays (`SettlementCommand.settle/3`, driven from the COL case
        detail screen).
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
      maintenance: MaintenanceCommand.pending(100),
      col_writeoffs: WriteOffCommand.pending(100),
      col_workouts: WorkoutCommand.pending(100),
      col_settlements: SettlementCommand.pending(100),
      hcs_facility_limits: FacilityLimitCommand.pending(100))
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

  # ---------------------------------------------------------------------------
  # Grid row builders — one flat map per pending item; `can_approve` is the
  # component-level assign folded into each row so the actions column's
  # `whenField`/`whenValue` can hide Approve/Reject per row (same pattern as
  # CmsEodComponent's `can_retry`).
  # ---------------------------------------------------------------------------

  defp facility_limit_row(c, can_approve) do
    %{
      row_id: to_string(c.id),
      requested_at: Calendar.strftime(c.inserted_at, "%Y-%m-%d %H:%M"),
      company_id: c.company_id,
      change: "#{c.current_limit} → #{c.requested_limit}",
      reason: c.reason,
      requested_by: c.requested_by,
      can_approve: can_approve
    }
  end

  defp adjustment_row(adj, can_approve) do
    %{
      id: adj.adjustment_id,
      requested: Calendar.strftime(adj.inserted_at, "%Y-%m-%d %H:%M"),
      transaction: String.slice(to_string(adj.transaction_id), 0, 8) <> "…",
      old_new: "#{adj.old_amount} → #{adj.new_amount}",
      delta: adj.delta,
      direction: adj.direction,
      direction_class: if(adj.direction == "CREDIT", do: "badge-success", else: "badge-warning"),
      reason: adj.reason_code,
      maker: adj.requested_by,
      can_approve: can_approve
    }
  end

  defp maintenance_row(m, can_approve) do
    %{
      id: m.id,
      requested: Calendar.strftime(m.inserted_at, "%Y-%m-%d %H:%M"),
      transaction: String.slice(to_string(m.transaction_id), 0, 8) <> "…",
      action: m.action_type,
      reason: m.reason_code,
      changes: inspect(m.after_values),
      maker: m.requested_by,
      can_approve: can_approve
    }
  end

  defp writeoff_row(w, can_approve) do
    %{
      id: w.id,
      requested: Calendar.strftime(w.inserted_at, "%Y-%m-%d %H:%M"),
      account: String.slice(to_string(w.account_id), 0, 8) <> "…",
      dpd: w.dpd_bucket,
      amount: w.write_off_amount,
      ifrs9: w.ifrs9_stage,
      reason: w.reason,
      requested_by: w.requested_by,
      can_approve: can_approve
    }
  end

  defp workout_row(w, can_approve) do
    %{
      id: w.id,
      requested: Calendar.strftime(w.inserted_at, "%Y-%m-%d %H:%M"),
      account: String.slice(to_string(w.account_id), 0, 8) <> "…",
      plan_type: w.plan_type,
      terms: workout_terms(w),
      period: "#{w.start_date} → #{w.end_date}",
      reason: w.reason,
      requested_by: w.requested_by,
      can_approve: can_approve
    }
  end

  defp workout_terms(%{plan_type: "APR_REDUCTION", new_apr: apr}), do: "new APR #{apr}%"
  defp workout_terms(%{plan_type: "PAYMENT_HOLIDAY", holiday_months: m}), do: "#{m} month(s)"
  defp workout_terms(%{plan_type: "RESTRUCTURE", emi_tenor_months: m}), do: "#{m} month EMI"
  defp workout_terms(_), do: "—"

  defp settlement_row(s, can_approve) do
    %{
      id: s.id,
      requested: Calendar.strftime(s.inserted_at, "%Y-%m-%d %H:%M"),
      account: String.slice(to_string(s.account_id), 0, 8) <> "…",
      outstanding: s.outstanding_amount,
      offer: s.offer_amount,
      discount: "#{s.discount_percent}%",
      expires: s.expiry_date,
      requested_by: s.requested_by,
      can_approve: can_approve
    }
  end

end
