defmodule VmuCoreWeb.Live.Admin.HcsComponent do
  @moduledoc """
  Admin LiveComponent: HCS company list/detail (Way4 parity plan Phase 1
  item 2, 2026-07-25) — the first ops UI for HCS, closing the "no admin
  UI" gap. Ported from Avenza's `hcs_component.ex`, adapted to this app's
  session/authz model (`ASM.Authz.can?/3`, not `WalletWeb.Authorization.
  Policy`).

  - Company list with search, and a "+ New Company" form
  - Company detail: full field view, edit non-financial fields directly,
    employee card roster (read-only — full employee CRUD is a later
    item), spending controls (read-only, same reason)
  - **Facility limit changes are NOT edited directly** — they're requested
    here (`FacilityLimitCommand.request/3`) and approved from the existing
    unified Approval Inbox, the same "one action surface" split COL uses
    for write-offs/workout plans/settlement offers.

  Fleet vehicles/driver assignment/spend reports (Way4 parity plan Phase 1
  item 3, 2026-07-25) — vehicle roster + "+ Add Vehicle" live in the
  company detail view; a vehicle detail view (fleet card issuance, driver
  assignment history) is its own `:vehicle_detail` mode, same split
  Avenza's original uses.

  Visibility requires `hcs:view`; create/edit/request-limit-change require
  `hcs:edit`.
  """

  use Phoenix.LiveComponent
  import Ecto.Query
  import VmuCoreWeb.AdminUI

  alias VmuCore.{Repo, HCS.Company, HCS.EmployeeCard, HCS.SpendingControl,
                 HCS.CompanyOnboarding, HCS.FacilityLimitCommand, HCS.FacilityLimitChange,
                 HCS.Vehicle, HCS.FleetCard, HCS.FleetOnboarding, HCS.DriverAssignmentCommand,
                 HCS.FleetReport}
  alias VmuCore.ASM.Authz
  alias Decimal, as: D

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       mode: :list,
       search: "",
       companies: [],
       notice: nil,
       notice_kind: :info,
       active_action: :none,
       company: nil,
       employee_cards: [],
       spending_controls: [],
       pending_limit_changes: [],
       vehicles: [],
       report_kind: :vehicle,
       report_rows: [],
       report_period_from: nil,
       report_period_to: nil,
       selected_vehicle: nil,
       selected_vehicle_card: nil,
       selected_vehicle_history: [],
       can_edit: false,
       loaded_deep_link_id: nil
     )
     |> load_companies()}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    operator = socket.assigns[:current_operator]
    socket = assign(socket, can_edit: operator && Authz.can?(operator, "hcs", "edit"))

    # Koṣa domain-model alignment (2026-07-28) — a "View in Corporate Cards
    # (HCS)" link lands here with ?view=<company_id> (Arrangements.search/1
    # already resolves CORPORATE_EMPLOYEE/CORPORATE_FLEET refs up to their
    # parent company, since HCS has no standalone card-level detail view).
    socket =
      case assigns[:deep_link_id] do
        id when is_binary(id) and id != "" and id != socket.assigns.loaded_deep_link_id ->
          socket |> load_detail(id) |> assign(loaded_deep_link_id: id)

        _ ->
          socket
      end

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # List events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(search: q) |> load_companies()}
  end

  def handle_event("view_company", %{"id" => id}, socket) do
    {:noreply, load_detail(socket, id)}
  end

  def handle_event("back_to_list", _, socket) do
    {:noreply, socket |> assign(mode: :list, active_action: :none, notice: nil) |> load_companies()}
  end

  def handle_event("open_action", %{"a" => action}, socket) do
    {:noreply, assign(socket, active_action: String.to_atom(action), notice: nil)}
  end

  def handle_event("action_close", _, socket) do
    {:noreply, assign(socket, active_action: :none)}
  end

  # ---------------------------------------------------------------------------
  # Create company
  # ---------------------------------------------------------------------------

  def handle_event("create_company_save", %{"company" => params}, socket) do
    if socket.assigns.can_edit do
      credit_limit = parse_decimal(params["credit_limit"])

      cond do
        is_nil(credit_limit) or D.compare(credit_limit, D.new(0)) != :gt ->
          {:noreply, assign(socket, notice: "Facility credit limit must be a positive number.", notice_kind: :error)}

        params["company_code"] in [nil, ""] or params["company_name"] in [nil, ""] ->
          {:noreply, assign(socket, notice: "Company code and name are required.", notice_kind: :error)}

        true ->
          # The parent facility placeholder account needs a backing CIF
          # customer (Account.customer_id is required) — HCS has no bare
          # "company" identity independent of CIF today, so one is created
          # here as a CORPORATE-tier customer using the company's own name.
          customer_result =
            %VmuCore.Shared.Customer{}
            |> VmuCore.Shared.Customer.changeset(%{
              sys_id: params["sys_id"], bank_id: params["bank_id"],
              first_name: "Corporate", last_name: params["company_name"],
              customer_tier: "CORPORATE", company_name: params["company_name"],
              # Found live 2026-07-25: `|| "PENDING"` only catches nil, not
              # the empty string an untouched form field actually submits
              # — the original ported code had this same gap, never
              # caught (Avenza's version has zero tests).
              registration_number: blank_to_nil(params["registration_no"]) || "PENDING"
            })
            |> Repo.insert()

          with {:ok, customer} <- customer_result do
            attrs = %{
              account_attrs: %{
                customer_id: customer.customer_id,
                sys_id: params["sys_id"], bank_id: params["bank_id"],
                logo_id: params["logo_id"], block_id: params["block_id"],
                pan_token: synthetic_pan_token(), last_four: "0000",
                expiry_date: "0000", credit_limit: credit_limit
              },
              company_attrs: %{
                company_code: params["company_code"], company_name: params["company_name"],
                registration_no: params["registration_no"], liability_model: "CENTRAL",
                credit_limit: credit_limit
              }
            }

            case CompanyOnboarding.onboard_company(attrs) do
              {:ok, %{company: company}} ->
                {:noreply, socket |> assign(mode: :list, notice: "Company #{company.company_code} created.", notice_kind: :success) |> load_companies()}

              {:error, reason} ->
                {:noreply, assign(socket, notice: "Create failed — #{inspect(reason)}", notice_kind: :error)}
            end
          else
            {:error, changeset} ->
              {:noreply, assign(socket, notice: "Create failed (customer) — #{inspect(changeset.errors)}", notice_kind: :error)}
          end
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot create companies.", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Edit company (non-financial fields)
  # ---------------------------------------------------------------------------

  def handle_event("edit_company_save", %{"company" => params}, socket) do
    if socket.assigns.can_edit do
      company = socket.assigns.company

      attrs = %{
        company_name: params["company_name"],
        registration_no: params["registration_no"],
        tax_id: params["tax_id"],
        industry_code: params["industry_code"],
        relationship_manager: params["relationship_manager"],
        billing_cycle_day: parse_int(params["billing_cycle_day"]),
        max_employee_cards: parse_int(params["max_employee_cards"]),
        status: params["status"]
      }

      case company |> Company.changeset(attrs) |> Repo.update() do
        {:ok, updated} ->
          {:noreply, socket |> assign(company: updated, active_action: :none,
                        notice: "Company updated.", notice_kind: :success)}

        {:error, changeset} ->
          {:noreply, assign(socket, notice: "Update failed — #{inspect(changeset.errors)}", notice_kind: :error)}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot edit companies.", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Request facility limit change (maker-checker via Approval Inbox)
  # ---------------------------------------------------------------------------

  def handle_event("request_limit_save", %{"action" => params}, socket) do
    if socket.assigns.can_edit do
      operator = socket.assigns.current_operator
      requested = parse_decimal(params["requested_limit"])

      cond do
        is_nil(requested) or D.compare(requested, D.new(0)) != :gt ->
          {:noreply, assign(socket, notice: "Requested limit must be a positive number.", notice_kind: :error)}

        true ->
          case FacilityLimitCommand.request(socket.assigns.company.id, requested,
                 reason: params["reason"], requested_by: operator.username) do
            {:ok, _change} ->
              {:noreply, socket |> assign(active_action: :none,
                            notice: "Facility limit change requested — pending approval in the Approval Inbox.",
                            notice_kind: :success)
                         |> reload_pending_changes()}

            {:error, reason} ->
              {:noreply, assign(socket, notice: "Request failed — #{inspect(reason)}", notice_kind: :error)}
          end
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot request limit changes.", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Vehicles / fleet cards / driver assignment (Way4 parity plan Phase 1
  # item 3, 2026-07-25)
  # ---------------------------------------------------------------------------

  def handle_event("add_vehicle_save", %{"vehicle" => params}, socket) do
    if socket.assigns.can_edit do
      attrs = %{
        vin: blank_to_nil(params["vin"]), plate_number: params["plate_number"],
        make: params["make"], model: params["model"], year: parse_int(params["year"])
      }

      case FleetOnboarding.add_vehicle(socket.assigns.company.id, attrs) do
        {:ok, vehicle} ->
          {:noreply, socket
                      |> assign(active_action: :none, notice: "Vehicle #{vehicle.plate_number} added.", notice_kind: :success)
                      |> load_vehicles()}

        {:error, changeset} ->
          {:noreply, assign(socket, notice: "Add vehicle failed — #{inspect(changeset.errors)}", notice_kind: :error)}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot add vehicles.", notice_kind: :error)}
    end
  end

  def handle_event("view_vehicle", %{"id" => id}, socket) do
    {:noreply, load_vehicle_detail(socket, id)}
  end

  def handle_event("back_to_company", _, socket) do
    {:noreply, socket
                |> assign(mode: :detail, active_action: :none, notice: nil, selected_vehicle: nil)
                |> load_vehicles()}
  end

  def handle_event("issue_fleet_card_save", %{"card" => params}, socket) do
    if socket.assigns.can_edit do
      limit = parse_decimal(params["individual_limit"])
      vehicle = socket.assigns.selected_vehicle

      cond do
        is_nil(limit) or D.compare(limit, D.new(0)) != :gt ->
          {:noreply, assign(socket, notice: "Individual limit must be a positive number.", notice_kind: :error)}

        true ->
          card_attrs = %{
            individual_limit: limit,
            can_withdraw_cash: params["can_withdraw_cash"] == "true",
            monthly_spend_cap: parse_decimal(params["monthly_spend_cap"])
          }

          case FleetOnboarding.add_fleet_card(socket.assigns.company.id, vehicle.id, card_attrs) do
            {:ok, _result} ->
              {:noreply, socket
                          |> load_vehicle_detail(vehicle.id)
                          |> assign(active_action: :none, notice: "Fleet card issued for #{vehicle.plate_number}.", notice_kind: :success)}

            {:error, reason} ->
              {:noreply, assign(socket, notice: "Card issuance failed — #{inspect(reason)}", notice_kind: :error)}
          end
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot issue fleet cards.", notice_kind: :error)}
    end
  end

  def handle_event("assign_driver_save", %{"driver" => params}, socket) do
    if socket.assigns.can_edit do
      vehicle = socket.assigns.selected_vehicle

      if params["driver_name"] in [nil, ""] do
        {:noreply, assign(socket, notice: "Driver name is required.", notice_kind: :error)}
      else
        {:ok, _assignment} =
          DriverAssignmentCommand.assign_driver(vehicle.id, params["driver_name"], blank_to_nil(params["driver_license_no"]))

        {:noreply, socket
                    |> load_vehicle_detail(vehicle.id)
                    |> assign(active_action: :none, notice: "Driver assigned to #{vehicle.plate_number}.", notice_kind: :success)}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot assign drivers.", notice_kind: :error)}
    end
  end

  def handle_event("unassign_driver", _, socket) do
    if socket.assigns.can_edit do
      vehicle = socket.assigns.selected_vehicle

      case DriverAssignmentCommand.unassign_driver(vehicle.id) do
        :ok ->
          {:noreply, socket
                      |> load_vehicle_detail(vehicle.id)
                      |> assign(notice: "Driver unassigned.", notice_kind: :success)}

        {:error, :no_active_assignment} ->
          {:noreply, assign(socket, notice: "No driver currently assigned.", notice_kind: :error)}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot unassign drivers.", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Fleet spend report
  # ---------------------------------------------------------------------------

  def handle_event("generate_report_save", %{"report" => params}, socket) do
    with {:ok, from_date} <- Date.from_iso8601(params["period_from"] || ""),
         {:ok, to_date}   <- Date.from_iso8601(params["period_to"] || "") do
      kind = if params["kind"] == "driver", do: :driver, else: :vehicle
      company_id = socket.assigns.company.id

      rows =
        case kind do
          :vehicle -> FleetReport.spend_by_vehicle(company_id, from_date, to_date)
          :driver  -> FleetReport.spend_by_driver(company_id, from_date, to_date)
        end

      {:noreply, assign(socket,
        report_kind: kind, report_rows: rows,
        report_period_from: from_date, report_period_to: to_date,
        notice: nil)}
    else
      _ -> {:noreply, assign(socket, notice: "Enter a valid date range.", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — data loading
  # ---------------------------------------------------------------------------

  defp load_companies(socket) do
    search = String.trim(socket.assigns[:search] || "")

    query =
      if search == "" do
        from(c in Company, order_by: [asc: c.company_name])
      else
        pattern = "%#{search}%"
        from(c in Company,
          where: ilike(c.company_name, ^pattern) or ilike(c.company_code, ^pattern),
          order_by: [asc: c.company_name])
      end

    assign(socket, companies: Repo.all(query), mode: :list)
  end

  defp load_detail(socket, company_id) do
    company = Repo.get!(Company, company_id)

    socket
    |> assign(
      mode: :detail,
      company: company,
      active_action: :none,
      notice: nil,
      employee_cards: Repo.all(from e in EmployeeCard, where: e.company_id == ^company.id, order_by: [asc: e.employee_name]),
      spending_controls: Repo.all(from s in SpendingControl, where: s.company_id == ^company.id)
    )
    |> reload_pending_changes()
    |> load_vehicles()
  end

  # Augments each Vehicle with its current driver name and whether a fleet
  # card has been issued, so the roster table doesn't need N+1 lookups
  # from the template.
  defp load_vehicles(socket) do
    company = socket.assigns.company

    vehicles =
      Repo.all(from v in Vehicle, where: v.company_id == ^company.id, order_by: [asc: v.plate_number])
      |> Enum.map(fn v ->
        assignment = DriverAssignmentCommand.current_assignment(v.id)
        has_card = Repo.exists?(from fc in FleetCard, where: fc.vehicle_id == ^v.id and fc.status == "ACTIVE")

        v
        |> Map.put(:current_driver, assignment && assignment.driver_name)
        |> Map.put(:has_card, has_card)
      end)

    assign(socket, vehicles: vehicles)
  end

  defp load_vehicle_detail(socket, vehicle_id) do
    vehicle = Repo.get!(Vehicle, vehicle_id)

    fleet_card =
      Repo.one(
        from fc in FleetCard,
          where: fc.vehicle_id == ^vehicle.id and fc.status == "ACTIVE",
          limit: 1
      )

    assign(socket,
      mode: :vehicle_detail,
      active_action: :none,
      notice: nil,
      selected_vehicle: vehicle,
      selected_vehicle_card: fleet_card,
      selected_vehicle_history: DriverAssignmentCommand.history(vehicle.id)
    )
  end

  defp reload_pending_changes(socket) do
    company = socket.assigns.company

    assign(socket,
      pending_limit_changes:
        Repo.all(
          from c in FacilityLimitChange,
            where: c.company_id == ^company.id and c.status == "PENDING_APPROVAL",
            order_by: [desc: c.inserted_at]
        ))
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  defp synthetic_pan_token do
    :crypto.hash(:sha256, "hcs-facility-#{System.unique_integer([:positive])}-#{:rand.uniform(999_999_999)}")
    |> Base.encode16(case: :lower)
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil
  defp parse_decimal(str) do
    case D.parse(str) do
      {d, ""} -> d
      _ -> nil
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp money(nil), do: "—"
  defp money(%D{} = d), do: d |> D.round(2) |> D.to_string()
  defp money(v), do: to_string(v)

  defp status_cls("ACTIVE"),    do: "badge-green"
  defp status_cls("SUSPENDED"), do: "badge-yellow"
  defp status_cls("CLOSED"),    do: "badge-gray"
  defp status_cls(_),           do: "badge-gray"

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(%{mode: :list} = assigns) do
    ~H"""
    <div class="component-panel">
      <.page_header title="Corporate Card Programmes (HCS)" subtitle="Company facilities and employee cards">
        <:actions>
          <button :if={@can_edit} class="btn-sm btn-primary" phx-click="open_action" phx-value-a="create_company" phx-target={@myself}>+ New Company</button>
        </:actions>
      </.page_header>

      <%= if @notice do %><.alert kind={@notice_kind} message={@notice} /><% end %>

      <%= if @active_action == :create_company do %>
        <div class="action-panel" style="margin-bottom:16px;">
          <div class="action-panel-title">
            <span>🏢 New Company</span>
            <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
          </div>
          <form phx-submit="create_company_save" phx-target={@myself}>
            <div class="form-grid-2">
              <div class="form-group"><label class="form-label">Company Code *</label>
                <input class="input" type="text" name="company[company_code]" maxlength="10" required/></div>
              <div class="form-group"><label class="form-label">Company Name *</label>
                <input class="input" type="text" name="company[company_name]" required/></div>
              <div class="form-group"><label class="form-label">Registration No.</label>
                <input class="input" type="text" name="company[registration_no]"/></div>
              <div class="form-group"><label class="form-label">Facility Credit Limit *</label>
                <input class="input" type="text" name="company[credit_limit]" placeholder="100000.00" required/></div>
              <div class="form-group"><label class="form-label">SYS ID *</label>
                <input class="input" type="text" name="company[sys_id]" maxlength="4" required/></div>
              <div class="form-group"><label class="form-label">Bank ID *</label>
                <input class="input" type="text" name="company[bank_id]" maxlength="4" required/></div>
              <div class="form-group"><label class="form-label">Logo ID *</label>
                <input class="input" type="text" name="company[logo_id]" maxlength="4" required/></div>
              <div class="form-group"><label class="form-label">Block ID *</label>
                <input class="input" type="text" name="company[block_id]" maxlength="4" required/></div>
            </div>
            <div style="display:flex;gap:8px;margin-top:12px;">
              <button type="submit" class="btn btn-primary">Create Company</button>
              <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
            </div>
          </form>
        </div>
      <% end %>

      <form phx-change="search" phx-target={@myself} style="margin-bottom:12px;">
        <input class="input" type="text" name="q" value={@search} placeholder="Search company code or name…" style="max-width:320px;"/>
      </form>

      <div class="table-wrap">
        <table class="data-table">
          <thead>
            <tr><th>Code</th><th>Name</th><th>Liability</th><th>Facility Limit</th><th>Available</th><th>Status</th><th></th></tr>
          </thead>
          <tbody>
            <%= if @companies == [] do %>
              <tr><td colspan="7" class="empty-row" style="text-align:center;">No companies found.</td></tr>
            <% end %>
            <%= for c <- @companies do %>
              <tr>
                <td class="mono"><%= c.company_code %></td>
                <td><%= c.company_name %></td>
                <td><%= c.liability_model %></td>
                <td class="mono"><%= money(c.credit_limit) %></td>
                <td class="mono"><%= money(c.available_limit) %></td>
                <td><span class={"badge #{status_cls(c.status)}"}><%= c.status %></span></td>
                <td><button class="btn btn-xs" phx-click="view_company" phx-value-id={c.id} phx-target={@myself}>View</button></td>
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
      <.page_header title={"#{@company.company_name} (#{@company.company_code})"} subtitle="Company facility detail">
        <:actions>
          <button class="btn-sm" phx-click="back_to_list" phx-target={@myself}>← Back to list</button>
        </:actions>
      </.page_header>

      <%= if @notice do %><.alert kind={@notice_kind} message={@notice} /><% end %>

      <div class="form-pane-section-title" style="display:flex;justify-content:space-between;align-items:center;">
        <span>Facility</span>
        <div :if={@can_edit} style="display:flex;gap:8px;">
          <button class="btn btn-sm" phx-click="open_action" phx-value-a="edit_company" phx-target={@myself}>Edit</button>
          <button class="btn btn-sm btn-primary" phx-click="open_action" phx-value-a="request_limit" phx-target={@myself}>Request Limit Change</button>
        </div>
      </div>

      <%= if @active_action == :request_limit do %>
        <div class="action-panel action-panel-warning" style="margin-bottom:16px;">
          <div class="action-panel-title">
            <span>📈 Request Facility Limit Change</span>
            <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
          </div>
          <div style="font-size:12px;color:var(--text-secondary);margin-bottom:14px;">
            Current limit: <strong class="mono"><%= money(@company.credit_limit) %></strong>
            — this only <em>requests</em> a change; a different operator must approve it from the Approval Inbox.
          </div>
          <form phx-submit="request_limit_save" phx-target={@myself}>
            <div class="form-grid-2">
              <div class="form-group"><label class="form-label">New Limit *</label>
                <input class="input" type="text" name="action[requested_limit]" required/></div>
              <div class="form-group"><label class="form-label">Reason</label>
                <input class="input" type="text" name="action[reason]"/></div>
            </div>
            <div style="display:flex;gap:8px;margin-top:12px;">
              <button type="submit" class="btn btn-primary">Submit Request</button>
              <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
            </div>
          </form>
        </div>
      <% end %>

      <%= if @active_action == :edit_company do %>
        <div class="action-panel" style="margin-bottom:16px;">
          <div class="action-panel-title">
            <span>✏️ Edit Company</span>
            <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
          </div>
          <form phx-submit="edit_company_save" phx-target={@myself}>
            <div class="form-grid-2">
              <div class="form-group"><label class="form-label">Company Name</label>
                <input class="input" type="text" name="company[company_name]" value={@company.company_name}/></div>
              <div class="form-group"><label class="form-label">Registration No.</label>
                <input class="input" type="text" name="company[registration_no]" value={@company.registration_no}/></div>
              <div class="form-group"><label class="form-label">Tax ID</label>
                <input class="input" type="text" name="company[tax_id]" value={@company.tax_id}/></div>
              <div class="form-group"><label class="form-label">Industry Code</label>
                <input class="input" type="text" name="company[industry_code]" value={@company.industry_code}/></div>
              <div class="form-group"><label class="form-label">Relationship Manager</label>
                <input class="input" type="text" name="company[relationship_manager]" value={@company.relationship_manager}/></div>
              <div class="form-group"><label class="form-label">Billing Cycle Day</label>
                <input class="input" type="text" name="company[billing_cycle_day]" value={@company.billing_cycle_day}/></div>
              <div class="form-group"><label class="form-label">Max Employee Cards</label>
                <input class="input" type="text" name="company[max_employee_cards]" value={@company.max_employee_cards}/></div>
              <div class="form-group"><label class="form-label">Status</label>
                <select class="input" name="company[status]">
                  <option value="ACTIVE" selected={@company.status == "ACTIVE"}>ACTIVE</option>
                  <option value="SUSPENDED" selected={@company.status == "SUSPENDED"}>SUSPENDED</option>
                  <option value="CLOSED" selected={@company.status == "CLOSED"}>CLOSED</option>
                </select></div>
            </div>
            <div style="display:flex;gap:8px;margin-top:12px;">
              <button type="submit" class="btn btn-primary">Save</button>
              <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
            </div>
          </form>
        </div>
      <% end %>

      <div class="table-wrap">
        <table class="data-table">
          <tbody>
            <tr><td>Liability Model</td><td><%= @company.liability_model %></td></tr>
            <tr><td>Facility Limit</td><td class="mono"><%= money(@company.credit_limit) %></td></tr>
            <tr><td>Available</td><td class="mono"><%= money(@company.available_limit) %></td></tr>
            <tr><td>Billing Cycle Day</td><td><%= @company.billing_cycle_day %></td></tr>
            <tr><td>Max Employee Cards</td><td><%= @company.max_employee_cards %></td></tr>
            <tr><td>Relationship Manager</td><td><%= @company.relationship_manager || "—" %></td></tr>
            <tr><td>Status</td><td><span class={"badge #{status_cls(@company.status)}"}><%= @company.status %></span></td></tr>
          </tbody>
        </table>
      </div>

      <div class="form-pane-section-title" style="margin-top:20px;">
        Pending Facility Limit Requests (<%= length(@pending_limit_changes) %>)
      </div>
      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>Requested</th><th>Current → Requested</th><th>Reason</th><th>By</th></tr></thead>
          <tbody>
            <%= if @pending_limit_changes == [] do %>
              <tr><td colspan="4" class="empty-row" style="text-align:center;">None pending.</td></tr>
            <% end %>
            <%= for c <- @pending_limit_changes do %>
              <tr>
                <td><%= Calendar.strftime(c.inserted_at, "%Y-%m-%d %H:%M") %></td>
                <td><%= c.current_limit %> → <%= c.requested_limit %></td>
                <td><%= c.reason %></td>
                <td><code><%= c.requested_by %></code></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
      <p class="text-muted" style="font-size:0.8em;">Approve/reject from the Approval Inbox.</p>

      <div class="form-pane-section-title" style="margin-top:20px;">
        Employee Cards (<%= length(@employee_cards) %>)
      </div>
      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>Name</th><th>Dept</th><th>Individual Limit</th><th>Daily Spend</th><th>Cash?</th><th>Status</th></tr></thead>
          <tbody>
            <%= if @employee_cards == [] do %>
              <tr><td colspan="6" class="empty-row" style="text-align:center;">No employee cards issued.</td></tr>
            <% end %>
            <%= for e <- @employee_cards do %>
              <tr>
                <td><%= e.employee_name %></td>
                <td><%= e.department || "—" %></td>
                <td class="mono"><%= money(e.individual_limit) %></td>
                <td class="mono"><%= money(e.daily_spend || Decimal.new(0)) %></td>
                <td><%= if e.can_withdraw_cash, do: "Yes", else: "No" %></td>
                <td><span class={"badge #{status_cls(e.status)}"}><%= e.status %></span></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <div class="form-pane-section-title" style="margin-top:20px;">
        Spending Controls (<%= length(@spending_controls) %>)
      </div>
      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>Scope</th><th>Type</th><th>Detail</th><th>Status</th></tr></thead>
          <tbody>
            <%= if @spending_controls == [] do %>
              <tr><td colspan="4" class="empty-row" style="text-align:center;">No spending controls configured.</td></tr>
            <% end %>
            <%= for s <- @spending_controls do %>
              <tr>
                <td><%= s.scope %></td>
                <td><%= s.control_type %></td>
                <td>
                  <%= cond do %>
                    <% s.control_type in ["MCC_BLOCK", "MCC_ALLOW"] -> %><%= Enum.join(s.mcc_codes || [], ", ") %>
                    <% s.control_type == "CHANNEL_BLOCK" -> %><%= Enum.join(s.channels || [], ", ") %>
                    <% s.control_type == "TXN_CAP" -> %><%= money(s.per_txn_cap) %>
                    <% s.control_type == "DAILY_CAP" -> %><%= money(s.daily_cap) %>
                    <% true -> %>—
                  <% end %>
                </td>
                <td><span class={"badge #{status_cls(s.status)}"}><%= s.status %></span></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <div class="form-pane-section-title" style="display:flex;justify-content:space-between;align-items:center;margin-top:20px;">
        <span>Fleet Vehicles (<%= length(@vehicles) %>)</span>
        <button :if={@can_edit} class="btn btn-sm btn-primary" phx-click="open_action" phx-value-a="add_vehicle" phx-target={@myself}>+ Add Vehicle</button>
      </div>

      <%= if @active_action == :add_vehicle do %>
        <div class="action-panel" style="margin-bottom:16px;">
          <div class="action-panel-title">
            <span>🚚 New Vehicle</span>
            <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
          </div>
          <form phx-submit="add_vehicle_save" phx-target={@myself}>
            <div class="form-grid-2">
              <div class="form-group"><label class="form-label">Plate Number *</label>
                <input class="input" type="text" name="vehicle[plate_number]" required/></div>
              <div class="form-group"><label class="form-label">VIN</label>
                <input class="input" type="text" name="vehicle[vin]" maxlength="17"/></div>
              <div class="form-group"><label class="form-label">Make</label>
                <input class="input" type="text" name="vehicle[make]"/></div>
              <div class="form-group"><label class="form-label">Model</label>
                <input class="input" type="text" name="vehicle[model]"/></div>
              <div class="form-group"><label class="form-label">Year</label>
                <input class="input" type="text" name="vehicle[year]"/></div>
            </div>
            <div style="display:flex;gap:8px;margin-top:12px;">
              <button type="submit" class="btn btn-primary">Add Vehicle</button>
              <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
            </div>
          </form>
        </div>
      <% end %>

      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>Plate</th><th>VIN</th><th>Make/Model</th><th>Current Driver</th><th>Fleet Card</th><th>Status</th><th></th></tr></thead>
          <tbody>
            <%= if @vehicles == [] do %>
              <tr><td colspan="7" class="empty-row" style="text-align:center;">No vehicles registered.</td></tr>
            <% end %>
            <%= for v <- @vehicles do %>
              <tr>
                <td class="mono"><%= v.plate_number %></td>
                <td class="mono"><%= v.vin || "—" %></td>
                <td><%= [v.make, v.model] |> Enum.reject(&is_nil/1) |> Enum.join(" ") %></td>
                <td><%= v.current_driver || "—" %></td>
                <td><%= if v.has_card, do: "Issued", else: "None" %></td>
                <td><span class={"badge #{status_cls(v.status)}"}><%= v.status %></span></td>
                <td><button class="btn btn-xs" phx-click="view_vehicle" phx-value-id={v.id} phx-target={@myself}>View</button></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <div class="form-pane-section-title" style="display:flex;justify-content:space-between;align-items:center;margin-top:20px;">
        <span>Fleet Spend Report</span>
        <button class="btn btn-sm" phx-click="open_action" phx-value-a="fleet_report" phx-target={@myself}>Run Report</button>
      </div>

      <%= if @active_action == :fleet_report do %>
        <div class="action-panel" style="margin-bottom:16px;">
          <div class="action-panel-title">
            <span>📊 Fleet Spend Report</span>
            <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
          </div>
          <form phx-submit="generate_report_save" phx-target={@myself}>
            <div class="form-grid-2">
              <div class="form-group"><label class="form-label">Period From *</label>
                <input class="input" type="date" name="report[period_from]" required/></div>
              <div class="form-group"><label class="form-label">Period To *</label>
                <input class="input" type="date" name="report[period_to]" required/></div>
              <div class="form-group"><label class="form-label">Group By</label>
                <select class="input" name="report[kind]">
                  <option value="vehicle">Vehicle</option>
                  <option value="driver">Driver (current assignment only)</option>
                </select></div>
            </div>
            <div style="display:flex;gap:8px;margin-top:12px;">
              <button type="submit" class="btn btn-primary">Generate</button>
            </div>
          </form>
        </div>
      <% end %>

      <div :if={@report_rows != []} class="table-wrap">
        <p class="text-muted" style="font-size:0.8em;">
          <%= @report_period_from %> → <%= @report_period_to %> · grouped by <%= @report_kind %>
          <%= if @report_kind == :driver do %>(spend by driver uses each vehicle's <em>current</em> assignment only — not split across mid-period reassignment)<% end %>
        </p>
        <table class="data-table">
          <thead>
            <tr>
              <th :if={@report_kind == :vehicle}>Vehicle</th>
              <th :if={@report_kind == :driver}>Driver</th>
              <th :if={@report_kind == :driver}>Vehicles</th>
              <th>Spend</th>
            </tr>
          </thead>
          <tbody>
            <%= for row <- @report_rows do %>
              <tr>
                <td :if={@report_kind == :vehicle} class="mono"><%= row.plate_number %></td>
                <td :if={@report_kind == :driver}><%= row.driver_name %></td>
                <td :if={@report_kind == :driver}><%= row.vehicles %></td>
                <td class="mono"><%= money(row.spend) %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  def render(%{mode: :vehicle_detail} = assigns) do
    ~H"""
    <div class="component-panel">
      <.page_header title={"#{@selected_vehicle.plate_number} — #{@company.company_name}"} subtitle="Vehicle detail">
        <:actions>
          <button class="btn-sm" phx-click="back_to_company" phx-target={@myself}>← Back to company</button>
        </:actions>
      </.page_header>

      <%= if @notice do %><.alert kind={@notice_kind} message={@notice} /><% end %>

      <div class="table-wrap">
        <table class="data-table">
          <tbody>
            <tr><td>Plate Number</td><td class="mono"><%= @selected_vehicle.plate_number %></td></tr>
            <tr><td>VIN</td><td class="mono"><%= @selected_vehicle.vin || "—" %></td></tr>
            <tr><td>Make / Model / Year</td><td><%= [@selected_vehicle.make, @selected_vehicle.model, @selected_vehicle.year] |> Enum.reject(&is_nil/1) |> Enum.join(" ") %></td></tr>
            <tr><td>Status</td><td><span class={"badge #{status_cls(@selected_vehicle.status)}"}><%= @selected_vehicle.status %></span></td></tr>
          </tbody>
        </table>
      </div>

      <div class="form-pane-section-title" style="display:flex;justify-content:space-between;align-items:center;margin-top:20px;">
        <span>Fleet Card</span>
        <button :if={@can_edit and is_nil(@selected_vehicle_card)} class="btn btn-sm btn-primary" phx-click="open_action" phx-value-a="issue_fleet_card" phx-target={@myself}>+ Issue Fleet Card</button>
      </div>

      <%= if @active_action == :issue_fleet_card do %>
        <div class="action-panel" style="margin-bottom:16px;">
          <div class="action-panel-title">
            <span>💳 Issue Fleet Card</span>
            <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
          </div>
          <form phx-submit="issue_fleet_card_save" phx-target={@myself}>
            <div class="form-grid-2">
              <div class="form-group"><label class="form-label">Individual Limit *</label>
                <input class="input" type="text" name="card[individual_limit]" placeholder="5000.00" required/></div>
              <div class="form-group"><label class="form-label">Monthly Spend Cap</label>
                <input class="input" type="text" name="card[monthly_spend_cap]"/></div>
              <div class="form-group"><label class="form-label">Cash Withdrawal</label>
                <select class="input" name="card[can_withdraw_cash]">
                  <option value="false" selected>No (recommended for fuel cards)</option>
                  <option value="true">Yes</option>
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
          <tbody>
            <%= if @selected_vehicle_card do %>
              <tr><td>Individual Limit</td><td class="mono"><%= money(@selected_vehicle_card.individual_limit) %></td></tr>
              <tr><td>Available</td><td class="mono"><%= money(@selected_vehicle_card.available_individual) %></td></tr>
              <tr><td>Daily Spend</td><td class="mono"><%= money(@selected_vehicle_card.daily_spend || Decimal.new(0)) %></td></tr>
              <tr><td>Cash Withdrawal</td><td><%= if @selected_vehicle_card.can_withdraw_cash, do: "Yes", else: "No" %></td></tr>
              <tr><td>Status</td><td><span class={"badge #{status_cls(@selected_vehicle_card.status)}"}><%= @selected_vehicle_card.status %></span></td></tr>
            <% else %>
              <tr><td colspan="2" class="empty-row" style="text-align:center;">No fleet card issued for this vehicle yet.</td></tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <div class="form-pane-section-title" style="display:flex;justify-content:space-between;align-items:center;margin-top:20px;">
        <span>Driver Assignment</span>
        <div :if={@can_edit} style="display:flex;gap:8px;">
          <button class="btn btn-sm btn-primary" phx-click="open_action" phx-value-a="assign_driver" phx-target={@myself}>Assign Driver</button>
          <button :if={@selected_vehicle_history != [] and Enum.at(@selected_vehicle_history, 0) && is_nil(Enum.at(@selected_vehicle_history, 0).unassigned_at)}
                  class="btn btn-sm" phx-click="unassign_driver" phx-target={@myself}>Unassign Current</button>
        </div>
      </div>

      <%= if @active_action == :assign_driver do %>
        <div class="action-panel" style="margin-bottom:16px;">
          <div class="action-panel-title">
            <span>🧑 Assign Driver</span>
            <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
          </div>
          <div style="font-size:12px;color:var(--text-secondary);margin-bottom:14px;">
            Assigning a new driver automatically closes out the currently active assignment, if any.
          </div>
          <form phx-submit="assign_driver_save" phx-target={@myself}>
            <div class="form-grid-2">
              <div class="form-group"><label class="form-label">Driver Name *</label>
                <input class="input" type="text" name="driver[driver_name]" required/></div>
              <div class="form-group"><label class="form-label">License No.</label>
                <input class="input" type="text" name="driver[driver_license_no]"/></div>
            </div>
            <div style="display:flex;gap:8px;margin-top:12px;">
              <button type="submit" class="btn btn-primary">Assign</button>
              <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
            </div>
          </form>
        </div>
      <% end %>

      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>Driver</th><th>License</th><th>Assigned</th><th>Unassigned</th></tr></thead>
          <tbody>
            <%= if @selected_vehicle_history == [] do %>
              <tr><td colspan="4" class="empty-row" style="text-align:center;">No assignment history.</td></tr>
            <% end %>
            <%= for a <- @selected_vehicle_history do %>
              <tr>
                <td><%= a.driver_name %></td>
                <td><%= a.driver_license_no || "—" %></td>
                <td><%= Calendar.strftime(a.assigned_at, "%Y-%m-%d %H:%M") %></td>
                <td><%= if a.unassigned_at, do: Calendar.strftime(a.unassigned_at, "%Y-%m-%d %H:%M"), else: "— (current)" %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
