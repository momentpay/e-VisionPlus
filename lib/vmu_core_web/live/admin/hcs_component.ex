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
                 HCS.FleetReport, HCS.EmployeeCardCommand,
                 CMS.Account, CMS.BlockCodeHistory, CMS.NonMonetaryEvent,
                 CTA.CardLifecycle, CTA.Cards, Shared.Customer}
  alias VmuCore.ASM.Authz
  alias Decimal, as: D

  @default_operator_id "00000000-0000-0000-0000-000000000001"

  @block_codes [
    {"L — Lost Card",        "L"},
    {"S — Stolen Card",      "S"},
    {"F — Fraud Suspicion",  "F"},
    {"C — Collections Hold", "C"}
  ]

  @block_reason_codes [
    {"Cardholder reported card lost",          "REPORTED_LOST"},
    {"Cardholder reported card stolen",        "REPORTED_STOLEN"},
    {"Fraud team flagged suspicious activity", "FRAUD_ALERT"},
    {"Account moved to collections queue",     "COLLECTIONS_HOLD"},
    {"Cardholder requested temporary block",   "CUSTOMER_REQUEST"},
    {"Applied by automated EOD batch",         "EOD_AUTOMATED"}
  ]

  @unblock_reason_codes [
    {"Investigation completed, block lifted", "INVESTIGATION_CLOSED"},
    {"Manual override by supervisor",         "SUPERVISOR_OVERRIDE"},
    {"Cardholder requested unblock",          "CUSTOMER_REQUEST"}
  ]

  @operator_roles [{"Agent", "AGENT"}, {"Supervisor", "SUPERVISOR"}, {"System", "SYSTEM"}]
  @tri_state [{"Inherit", ""}, {"Enabled", "true"}, {"Disabled", "false"}]

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
       loaded_deep_link_id: nil,
       embedded: false,
       # Card Products UX Parity Phase 3 (2026-07-28) — Employee Card
       # detail view + wizard, the first admin UI Employee Cards have
       # ever had (previously a read-only table row only).
       selected_employee: nil,
       selected_employee_account: nil,
       selected_employee_customer: nil,
       employee_cards_issued: [],
       employee_block_history: [],
       employee_nonmon_events: [],
       employee_channels_card_id: nil,
       employee_detail_tab: 1,
       emp_wizard_step: 1,
       emp_form_data: %{},
       emp_customer_search: "",
       emp_customer_results: [],
       block_codes: @block_codes,
       block_reason_codes: @block_reason_codes,
       unblock_reason_codes: @unblock_reason_codes,
       operator_roles: @operator_roles,
       tri_state: @tri_state
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
  # Employee Card wizard (Card Products UX Parity Phase 3, 2026-07-28) —
  # the first create/manage UI Employee Cards have ever had. Same
  # Customer / Product-details / Review shape as Debit/Prepaid's wizard,
  # except step 1 also allows creating a brand-new individual employee
  # customer inline (unlike Debit/Prepaid, a company's named employees
  # usually don't already have a CIF record to search for).
  # ---------------------------------------------------------------------------

  def handle_event("emp_wizard_new", _params, socket) do
    company = socket.assigns.company
    parent_account = Repo.get!(Account, company.parent_account_id)

    {:noreply, assign(socket,
      mode: :employee_wizard, emp_wizard_step: 1,
      emp_form_data: %{
        "sys_id" => parent_account.sys_id, "bank_id" => parent_account.bank_id,
        "logo_id" => parent_account.logo_id, "block_id" => parent_account.block_id
      },
      emp_customer_search: "", emp_customer_results: [], notice: nil
    )}
  end

  def handle_event("emp_cust_search_wizard", %{"value" => q}, socket) do
    results =
      if String.length(q || "") >= 2 do
        term = "%#{q}%"
        Repo.all(
          from c in Customer,
            where: ilike(c.first_name, ^term) or ilike(c.last_name, ^term) or
                   ilike(fragment("? || ' ' || ?", c.first_name, c.last_name), ^term) or
                   ilike(c.email, ^term) or ilike(c.mobile_number, ^term),
            limit: 10
        )
      else
        []
      end
    {:noreply, assign(socket, emp_customer_search: q, emp_customer_results: results)}
  end

  def handle_event("emp_select_customer", %{"id" => cust_id}, socket) do
    case Repo.get(Customer, cust_id) do
      nil -> {:noreply, socket}
      cust ->
        fd = Map.merge(socket.assigns.emp_form_data, %{
          "customer_id" => to_string(cust.customer_id),
          "customer_name" => "#{cust.first_name} #{cust.last_name}",
          "employee_name" => "#{cust.first_name} #{cust.last_name}"
        })
        {:noreply, assign(socket, emp_form_data: fd, emp_customer_search: "", emp_customer_results: [], emp_wizard_step: 2)}
    end
  end

  def handle_event("emp_new_customer_save", %{"cust" => params}, socket) do
    fd = socket.assigns.emp_form_data

    case %Customer{}
         |> Customer.changeset(%{
           sys_id: fd["sys_id"], bank_id: fd["bank_id"],
           first_name: params["first_name"], last_name: params["last_name"],
           email: blank_to_nil(params["email"]), mobile_number: blank_to_nil(params["mobile_number"]),
           customer_tier: "RETAIL"
         })
         |> Repo.insert() do
      {:ok, cust} ->
        fd2 = Map.merge(fd, %{
          "customer_id" => to_string(cust.customer_id),
          "customer_name" => "#{cust.first_name} #{cust.last_name}",
          "employee_name" => "#{cust.first_name} #{cust.last_name}"
        })
        {:noreply, assign(socket, emp_form_data: fd2, emp_wizard_step: 2)}

      {:error, changeset} ->
        {:noreply, assign(socket, notice: "Could not create employee record — #{inspect(changeset.errors)}", notice_kind: :error)}
    end
  end

  def handle_event("emp_wizard_step", %{"s" => s}, socket) do
    {:noreply, assign(socket, emp_wizard_step: String.to_integer(s))}
  end

  def handle_event("emp_wizard_change", %{"card" => params}, socket) do
    {:noreply, assign(socket, emp_form_data: Map.merge(socket.assigns.emp_form_data, params))}
  end

  def handle_event("emp_wizard_save", _params, socket) do
    if socket.assigns.can_edit do
      fd = socket.assigns.emp_form_data
      limit = parse_decimal(fd["individual_limit"])

      cond do
        is_nil(fd["customer_id"]) ->
          {:noreply, assign(socket, notice: "Select or create an employee first.", notice_kind: :error)}

        is_nil(limit) or D.compare(limit, D.new(0)) != :gt ->
          {:noreply, assign(socket, notice: "Individual limit must be a positive number.", notice_kind: :error)}

        true ->
          employee_attrs = %{
            customer_id: fd["customer_id"], sys_id: fd["sys_id"], bank_id: fd["bank_id"],
            logo_id: fd["logo_id"], block_id: fd["block_id"] || "DFLT",
            # Stub PAN — same convention AccountComponent's own wizard
            # uses (see synthetic_pan_token/0). Real card issuance is a
            # separate "+ Issue Card" action once the sub-account exists,
            # not baked into account creation.
            pan_token: synthetic_pan_token(), last_four: "0000", expiry_date: "0000"
          }

          card_attrs = %{
            employee_name: fd["employee_name"], employee_id: blank_to_nil(fd["employee_id"]),
            department: blank_to_nil(fd["department"]), cost_centre: blank_to_nil(fd["cost_centre"]),
            individual_limit: limit, card_type: fd["card_type"] || "STANDARD",
            can_withdraw_cash: fd["can_withdraw_cash"] == "true",
            monthly_spend_cap: parse_decimal(fd["monthly_spend_cap"])
          }

          case CompanyOnboarding.add_employee_card(socket.assigns.company.id, employee_attrs, card_attrs) do
            {:ok, %{employee_card: card}} ->
              {:noreply, socket
                          |> load_detail(socket.assigns.company.id)
                          |> then(&load_employee_detail(&1, card.id))
                          |> assign(employee_detail_tab: 1, notice: "Employee card issued for #{fd["employee_name"]}.", notice_kind: :success)}

            {:error, :max_employee_cards_reached} ->
              {:noreply, assign(socket, notice: "This company has reached its maximum employee card count.", notice_kind: :error)}

            {:error, :individual_limit_exceeds_company_pool} ->
              {:noreply, assign(socket, notice: "Individual limit exceeds the company remaining facility pool.", notice_kind: :error)}

            {:error, reason} ->
              {:noreply, assign(socket, notice: "Create failed — #{inspect(reason)}", notice_kind: :error)}
          end
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot issue employee cards.", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Employee Card detail view (Card Products UX Parity Phase 3, 2026-07-28)
  # ---------------------------------------------------------------------------

  def handle_event("view_employee", %{"id" => id}, socket) do
    {:noreply, socket |> assign(employee_detail_tab: 1) |> load_employee_detail(id)}
  end

  def handle_event("back_to_company_from_employee", _, socket) do
    {:noreply, load_detail(socket, socket.assigns.company.id)}
  end

  def handle_event("employee_detail_tab", %{"t" => t}, socket) do
    {:noreply, assign(socket, employee_detail_tab: String.to_integer(t), active_action: :none)}
  end

  def handle_event("emp_block_save", %{"action" => params}, socket) do
    card = socket.assigns.selected_employee
    op_id = normalize_uuid(params["operator_id"])

    case EmployeeCardCommand.apply_block(
      card, params["block_code"], params["reason_code"], params["reason_text"] || "",
      op_id, params["operator_role"] || "AGENT", current_operator: socket.assigns.current_operator
    ) do
      {:ok, updated_card} ->
        {:noreply, socket
                    |> load_employee_detail(updated_card.id)
                    |> assign(active_action: :none, notice: "Block code #{params["block_code"]} applied.", notice_kind: :success)}

      {:error, cs} ->
        {:noreply, assign(socket, notice: "Block failed — #{cs_error_msg(cs)}", notice_kind: :error)}
    end
  end

  def handle_event("emp_unblock_save", %{"action" => params}, socket) do
    card = socket.assigns.selected_employee
    op_id = normalize_uuid(params["operator_id"])

    case EmployeeCardCommand.remove_block(
      card, params["reason_code"], params["reason_text"] || "",
      op_id, params["operator_role"] || "AGENT", current_operator: socket.assigns.current_operator
    ) do
      {:ok, updated_card} ->
        {:noreply, socket
                    |> load_employee_detail(updated_card.id)
                    |> assign(active_action: :none, notice: "Block removed.", notice_kind: :success)}

      {:error, cs} ->
        {:noreply, assign(socket, notice: "Unblock failed — #{cs_error_msg(cs)}", notice_kind: :error)}
    end
  end

  def handle_event("emp_nonmon_save", %{"action" => params}, socket) do
    card = socket.assigns.selected_employee
    etype = params["event_type"]
    op_id = normalize_uuid(params["operator_id"])
    {old_val, new_val} = build_nonmon_values(etype, params, socket.assigns)

    case NonMonetaryEvent.record(
      account_id: card.employee_account_id, event_type: etype,
      old_value: old_val, new_value: new_val,
      reason: params["reason"] || "", reference_id: params["reference_id"],
      operator_id: op_id, operator_role: params["operator_role"] || "AGENT"
    ) do
      {:ok, _event} ->
        apply_nonmon_change(etype, params, socket.assigns)
        {:noreply, socket
                    |> load_employee_detail(card.id)
                    |> assign(active_action: :none, notice: "#{etype_label(etype)} recorded.", notice_kind: :success)}

      {:error, cs} ->
        {:noreply, assign(socket, notice: "Event failed — #{cs_error_msg(cs)}", notice_kind: :error)}
    end
  end

  def handle_event("emp_limits_save", %{"action" => params}, socket) do
    card = socket.assigns.selected_employee
    op_id = normalize_uuid(params["operator_id"])
    new_limit = parse_decimal(params["individual_limit"])
    new_cap = parse_decimal(params["monthly_spend_cap"])

    cond do
      is_nil(new_limit) or D.compare(new_limit, D.new(0)) != :gt ->
        {:noreply, assign(socket, notice: "Individual limit must be a positive number.", notice_kind: :error)}

      true ->
        case EmployeeCardCommand.change_limit(card, new_limit, new_cap, op_id) do
          {:ok, updated_card} ->
            {:noreply, socket
                        |> load_employee_detail(updated_card.id)
                        |> assign(active_action: :none, notice: "Limits updated.", notice_kind: :success)}

          {:error, :individual_limit_exceeds_company_pool} ->
            {:noreply, assign(socket, notice: "New limit exceeds the company remaining facility pool.", notice_kind: :error)}

          {:error, reason} ->
            {:noreply, assign(socket, notice: "Update failed — #{inspect(reason)}", notice_kind: :error)}
        end
    end
  end

  def handle_event("emp_kyc", %{"status" => status}, socket) do
    customer = socket.assigns.selected_employee_customer

    attrs =
      if status == "VERIFIED",
        do: %{kyc_status: status, kyc_verified_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)},
        else: %{kyc_status: status, kyc_verified_at: nil}

    case customer |> Customer.changeset(attrs) |> Repo.update() do
      {:ok, _updated} ->
        {:noreply, socket
                    |> load_employee_detail(socket.assigns.selected_employee.id)
                    |> assign(notice: "KYC status set to #{status}.", notice_kind: :success)}

      {:error, cs} ->
        {:noreply, assign(socket, notice: "KYC update failed — #{cs_error_msg(cs)}", notice_kind: :error)}
    end
  end

  def handle_event("issue_card_save", %{"card" => params}, socket) do
    if socket.assigns.can_edit do
      card_type = params["card_type"] || "PRIMARY"
      account = socket.assigns.selected_employee_account

      case CardLifecycle.issue_new(account, card_type: card_type) do
        {:ok, _card} ->
          {:noreply, socket
                      |> load_employee_detail(socket.assigns.selected_employee.id)
                      |> assign(active_action: :none, notice: "#{card_type} card issued (INACTIVE).", notice_kind: :success)}

        {:error, reason} ->
          {:noreply, assign(socket, notice: "Card issuance failed — #{inspect(reason)}", notice_kind: :error)}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot issue cards.", notice_kind: :error)}
    end
  end

  def handle_event("card_activate", %{"id" => card_id}, socket) do
    case CardLifecycle.activate(card_id, operator: socket.assigns.current_operator) do
      {:ok, _card} ->
        {:noreply, socket |> load_employee_detail(socket.assigns.selected_employee.id) |> assign(notice: "Card activated.", notice_kind: :success)}

      {:error, reason} ->
        {:noreply, assign(socket, notice: "Activation failed — #{inspect(reason)}", notice_kind: :error)}
    end
  end

  def handle_event("card_block", %{"id" => card_id}, socket) do
    case CardLifecycle.block(card_id, "ADMIN", operator: socket.assigns.current_operator) do
      {:ok, _card} ->
        {:noreply, socket |> load_employee_detail(socket.assigns.selected_employee.id) |> assign(notice: "Card blocked.", notice_kind: :success)}

      {:error, reason} ->
        {:noreply, assign(socket, notice: "Block failed — #{inspect(reason)}", notice_kind: :error)}
    end
  end

  def handle_event("card_unblock", %{"id" => card_id}, socket) do
    case CardLifecycle.unblock(card_id, operator: socket.assigns.current_operator) do
      {:ok, _card} ->
        {:noreply, socket |> load_employee_detail(socket.assigns.selected_employee.id) |> assign(notice: "Card unblocked.", notice_kind: :success)}

      {:error, reason} ->
        {:noreply, assign(socket, notice: "Unblock failed — #{inspect(reason)}", notice_kind: :error)}
    end
  end

  def handle_event("open_channels", %{"id" => card_id}, socket) do
    {:noreply, assign(socket, active_action: :card_channels, employee_channels_card_id: card_id, notice: nil)}
  end

  def handle_event("card_channels_save", params, socket) do
    card_id = socket.assigns.employee_channels_card_id

    controls = %{
      ecom_enabled: tri_parse(params["ecom_enabled"]), atm_enabled: tri_parse(params["atm_enabled"]),
      contactless_enabled: tri_parse(params["contactless_enabled"]), intl_enabled: tri_parse(params["intl_enabled"])
    }

    case CardLifecycle.set_channel_controls(card_id, controls, operator: socket.assigns.current_operator) do
      {:ok, _card} ->
        {:noreply, socket
                    |> load_employee_detail(socket.assigns.selected_employee.id)
                    |> assign(active_action: :none, notice: "Channel controls updated.", notice_kind: :success)}

      {:error, reason} ->
        {:noreply, assign(socket, notice: "Update failed — #{inspect(reason)}", notice_kind: :error)}
    end
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

  # Card Products UX Parity Phase 3 (2026-07-28) — loads an EmployeeCard's
  # full detail: the underlying CMS.Account (block_code/velocity fields),
  # the individual employee's own Shared.Customer (Address/Phone/Email/
  # KYC target — distinct from the company's own synthetic CORPORATE
  # customer), any real CTA.Card issued, and the shared BlockCodeHistory/
  # NonMonetaryEvent audit trails (same cms_accounts FK Credit uses).
  defp load_employee_detail(socket, employee_card_id) do
    card = Repo.get!(EmployeeCard, employee_card_id)
    account = Repo.get!(Account, card.employee_account_id)
    customer = Repo.get(Customer, account.customer_id)
    company = socket.assigns[:company] || Repo.get!(Company, card.company_id)

    assign(socket,
      mode: :employee_detail,
      company: company,
      active_action: :none,
      notice: nil,
      selected_employee: card,
      selected_employee_account: account,
      selected_employee_customer: customer,
      employee_cards_issued: Cards.by_account(account.account_id),
      employee_block_history: BlockCodeHistory.history_for(account.account_id),
      employee_nonmon_events: NonMonetaryEvent.history_for(account.account_id)
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
  defp status_cls("CANCELLED"), do: "badge-gray"
  defp status_cls("BLOCKED"),   do: "badge-red"
  defp status_cls("INACTIVE"),  do: "badge-blue"
  defp status_cls(_),           do: "badge-gray"

  defp kyc_badge_cls("VERIFIED"), do: "badge-green"
  defp kyc_badge_cls("REJECTED"), do: "badge-red"
  defp kyc_badge_cls(_), do: "badge-yellow"

  defp tri_parse("true"), do: true
  defp tri_parse("false"), do: false
  defp tri_parse(_), do: nil

  defp tri_selected(nil, ""), do: true
  defp tri_selected(true, "true"), do: true
  defp tri_selected(false, "false"), do: true
  defp tri_selected(_, _), do: false

  defp normalize_uuid(""), do: @default_operator_id
  defp normalize_uuid(nil), do: @default_operator_id
  defp normalize_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> @default_operator_id
    end
  end

  defp cs_error_msg(cs) do
    Enum.map_join(cs.errors, "; ", fn {f, {m, _}} -> "#{f}: #{m}" end)
  end

  defp etype_label("address_change"), do: "Address change"
  defp etype_label("phone_change"), do: "Phone change"
  defp etype_label("email_change"), do: "Email change"
  defp etype_label(t), do: t

  # ── Non-monetary helpers (Card Products UX Parity Phase 3, 2026-07-28)
  # — same shape as Debit/Prepaid's own copies, targeting the employee's
  # individual Shared.Customer (not the company's synthetic one).
  defp build_nonmon_values("address_change", params, assigns) do
    c = assigns.selected_employee_customer
    old = %{"line1" => c && c.address_line1, "city" => c && c.city, "country" => c && c.country}
    new = %{"line1" => params["new_line1"], "line2" => params["new_line2"],
            "city" => params["new_city"], "postal" => params["new_postal"],
            "country" => params["new_country"]}
    {old, new}
  end
  defp build_nonmon_values("phone_change", params, assigns) do
    c = assigns.selected_employee_customer
    old = %{"mobile_country" => c && c.mobile_country, "mobile_number" => c && c.mobile_number}
    new = %{"mobile_country" => params["new_mobile_country"], "mobile_number" => params["new_mobile_number"]}
    {old, new}
  end
  defp build_nonmon_values("email_change", params, assigns) do
    c = assigns.selected_employee_customer
    {%{"email" => c && c.email}, %{"email" => params["new_email"]}}
  end
  defp build_nonmon_values(_, _, _), do: {nil, nil}

  defp apply_nonmon_change("address_change", params, %{selected_employee_customer: c}) when not is_nil(c) do
    c |> Customer.changeset(%{
      address_line1: params["new_line1"], address_line2: params["new_line2"],
      city: params["new_city"], postal_code: params["new_postal"], country: params["new_country"]
    }) |> Repo.update()
  end
  defp apply_nonmon_change("phone_change", params, %{selected_employee_customer: c}) when not is_nil(c) do
    c |> Customer.changeset(%{
      mobile_country: params["new_mobile_country"], mobile_number: params["new_mobile_number"]
    }) |> Repo.update()
  end
  defp apply_nonmon_change("email_change", params, %{selected_employee_customer: c}) when not is_nil(c) do
    c |> Customer.changeset(%{email: params["new_email"]}) |> Repo.update()
  end
  defp apply_nonmon_change(_, _, _), do: :ok

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(%{mode: :list} = assigns) do
    ~H"""
    <div class="component-panel">
      <%= if not @embedded do %>
        <.page_header title="Corporate Card Programmes (HCS)" subtitle="Company facilities and employee cards">
          <:actions>
            <button :if={@can_edit} class="btn-sm btn-primary" phx-click="open_action" phx-value-a="create_company" phx-target={@myself}>+ New Company</button>
          </:actions>
        </.page_header>
      <% end %>

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
      <%= if @embedded do %>
        <div style="font-size:16px;font-weight:700;margin-bottom:12px;"><%= @company.company_name %> (<%= @company.company_code %>)</div>
      <% else %>
        <.page_header title={"#{@company.company_name} (#{@company.company_code})"} subtitle="Company facility detail">
          <:actions>
            <button class="btn-sm" phx-click="back_to_list" phx-target={@myself}>← Back to list</button>
          </:actions>
        </.page_header>
      <% end %>

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

      <div class="form-pane-section-title" style="display:flex;justify-content:space-between;align-items:center;margin-top:20px;">
        <span>Employee Cards (<%= length(@employee_cards) %>)</span>
        <button :if={@can_edit} class="btn btn-sm btn-primary" phx-click="emp_wizard_new" phx-target={@myself}>+ Add Employee Card</button>
      </div>
      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>Name</th><th>Dept</th><th>Individual Limit</th><th>Daily Spend</th><th>Cash?</th><th>Status</th><th></th></tr></thead>
          <tbody>
            <%= if @employee_cards == [] do %>
              <tr><td colspan="7" class="empty-row" style="text-align:center;">No employee cards issued.</td></tr>
            <% end %>
            <%= for e <- @employee_cards do %>
              <tr>
                <td><%= e.employee_name %></td>
                <td><%= e.department || "—" %></td>
                <td class="mono"><%= money(e.individual_limit) %></td>
                <td class="mono"><%= money(e.daily_spend || Decimal.new(0)) %></td>
                <td><%= if e.can_withdraw_cash, do: "Yes", else: "No" %></td>
                <td><span class={"badge #{status_cls(e.status)}"}><%= e.status %></span></td>
                <td><button class="btn btn-xs" phx-click="view_employee" phx-value-id={e.id} phx-target={@myself}>View</button></td>
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
      <%= if @embedded do %>
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px;">
          <div style="font-size:16px;font-weight:700;"><%= @selected_vehicle.plate_number %> — <%= @company.company_name %></div>
          <button class="btn-sm" phx-click="back_to_company" phx-target={@myself}>← Back to company</button>
        </div>
      <% else %>
        <.page_header title={"#{@selected_vehicle.plate_number} — #{@company.company_name}"} subtitle="Vehicle detail">
          <:actions>
            <button class="btn-sm" phx-click="back_to_company" phx-target={@myself}>← Back to company</button>
          </:actions>
        </.page_header>
      <% end %>

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

  # ---------------------------------------------------------------------------
  # Employee Card wizard (Card Products UX Parity Phase 3, 2026-07-28)
  # ---------------------------------------------------------------------------

  def render(%{mode: :employee_wizard} = assigns) do
    ~H"""
    <div class="component-panel">
      <%= if @embedded do %>
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px;">
          <div style="font-size:16px;font-weight:700;">Add Employee Card — <%= @company.company_name %></div>
          <button class="btn-sm" phx-click="back_to_company_from_employee" phx-target={@myself}>← Back to company</button>
        </div>
      <% else %>
        <.page_header title={"Add Employee Card — #{@company.company_name}"} subtitle="Employee card issuance">
          <:actions>
            <button class="btn-sm" phx-click="back_to_company_from_employee" phx-target={@myself}>← Back to company</button>
          </:actions>
        </.page_header>
      <% end %>

      <%= if @notice do %><.alert kind={@notice_kind} message={@notice} /><% end %>

      <div class="card">
        <div style="font-size:16px;font-weight:700;margin-bottom:20px;">Add Employee Card — Step <%= @emp_wizard_step %> of 3</div>

        <div style="display:flex;gap:4px;margin-bottom:24px;">
          <%= for {s, label} <- [{1, "Employee"}, {2, "Card Details"}, {3, "Review"}] do %>
            <div style={"flex:1;padding:6px 8px;text-align:center;font-size:12px;font-weight:600;border-radius:4px;cursor:pointer;
              background:#{if s <= @emp_wizard_step, do: "var(--accent)", else: "var(--bg-canvas)"};
              color:#{if s <= @emp_wizard_step, do: "#fff", else: "var(--text-secondary)"};"}
              phx-click={if s < @emp_wizard_step, do: "emp_wizard_step"} phx-value-s={s} phx-target={@myself}>
              <%= s %>. <%= label %>
            </div>
          <% end %>
        </div>

        <%= case @emp_wizard_step do %>
          <% 1 -> %> <%= employee_wizard_step1(assigns) %>
          <% 2 -> %> <%= employee_wizard_step2(assigns) %>
          <% 3 -> %> <%= employee_wizard_step3(assigns) %>
          <% _ -> %> <p>Invalid step.</p>
        <% end %>
      </div>
    </div>
    """
  end

  defp employee_wizard_step1(assigns) do
    ~H"""
    <div>
      <div class="form-pane-section-title">Step 1 — Select or Add Employee</div>

      <%= if @emp_form_data["customer_id"] do %>
        <div style="background:#f0fdf4;border:1px solid #bbf7d0;padding:12px 16px;border-radius:8px;margin-bottom:16px;display:flex;justify-content:space-between;align-items:center;">
          <div style="font-weight:600;"><%= @emp_form_data["customer_name"] %></div>
          <button class="btn btn-sm btn-ghost" phx-click="emp_wizard_step" phx-value-s="1" phx-target={@myself}>Change</button>
        </div>
        <div style="display:flex;justify-content:flex-end;">
          <button class="btn btn-primary" phx-click="emp_wizard_step" phx-value-s="2" phx-target={@myself}>
            Next: Card Details →
          </button>
        </div>
      <% else %>
        <div style="margin-bottom:12px;">
          <input type="text" class="input" placeholder="Search existing customers by name, email, or mobile…"
            value={@emp_customer_search} phx-keyup="emp_cust_search_wizard" phx-debounce="300"
            phx-target={@myself} style="width:100%;max-width:480px;"/>
        </div>

        <%= if @emp_customer_results != [] do %>
          <div class="table-wrap">
            <table class="data-table">
              <thead><tr><th>Name</th><th>Email</th><th></th></tr></thead>
              <tbody>
                <%= for c <- @emp_customer_results do %>
                  <tr>
                    <td><%= c.first_name %> <%= c.last_name %></td>
                    <td style="font-size:12px;"><%= c.email %></td>
                    <td><button class="btn btn-sm btn-primary" phx-click="emp_select_customer" phx-value-id={c.customer_id} phx-target={@myself}>Select</button></td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>

        <div class="form-pane-section-title" style="margin-top:20px;">— or add a new employee —</div>
        <form phx-submit="emp_new_customer_save" phx-target={@myself}>
          <div class="form-grid-2">
            <div class="form-group"><label class="form-label">First Name *</label>
              <input class="input" type="text" name="cust[first_name]" required/></div>
            <div class="form-group"><label class="form-label">Last Name *</label>
              <input class="input" type="text" name="cust[last_name]" required/></div>
            <div class="form-group"><label class="form-label">Email</label>
              <input class="input" type="email" name="cust[email]"/></div>
            <div class="form-group"><label class="form-label">Mobile Number</label>
              <input class="input" type="text" name="cust[mobile_number]"/></div>
          </div>
          <div style="display:flex;gap:8px;margin-top:12px;">
            <button type="submit" class="btn btn-primary">Add New Employee</button>
          </div>
        </form>
      <% end %>
    </div>
    """
  end

  defp employee_wizard_step2(assigns) do
    ~H"""
    <div>
      <div class="form-pane-section-title">Step 2 — Card Details</div>
      <form phx-change="emp_wizard_change" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group"><label class="form-label">Employee Name *</label>
            <input class="input" type="text" name="card[employee_name]" value={@emp_form_data["employee_name"]} required/></div>
          <div class="form-group"><label class="form-label">Employee ID</label>
            <input class="input" type="text" name="card[employee_id]" value={@emp_form_data["employee_id"]}/></div>
          <div class="form-group"><label class="form-label">Department</label>
            <input class="input" type="text" name="card[department]" value={@emp_form_data["department"]}/></div>
          <div class="form-group"><label class="form-label">Cost Centre</label>
            <input class="input" type="text" name="card[cost_centre]" value={@emp_form_data["cost_centre"]}/></div>
          <div class="form-group"><label class="form-label">Individual Limit *</label>
            <input class="input" type="text" name="card[individual_limit]" placeholder="5000.00" value={@emp_form_data["individual_limit"]} required/></div>
          <div class="form-group"><label class="form-label">Monthly Spend Cap</label>
            <input class="input" type="text" name="card[monthly_spend_cap]" value={@emp_form_data["monthly_spend_cap"]}/></div>
          <div class="form-group"><label class="form-label">Card Type</label>
            <select class="input" name="card[card_type]">
              <option value="STANDARD" selected={@emp_form_data["card_type"] == "STANDARD"}>Standard</option>
              <option value="TRAVEL" selected={@emp_form_data["card_type"] == "TRAVEL"}>Travel</option>
              <option value="PURCHASING" selected={@emp_form_data["card_type"] == "PURCHASING"}>Purchasing</option>
              <option value="VIRTUAL" selected={@emp_form_data["card_type"] == "VIRTUAL"}>Virtual</option>
            </select></div>
          <div class="form-group"><label class="form-label">Cash Withdrawal</label>
            <select class="input" name="card[can_withdraw_cash]">
              <option value="false" selected={@emp_form_data["can_withdraw_cash"] != "true"}>No</option>
              <option value="true" selected={@emp_form_data["can_withdraw_cash"] == "true"}>Yes</option>
            </select></div>
        </div>
      </form>

      <div style="display:flex;gap:8px;margin-top:20px;">
        <button class="btn btn-secondary" phx-click="emp_wizard_step" phx-value-s="1" phx-target={@myself}>← Back</button>
        <button class="btn btn-primary" phx-click="emp_wizard_step" phx-value-s="3" phx-target={@myself}
          disabled={is_nil(@emp_form_data["employee_name"]) or @emp_form_data["employee_name"] == ""}>
          Next: Review →
        </button>
      </div>
    </div>
    """
  end

  defp employee_wizard_step3(assigns) do
    ~H"""
    <div>
      <div class="form-pane-section-title">Step 3 — Review</div>
      <.kv_detail rows={[
        {"Employee", @emp_form_data["employee_name"]},
        {"Employee ID", @emp_form_data["employee_id"] || "—"},
        {"Department", @emp_form_data["department"] || "—"},
        {"Individual Limit", @emp_form_data["individual_limit"]},
        {"Monthly Spend Cap", @emp_form_data["monthly_spend_cap"] || "—"},
        {"Card Type", @emp_form_data["card_type"] || "STANDARD"},
        {"Cash Withdrawal", if(@emp_form_data["can_withdraw_cash"] == "true", do: "Yes", else: "No")}
      ]}/>
      <div style="display:flex;gap:8px;margin-top:20px;">
        <button class="btn btn-secondary" phx-click="emp_wizard_step" phx-value-s="2" phx-target={@myself}>← Back</button>
        <button class="btn btn-primary" phx-click="emp_wizard_save" phx-target={@myself}>Add Employee Card</button>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Employee Card detail view (Card Products UX Parity Phase 3, 2026-07-28)
  # ---------------------------------------------------------------------------

  def render(%{mode: :employee_detail} = assigns) do
    ~H"""
    <div class="component-panel">
      <%= if @embedded do %>
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px;">
          <div style="font-size:16px;font-weight:700;"><%= @selected_employee.employee_name %> — <%= @company.company_name %></div>
          <button class="btn-sm" phx-click="back_to_company_from_employee" phx-target={@myself}>← Back to company</button>
        </div>
      <% else %>
        <.page_header title={"#{@selected_employee.employee_name} — #{@company.company_name}"} subtitle="Employee card detail">
          <:actions>
            <button class="btn-sm" phx-click="back_to_company_from_employee" phx-target={@myself}>← Back to company</button>
          </:actions>
        </.page_header>
      <% end %>

      <%= if @notice do %><.alert kind={@notice_kind} message={@notice} /><% end %>

      <%!-- Card Products UX Parity Phase 3 (2026-07-28) — account-level
           actions, mirroring Debit/Prepaid's Phase 1e/2d toolbar exactly,
           reusing CMS.BlockCodeHistory/NonMonetaryEvent directly since
           the employee's account_id is a real cms_accounts row (same
           table Credit uses — see EmployeeCardCommand's moduledoc). --%>
      <div class="card" style="margin-bottom:16px;">
        <div style="display:flex;gap:8px;flex-wrap:wrap;">
          <%= if is_nil(@selected_employee_account.block_code) do %>
            <button class="btn btn-sm btn-danger" phx-click="open_action" phx-value-a="apply_block" phx-target={@myself}>🔒 Apply Block</button>
          <% else %>
            <button class="btn btn-sm btn-secondary" phx-click="open_action" phx-value-a="remove_block" phx-target={@myself}>🔓 Remove Block</button>
          <% end %>
          <button class="btn btn-sm btn-secondary" phx-click="open_action" phx-value-a="change_address" phx-target={@myself}>📬 Address Change</button>
          <button class="btn btn-sm btn-secondary" phx-click="open_action" phx-value-a="change_phone" phx-target={@myself}>📱 Phone Change</button>
          <button class="btn btn-sm btn-secondary" phx-click="open_action" phx-value-a="change_email" phx-target={@myself}>✉️ Email Change</button>
          <button class="btn btn-sm btn-secondary" phx-click="open_action" phx-value-a="change_limits" phx-target={@myself}>📊 Change Limits</button>
        </div>
        <div style="display:flex;gap:8px;margin-top:8px;flex-wrap:wrap;padding-top:8px;border-top:1px solid var(--border);">
          <span style="font-size:11px;color:var(--text-muted);align-self:center;font-weight:600;">KYC:</span>
          <%= if @selected_employee_customer && @selected_employee_customer.kyc_status != "VERIFIED" do %>
            <button class="btn btn-sm btn-primary" style="background:var(--success);border-color:var(--success);"
              phx-click="emp_kyc" phx-value-status="VERIFIED" phx-target={@myself}>✓ Verify</button>
          <% end %>
          <%= if @selected_employee_customer && @selected_employee_customer.kyc_status != "REJECTED" do %>
            <button class="btn btn-sm btn-danger" phx-click="emp_kyc" phx-value-status="REJECTED" phx-target={@myself}>✗ Reject</button>
          <% end %>
          <%= if @selected_employee_customer && @selected_employee_customer.kyc_status != "PENDING" do %>
            <button class="btn btn-sm btn-secondary" phx-click="emp_kyc" phx-value-status="PENDING" phx-target={@myself}>↺ Reset to Pending</button>
          <% end %>
          <span :if={@selected_employee_customer} class={"badge #{kyc_badge_cls(@selected_employee_customer.kyc_status)}"} style="margin-left:4px;"><%= @selected_employee_customer.kyc_status %></span>
        </div>
      </div>

      <%= if @active_action in [:apply_block, :remove_block, :change_address, :change_phone, :change_email, :change_limits] do %>
        <%= employee_action_panel(assigns) %>
      <% end %>

      <div class="card" style="padding:0;overflow:hidden;">
        <div class="detail-tabs">
          <%= for {idx, label, icon} <- [{1, "Overview", "📋"}, {2, "Cards", "💳"}, {3, "History", "📜"}] do %>
            <div class={"detail-tab#{if @employee_detail_tab == idx, do: " active"}"}
              phx-click="employee_detail_tab" phx-value-t={idx} phx-target={@myself}>
              <%= icon %> <%= label %>
            </div>
          <% end %>
        </div>
        <div style="padding:20px;">
          <%= case @employee_detail_tab do %>
            <% 1 -> %> <%= employee_tab_overview(assigns) %>
            <% 2 -> %> <%= employee_tab_cards(assigns) %>
            <% 3 -> %> <%= employee_tab_history(assigns) %>
            <% _ -> %> <p>Invalid tab.</p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp employee_action_panel(%{active_action: :apply_block} = assigns) do
    ~H"""
    <div class="action-panel action-panel-danger" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>🔒 Apply Block Code</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <div class="text-sm text-muted" style="margin-bottom:8px;">
        Also suspends the employee card (HCS spend-limit checks gate on
        card status, not just the account block code) and blocks any
        real card issued against it.
      </div>
      <form phx-submit="emp_block_save" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">Block Code *</label>
            <select class="input" name="action[block_code]" required>
              <option value="">— Select —</option>
              <%= for {label, val} <- @block_codes do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Reason Code *</label>
            <select class="input" name="action[reason_code]" required>
              <option value="">— Select —</option>
              <%= for {label, val} <- @block_reason_codes do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Free Text (optional)</label>
            <input type="text" class="input" name="action[reason_text]" maxlength="200"/>
          </div>
          <div class="form-group">
            <label class="form-label">Operator Role</label>
            <select class="input" name="action[operator_role]">
              <%= for {label, val} <- @operator_roles do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group" style="grid-column:1/-1;">
            <label class="form-label">Operator ID (UUID)</label>
            <input type="text" class="input" name="action[operator_id]" placeholder="00000000-0000-0000-0000-000000000001" style="font-family:monospace;"/>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-danger">Apply Block</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp employee_action_panel(%{active_action: :remove_block} = assigns) do
    ~H"""
    <div class="action-panel" style="margin-bottom:16px;border-color:#bbf7d0;background:#f0fdf4;">
      <div class="action-panel-title">
        <span>🔓 Remove Block Code <%= @selected_employee_account.block_code %></span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <form phx-submit="emp_unblock_save" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">Reason Code *</label>
            <select class="input" name="action[reason_code]" required>
              <option value="">— Select —</option>
              <%= for {label, val} <- @unblock_reason_codes do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Operator Role</label>
            <select class="input" name="action[operator_role]">
              <%= for {label, val} <- @operator_roles do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Notes (optional)</label>
            <input type="text" class="input" name="action[reason_text]" maxlength="200"/>
          </div>
          <div class="form-group">
            <label class="form-label">Operator ID (UUID)</label>
            <input type="text" class="input" name="action[operator_id]" placeholder="00000000-0000-0000-0000-000000000001" style="font-family:monospace;"/>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-success">Remove Block</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp employee_action_panel(%{active_action: act} = assigns) when act in [:change_address, :change_phone, :change_email] do
    ~H"""
    <div class="action-panel" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>
          <%= case @active_action do
            :change_address -> "📬 Address Change"
            :change_phone   -> "📱 Phone Change"
            :change_email   -> "✉️ Email Change"
          end %>
        </span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <form phx-submit="emp_nonmon_save" phx-target={@myself}>
        <input type="hidden" name="action[event_type]" value={
          case @active_action do
            :change_address -> "address_change"
            :change_phone   -> "phone_change"
            :change_email   -> "email_change"
          end
        }/>
        <%= if @active_action == :change_address do %>
          <div class="form-grid-2">
            <div class="form-group" style="grid-column:1/-1;">
              <label class="form-label">New Address Line 1 *</label>
              <input type="text" class="input" name="action[new_line1]" required value={@selected_employee_customer && @selected_employee_customer.address_line1}/>
            </div>
            <div class="form-group" style="grid-column:1/-1;">
              <label class="form-label">Address Line 2</label>
              <input type="text" class="input" name="action[new_line2]" value={@selected_employee_customer && @selected_employee_customer.address_line2}/>
            </div>
            <div class="form-group">
              <label class="form-label">City *</label>
              <input type="text" class="input" name="action[new_city]" required value={@selected_employee_customer && @selected_employee_customer.city}/>
            </div>
            <div class="form-group">
              <label class="form-label">Postal Code</label>
              <input type="text" class="input" name="action[new_postal]" value={@selected_employee_customer && @selected_employee_customer.postal_code}/>
            </div>
            <div class="form-group">
              <label class="form-label">Country</label>
              <input type="text" class="input" name="action[new_country]" value={@selected_employee_customer && @selected_employee_customer.country}/>
            </div>
          </div>
        <% end %>
        <%= if @active_action == :change_phone do %>
          <div class="form-grid-2">
            <div class="form-group">
              <label class="form-label">Country Code</label>
              <input type="text" class="input" name="action[new_mobile_country]" value={@selected_employee_customer && @selected_employee_customer.mobile_country} placeholder="971"/>
            </div>
            <div class="form-group">
              <label class="form-label">Mobile Number *</label>
              <input type="text" class="input" name="action[new_mobile_number]" required value={@selected_employee_customer && @selected_employee_customer.mobile_number}/>
            </div>
          </div>
        <% end %>
        <%= if @active_action == :change_email do %>
          <div class="form-group">
            <label class="form-label">New Email Address *</label>
            <input type="email" class="input" name="action[new_email]" required value={@selected_employee_customer && @selected_employee_customer.email}/>
          </div>
        <% end %>
        <div class="form-grid-2" style="margin-top:12px;">
          <div class="form-group">
            <label class="form-label">Reason / Notes</label>
            <input type="text" class="input" name="action[reason]" placeholder="Reason…"/>
          </div>
          <div class="form-group">
            <label class="form-label">Reference ID</label>
            <input type="text" class="input" name="action[reference_id]" maxlength="50"/>
          </div>
          <div class="form-group">
            <label class="form-label">Operator ID (UUID)</label>
            <input type="text" class="input" name="action[operator_id]" placeholder="00000000-0000-0000-0000-000000000001" style="font-family:monospace;"/>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-primary">Save Change</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp employee_action_panel(%{active_action: :change_limits} = assigns) do
    ~H"""
    <div class="action-panel" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>📊 Change Limits</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <div class="text-sm text-muted" style="margin-bottom:8px;">
        Updates the employee's real, enforced spend limits (`HCS.LimitController`
        checks these directly) — re-validated against the company's
        remaining facility pool, same math as issuing a new card.
      </div>
      <form phx-submit="emp_limits_save" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">Individual Limit *</label>
            <input type="text" class="input" name="action[individual_limit]" value={@selected_employee.individual_limit} required/>
          </div>
          <div class="form-group">
            <label class="form-label">Monthly Spend Cap</label>
            <input type="text" class="input" name="action[monthly_spend_cap]" value={@selected_employee.monthly_spend_cap}/>
          </div>
          <div class="form-group" style="grid-column:1/-1;">
            <label class="form-label">Operator ID (UUID)</label>
            <input type="text" class="input" name="action[operator_id]" placeholder="00000000-0000-0000-0000-000000000001" style="font-family:monospace;"/>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-primary">Save Limits</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp employee_tab_overview(assigns) do
    ~H"""
    <div class="table-wrap">
      <table class="data-table">
        <tbody>
          <tr><td>Employee</td><td><%= @selected_employee.employee_name %></td></tr>
          <tr><td>Employee ID</td><td><%= @selected_employee.employee_id || "—" %></td></tr>
          <tr><td>Department</td><td><%= @selected_employee.department || "—" %></td></tr>
          <tr><td>Cost Centre</td><td><%= @selected_employee.cost_centre || "—" %></td></tr>
          <tr><td>Individual Limit</td><td class="mono"><%= money(@selected_employee.individual_limit) %></td></tr>
          <tr><td>Available</td><td class="mono"><%= money(@selected_employee.available_individual) %></td></tr>
          <tr><td>Monthly Spend Cap</td><td class="mono"><%= money(@selected_employee.monthly_spend_cap) %></td></tr>
          <tr><td>Daily Spend</td><td class="mono"><%= money(@selected_employee.daily_spend || Decimal.new(0)) %></td></tr>
          <tr><td>Cash Withdrawal</td><td><%= if @selected_employee.can_withdraw_cash, do: "Yes", else: "No" %></td></tr>
          <tr><td>Status</td><td><span class={"badge #{status_cls(@selected_employee.status)}"}><%= @selected_employee.status %></span></td></tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp employee_tab_cards(assigns) do
    ~H"""
    <div class="form-pane-section-title" style="display:flex;justify-content:space-between;align-items:center;">
      <span>Cards (<%= length(@employee_cards_issued) %>)</span>
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
                <option value="SUPPLEMENTARY">Supplementary</option>
              </select></div>
          </div>
          <div style="display:flex;gap:8px;margin-top:12px;">
            <button type="submit" class="btn btn-primary">Issue Card</button>
            <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
          </div>
        </form>
      </div>
    <% end %>

    <%= if @active_action == :card_channels do %>
      <% channels_card = Enum.find(@employee_cards_issued, &(&1.card_id == @employee_channels_card_id)) %>
      <% assigns = assign(assigns, :channels_card, channels_card) %>
      <div class="action-panel" style="margin-bottom:16px;">
        <div class="action-panel-title">
          <span>📶 Channel Controls — **** <%= @channels_card && @channels_card.last_four %></span>
          <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
        </div>
        <div class="form-hint" style="margin-bottom:10px;">
          Overrides the product's channel defaults for this card only. "Inherit" restores normal product behavior.
        </div>
        <form phx-submit="card_channels_save" phx-target={@myself}>
          <div class="form-grid-2">
            <div class="form-group">
              <label class="form-label">E-Commerce</label>
              <select class="input" name="ecom_enabled">
                <%= for {label, val} <- @tri_state do %>
                  <option value={val} selected={tri_selected(@channels_card && @channels_card.ecom_enabled, val)}><%= label %></option>
                <% end %>
              </select>
            </div>
            <div class="form-group">
              <label class="form-label">ATM</label>
              <select class="input" name="atm_enabled">
                <%= for {label, val} <- @tri_state do %>
                  <option value={val} selected={tri_selected(@channels_card && @channels_card.atm_enabled, val)}><%= label %></option>
                <% end %>
              </select>
            </div>
            <div class="form-group">
              <label class="form-label">Contactless</label>
              <select class="input" name="contactless_enabled">
                <%= for {label, val} <- @tri_state do %>
                  <option value={val} selected={tri_selected(@channels_card && @channels_card.contactless_enabled, val)}><%= label %></option>
                <% end %>
              </select>
            </div>
            <div class="form-group">
              <label class="form-label">International</label>
              <select class="input" name="intl_enabled">
                <%= for {label, val} <- @tri_state do %>
                  <option value={val} selected={tri_selected(@channels_card && @channels_card.intl_enabled, val)}><%= label %></option>
                <% end %>
              </select>
            </div>
          </div>
          <div style="display:flex;gap:8px;margin-top:12px;">
            <button type="submit" class="btn btn-primary">Save Controls</button>
            <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
          </div>
        </form>
      </div>
    <% end %>

    <div class="table-wrap">
      <table class="data-table">
        <thead><tr><th>PAN (last 4)</th><th>Type</th><th>Status</th><th>Expiry</th><th></th></tr></thead>
        <tbody>
          <%= if @employee_cards_issued == [] do %>
            <tr><td colspan="5" class="empty-row" style="text-align:center;">No cards issued.</td></tr>
          <% end %>
          <%= for c <- @employee_cards_issued do %>
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
                  <button class="btn btn-xs" phx-click="open_channels" phx-value-id={c.card_id} phx-target={@myself}>Channels</button>
                </div>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp employee_tab_history(assigns) do
    entries =
      (Enum.map(assigns.employee_block_history, fn h ->
         %{
           at: h.applied_at, kind: h.action,
           detail: "#{h.block_code || "—"} — #{h.reason_code}#{if h.reason_text, do: ": #{h.reason_text}", else: ""}",
           operator: h.operator_id
         }
       end) ++
         Enum.map(assigns.employee_nonmon_events, fn e ->
           %{at: e.applied_at, kind: String.upcase(e.event_type), detail: e.reason || "—", operator: e.operator_id}
         end))
      |> Enum.sort_by(& &1.at, {:desc, NaiveDateTime})

    assigns = assign(assigns, :entries, entries)

    ~H"""
    <div class="form-pane-section-title">Account History (<%= length(@entries) %>)</div>
    <div class="table-wrap">
      <table class="data-table">
        <thead><tr><th>Date</th><th>Event</th><th>Detail</th><th>Operator</th></tr></thead>
        <tbody>
          <%= if @entries == [] do %>
            <tr><td colspan="4" class="empty-row" style="text-align:center;">No history yet.</td></tr>
          <% end %>
          <%= for e <- @entries do %>
            <tr>
              <td><%= Calendar.strftime(e.at, "%Y-%m-%d %H:%M") %></td>
              <td><span class={"badge #{if e.kind in ["BLOCKED"], do: "badge-red", else: "badge-blue"}"}><%= e.kind %></span></td>
              <td><%= e.detail %></td>
              <td style="font-size:12px;"><code><%= e.operator %></code></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end
end
