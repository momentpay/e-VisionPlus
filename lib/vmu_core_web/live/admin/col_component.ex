defmodule VmuCoreWeb.Live.Admin.ColComponent do
  @moduledoc """
  Admin LiveComponent: COL case list/detail (COL-P5) + agency file exchange and
  bulk placement (COL-P6).

  First real UI surface for COL — everything built in P1–P4
  (config catalog, write-off auto-trigger, contact history, agency desk) was
  verified only at the code layer until now. Gives a collector:

  - A filterable case list (status, account search) with checkbox multi-select
    and a bulk "place selected cases with agency" action.
  - A case detail view with account/customer context, contact history (+ a form
    to log a manual call outcome — the first UI for `ContactHistory.record_call/3`,
    FR-COL-005), current agency placement (+ place/recall actions,
    `VmuCore.COL.AgencyDesk`), and a read-only view of any write-off request for
    the account (approval itself stays in the existing Approval Inbox — one
    action surface, not two).
  - An "Agency Files" panel: generate an assignment file for a bank/agency
    (`AgencyDesk.generate_assignment_file/3`) and import an activity file by
    pasting its content (`AgencyDesk.import_activity_file/4`) — both were
    code-only with no UI before this phase. Pasted content, not a real file
    upload widget, is a deliberate scope line (no `live_upload`/multipart wiring
    added) — still fully functional for the CSV/JSON an operator would have from
    an agency email or portal download.
  - Case detail: request a hardship/workout plan (`VmuCore.COL.WorkoutCommand`,
    FR-COL-014) or a settlement offer (`VmuCore.COL.SettlementCommand`,
    FR-COL-015) — approval itself happens in the Approval Inbox (COL-P9), same
    "one action surface" split as write-offs. An APPROVED settlement offer can
    be settled (payment + forgiveness posted) directly from here.

  Visibility requires `col:view`; place/recall/log-call/bulk/file/workout/settlement
  actions require `col:edit`.
  """

  use Phoenix.LiveComponent
  import Ecto.Query
  import VmuCoreWeb.AdminUI
  import VmuCoreWeb.Components.AgGrid

  alias VmuCore.{CMS.Account, COL.CollectionCase, COL.WriteOffRequest,
                  COL.AgencyPlacement, COL.AgencyDesk, COL.ContactHistory, COL.PromiseVerification,
                  COL.WorkoutCommand, COL.WorkoutPlan, COL.SettlementCommand, COL.SettlementOffer}
  alias VmuCore.Shared.{Customer, BankParameter, ModuleConfigEngine}
  alias VmuCore.ASM.Authz
  alias Decimal, as: D

  @repo Application.compile_env(:vmu_core_web, :repo, VmuCore.Repo)

  @per_page 25
  @statuses ~w[OPEN PROMISED WORKOUT AGENCY WRITTEN_OFF RECOVERED CLOSED]
  @call_outcomes ~w[right_party_contact no_answer promise_to_pay dispute_raised refused]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       mode: :list,
       status_filter: "",
       search: "",
       page: 1,
       per_page: @per_page,
       total: 0,
       cases: [],
       accounts_map: %{},
       notice: nil,
       notice_kind: :info,
       selected_case_ids: MapSet.new(),
       bulk_agency_code: "",
       # Detail
       case_row: nil,
       account: nil,
       customer: nil,
       contact_history: [],
       placement: nil,
       write_off_requests: [],
       agency_options: [],
       call_form: %{"outcome" => "right_party_contact", "notes" => ""},
       place_form: %{"agency_code" => ""},
       promise_form: %{"amount" => "", "date" => ""},
       workout_plans: [],
       settlement_offers: [],
       workout_form: %{"plan_type" => "PAYMENT_HOLIDAY", "new_apr" => "", "holiday_months" => "1",
                        "emi_tenor_months" => "6", "end_date" => "", "reason" => ""},
       settlement_form: %{"offer_amount" => "", "expiry_date" => ""},
       settle_form: %{"actual_amount" => "", "reference" => ""},
       # Agency Files
       bank_options: [],
       file_bank: "",
       file_agency_options: [],
       generated_file: nil,
       import_agency_code: "",
       import_file_content: "",
       import_result: nil,
       statuses: @statuses,
       call_outcomes: @call_outcomes,
       can_edit: false
     )
     |> load_cases()}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, assign(socket, can_edit: Authz.can?(socket.assigns.current_operator, "col", "edit"))}
  end

  # ---------------------------------------------------------------------------
  # List events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("filter", %{"status" => status, "search" => search}, socket) do
    {:noreply, socket |> assign(status_filter: status, search: search, page: 1) |> load_cases()}
  end

  def handle_event("next_page", _, socket) do
    {:noreply, socket |> assign(page: socket.assigns.page + 1) |> load_cases()}
  end

  def handle_event("prev_page", _, socket) do
    {:noreply, socket |> assign(page: max(1, socket.assigns.page - 1)) |> load_cases()}
  end

  def handle_event("view_case", %{"id" => case_id}, socket) do
    {:noreply, load_detail(socket, case_id)}
  end

  def handle_event("back_to_list", _, socket) do
    {:noreply, assign(socket, mode: :list, notice: nil)}
  end

  # ---------------------------------------------------------------------------
  # Bulk selection + bulk placement (COL-P6)
  # ---------------------------------------------------------------------------

  def handle_event("toggle_case", %{"id" => case_id}, socket) do
    selected = socket.assigns.selected_case_ids

    updated =
      if MapSet.member?(selected, case_id),
        do: MapSet.delete(selected, case_id),
        else: MapSet.put(selected, case_id)

    {:noreply, assign(socket, selected_case_ids: updated)}
  end

  def handle_event("update_bulk_agency", %{"bulk_agency_code" => code}, socket) do
    {:noreply, assign(socket, bulk_agency_code: code)}
  end

  def handle_event("bulk_place_with_agency", %{"bulk_agency_code" => code}, socket) do
    with_edit(socket, fn ->
      results = Enum.map(socket.assigns.selected_case_ids, &AgencyDesk.place(&1, code))
      placed = Enum.count(results, &match?({:ok, _}, &1))
      failed = length(results) - placed

      msg =
        if failed == 0,
          do: "Placed #{placed} case(s) with #{code}.",
          else: "Placed #{placed} case(s) with #{code}; #{failed} failed (see logs)."

      socket
      |> put_notice(msg, if(failed == 0, do: :success, else: :warning))
      |> assign(selected_case_ids: MapSet.new())
      |> load_cases()
    end)
  end

  # ---------------------------------------------------------------------------
  # Agency Files panel (COL-P6)
  # ---------------------------------------------------------------------------

  def handle_event("show_agency_files", _params, socket) do
    {:noreply,
     socket
     |> assign(mode: :agency_files, generated_file: nil, import_result: nil)
     |> load_bank_options()}
  end

  def handle_event("select_file_bank", %{"file_bank" => bank_key}, socket) do
    {:noreply, socket |> assign(file_bank: bank_key) |> load_file_agency_options()}
  end

  def handle_event("generate_file", %{"agency_code" => code}, socket) do
    with_edit(socket, fn ->
      {sys_id, bank_id} = split_bank_key(socket.assigns.file_bank)

      case AgencyDesk.generate_assignment_file(code, sys_id, bank_id) do
        {:ok, content, format} ->
          AgencyDesk.deliver_assignment_file(content, format, code)

          put_notice(
            assign(socket, generated_file: %{content: content, format: format, agency_code: code}),
            "Generated #{format} assignment file for #{code} (also logged as delivered).", :success
          )

        {:error, reason} ->
          put_notice(socket, "Generate failed: #{inspect(reason)}", :error)
      end
    end)
  end

  def handle_event("update_import_form", %{"agency_code" => code, "content" => content}, socket) do
    {:noreply, assign(socket, import_agency_code: code, import_file_content: content)}
  end

  def handle_event("import_file", %{"agency_code" => code, "content" => content}, socket) do
    with_edit(socket, fn ->
      {sys_id, bank_id} = split_bank_key(socket.assigns.file_bank)

      case AgencyDesk.import_activity_file(code, sys_id, bank_id, content) do
        {:ok, result} ->
          put_notice(assign(socket, import_result: result),
            "Imported: #{result.applied} applied, #{result.rejected} rejected.", :success)

        {:error, reason} ->
          put_notice(socket, "Import failed: #{inspect(reason)}", :error)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Detail events
  # ---------------------------------------------------------------------------

  def handle_event("update_call_form", %{"outcome" => outcome, "notes" => notes}, socket) do
    {:noreply, assign(socket, call_form: %{"outcome" => outcome, "notes" => notes})}
  end

  def handle_event("log_call", %{"outcome" => outcome, "notes" => notes}, socket) do
    with_edit(socket, fn ->
      account = socket.assigns.account

      ContactHistory.record_call(account.account_id, outcome,
        notes: notes, dpd_bucket: account.delinquency_bucket,
        attempted_by: socket.assigns.current_operator.username)

      socket
      |> put_notice("Call logged.", :success)
      |> assign(call_form: %{"outcome" => "right_party_contact", "notes" => ""})
      |> reload_detail()
    end)
  end

  def handle_event("update_place_form", %{"agency_code" => code}, socket) do
    {:noreply, assign(socket, place_form: %{"agency_code" => code})}
  end

  def handle_event("place_with_agency", %{"agency_code" => code}, socket) do
    with_edit(socket, fn ->
      case AgencyDesk.place(socket.assigns.case_row.case_id, code) do
        {:ok, _placement} ->
          socket |> put_notice("Case placed with #{code}.", :success) |> reload_detail()

        {:error, :agency_not_configured} ->
          put_notice(socket, "Agency \"#{code}\" is not configured for this bank.", :error)

        {:error, :open_dispute_exists} ->
          put_notice(socket, "This account has an open dispute — cannot place with an agency until it's resolved.", :error)

        {:error, reason} ->
          put_notice(socket, "Placement failed: #{inspect(reason)}", :error)
      end
    end)
  end

  def handle_event("update_promise_form", %{"amount" => amount, "date" => date}, socket) do
    {:noreply, assign(socket, promise_form: %{"amount" => amount, "date" => date})}
  end

  def handle_event("log_promise", %{"amount" => amount, "date" => date}, socket) do
    with_edit(socket, fn ->
      with {:ok, decimal_amount} <- parse_decimal(amount),
           {:ok, parsed_date} <- Date.from_iso8601(date) do
        case PromiseVerification.log_promise(socket.assigns.case_row.case_id, decimal_amount, parsed_date) do
          {:ok, _} ->
            socket
            |> put_notice("Promise logged — will auto-verify on #{date}.", :success)
            |> assign(promise_form: %{"amount" => "", "date" => ""})
            |> reload_detail()

          {:error, reason} ->
            put_notice(socket, "Log promise failed: #{inspect(reason)}", :error)
        end
      else
        _ -> put_notice(socket, "Enter a valid amount and date (YYYY-MM-DD).", :error)
      end
    end)
  end

  def handle_event("recall_placement", _params, socket) do
    with_edit(socket, fn ->
      case AgencyDesk.recall(socket.assigns.placement.id, "Recalled via admin console") do
        {:ok, _} -> socket |> put_notice("Placement recalled.", :success) |> reload_detail()
        {:error, reason} -> put_notice(socket, "Recall failed: #{inspect(reason)}", :error)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Workout plans (COL-P9)
  # ---------------------------------------------------------------------------

  def handle_event("update_workout_form", params, socket) do
    {:noreply, assign(socket, workout_form: Map.take(params, ~w[plan_type new_apr holiday_months emi_tenor_months end_date reason]))}
  end

  def handle_event("request_workout", params, socket) do
    with_edit(socket, fn ->
      %{case_row: case_row, account: account} = socket.assigns
      plan_type = params["plan_type"]

      workout_params = %{
        requested_by: socket.assigns.current_operator.username,
        reason: blank_to_nil(params["reason"])
      }

      result =
        with {:ok, extra} <- parse_workout_params(plan_type, params) do
          WorkoutCommand.request(case_row.case_id, account.account_id, plan_type, Map.merge(workout_params, extra))
        end

      case result do
        {:ok, _plan} ->
          socket |> put_notice("Workout plan requested — pending approval.", :success) |> reload_detail()

        {:error, :invalid_params} ->
          put_notice(socket, "Enter valid values for this plan type.", :error)

        {:error, reason} ->
          put_notice(socket, "Request failed: #{inspect(reason)}", :error)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Settlement offers (COL-P9)
  # ---------------------------------------------------------------------------

  def handle_event("update_settlement_form", params, socket) do
    {:noreply, assign(socket, settlement_form: Map.take(params, ~w[offer_amount expiry_date]))}
  end

  def handle_event("request_settlement", params, socket) do
    with_edit(socket, fn ->
      %{case_row: case_row, account: account} = socket.assigns

      with {:ok, amount} <- parse_decimal(params["offer_amount"]),
           {:ok, expiry} <- Date.from_iso8601(params["expiry_date"] || "") do
        case SettlementCommand.request(case_row.case_id, account.account_id, amount, expiry,
               socket.assigns.current_operator.username) do
          {:ok, _offer} ->
            socket |> put_notice("Settlement offer requested — pending approval.", :success) |> reload_detail()

          {:error, {:discount_too_deep, discount, max_allowed}} ->
            put_notice(socket, "Discount #{discount}% exceeds the maximum allowed #{max_allowed}%.", :error)

          {:error, reason} ->
            put_notice(socket, "Request failed: #{inspect(reason)}", :error)
        end
      else
        _ -> put_notice(socket, "Enter a valid offer amount and expiry date.", :error)
      end
    end)
  end

  def handle_event("update_settle_form", params, socket) do
    {:noreply, assign(socket, settle_form: Map.take(params, ~w[actual_amount reference]))}
  end

  def handle_event("settle_offer", %{"offer_id" => offer_id} = params, socket) do
    with_edit(socket, fn ->
      with {:ok, amount} <- parse_decimal(params["actual_amount"]) do
        case SettlementCommand.settle(offer_id, amount, params["reference"] || "") do
          {:ok, offer} ->
            socket
            |> put_notice("Settlement paid: #{offer.paid_amount} received, #{offer.forgiven_amount} forgiven.", :success)
            |> reload_detail()

          {:error, reason} ->
            put_notice(socket, "Settle failed: #{inspect(reason)}", :error)
        end
      else
        _ -> put_notice(socket, "Enter a valid amount.", :error)
      end
    end)
  end

  defp parse_workout_params("PAYMENT_HOLIDAY", params) do
    case Integer.parse(params["holiday_months"] || "") do
      {n, ""} when n > 0 -> {:ok, %{holiday_months: n}}
      _ -> {:error, :invalid_params}
    end
  end

  defp parse_workout_params("APR_REDUCTION", params) do
    with {:ok, apr} <- parse_decimal(params["new_apr"]),
         {:ok, end_date} <- Date.from_iso8601(params["end_date"] || "") do
      {:ok, %{new_apr: apr, end_date: end_date}}
    else
      _ -> {:error, :invalid_params}
    end
  end

  defp parse_workout_params("RESTRUCTURE", params) do
    case Integer.parse(params["emi_tenor_months"] || "") do
      {n, ""} when n > 0 -> {:ok, %{emi_tenor_months: n}}
      _ -> {:error, :invalid_params}
    end
  end

  defp parse_workout_params(_, _), do: {:error, :invalid_params}

  defp with_edit(socket, fun) do
    if socket.assigns.can_edit do
      {:noreply, fun.()}
    else
      {:noreply, put_notice(socket, "Your role cannot make changes to COL cases.", :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(%{mode: :list} = assigns) do
    ~H"""
    <div id={@id} class="component-panel">
      <.page_header title="Collections & Recovery" subtitle="Cases by status, DPD bucket, and assignment">
        <:actions>
          <button class="btn-sm" phx-click="show_agency_files" phx-target={@myself}>📁 Agency Files</button>
        </:actions>
      </.page_header>

      <.alert :if={@notice} kind={@notice_kind} message={@notice} />

      <form phx-change="filter" phx-target={@myself} style="display:flex; gap:0.5rem; margin-bottom:1rem; align-items:end">
        <div class="field" style="margin:0">
          <label>Status</label>
          <select name="status">
            <option value="" selected={@status_filter == ""}>All</option>
            <option :for={s <- @statuses} value={s} selected={@status_filter == s}><%= s %></option>
          </select>
        </div>
        <div class="field" style="margin:0">
          <label>Search (last 4 / account id)</label>
          <input type="text" name="search" value={@search} placeholder="1234" />
        </div>
      </form>

      <form :if={@can_edit and MapSet.size(@selected_case_ids) > 0}
            phx-change="update_bulk_agency" phx-submit="bulk_place_with_agency" phx-target={@myself}
            style="display:flex; gap:0.5rem; align-items:end; margin-bottom:1rem; padding:0.5rem; background:rgba(127,127,127,0.08); border-radius:6px">
        <span style="align-self:center"><%= MapSet.size(@selected_case_ids) %> selected</span>
        <div class="field" style="margin:0">
          <label>Place with agency code</label>
          <input type="text" name="bulk_agency_code" value={@bulk_agency_code} placeholder="AGENCY1" />
        </div>
        <button class="btn-sm btn-success" type="submit">Place selected</button>
      </form>

      <%!-- Plain HTML for a structural reason, not a test one: each row
           carries a bound checkbox feeding the bulk "Place selected" form
           above. No ag_grid cell type hosts a bound form control, and AG
           Grid's own row-selection would need a new selection→LiveView
           bridge in the contract to drive @selected_case_ids. This list
           does grow with activity, so it is a genuine candidate once that
           bridge exists — see docs/shared/Admin_Detail_UX_Philosophy.md §1
           and the "remaining" note in §Status. --%>
      <div class="table-wrapper">
        <table class="data-table">
          <thead>
            <tr>
              <th></th><th>Account</th><th>DPD</th><th>Outstanding</th><th>Status</th>
              <th>Assigned To</th><th>Updated</th><th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@cases == []}>
              <td colspan="8" style="text-align:center;color:#888">No cases found.</td>
            </tr>
            <tr :for={c <- @cases}>
              <td>
                <input :if={@can_edit} type="checkbox" phx-click="toggle_case" phx-value-id={c.case_id}
                       phx-target={@myself} checked={MapSet.member?(@selected_case_ids, c.case_id)} />
              </td>
              <td><code style="font-size:0.85em"><%= account_label(@accounts_map, c.account_id) %></code></td>
              <td><%= c.dpd_bucket %></td>
              <td style="text-align:right"><%= c.outstanding_amount %></td>
              <td><.status_badge status={c.status} /></td>
              <td><%= c.assigned_to || "—" %></td>
              <td style="white-space:nowrap"><%= format_dt(c.updated_at) %></td>
              <td>
                <button class="btn-sm" phx-click="view_case" phx-value-id={c.case_id} phx-target={@myself}>View</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="pagination" style="margin-top:0.75rem">
        <button class="btn-sm" phx-click="prev_page" phx-target={@myself} disabled={@page <= 1}>← Prev</button>
        <span style="margin:0 0.5rem">Page <%= @page %> · <%= @total %> total</span>
        <button class="btn-sm" phx-click="next_page" phx-target={@myself} disabled={@page * @per_page >= @total}>Next →</button>
      </div>
    </div>
    """
  end

  def render(%{mode: :agency_files} = assigns) do
    ~H"""
    <div id={@id} class="component-panel">
      <.page_header title="Agency Files" subtitle="Assignment file generation + activity file import">
        <:actions>
          <button class="btn-sm" phx-click="back_to_list" phx-target={@myself}>← Back to cases</button>
        </:actions>
      </.page_header>

      <.alert :if={@notice} kind={@notice_kind} message={@notice} />

      <.form_card title="Bank / Agency">
        <form phx-change="select_file_bank" phx-target={@myself}>
          <div class="field">
            <label>Bank</label>
            <select name="file_bank">
              <option value="">— Select —</option>
              <option :for={{label, key} <- @bank_options} value={key} selected={@file_bank == key}><%= label %></option>
            </select>
          </div>
        </form>
        <div :if={@file_bank != "" and @file_agency_options == []} class="text-muted">
          No agencies configured for this bank (col.agency_config).
        </div>
      </.form_card>

      <.form_card :if={@file_agency_options != []} title="Generate Assignment File">
        <form phx-submit="generate_file" phx-target={@myself} style="display:flex; gap:0.5rem; align-items:end">
          <div class="field" style="margin:0">
            <label>Agency</label>
            <select name="agency_code">
              <option :for={code <- @file_agency_options} value={code}><%= code %></option>
            </select>
          </div>
          <button :if={@can_edit} class="btn-sm btn-success" type="submit">Generate</button>
        </form>
        <div :if={@generated_file} style="margin-top:0.75rem">
          <p class="text-muted">
            <%= @generated_file.format %> — <%= byte_size(@generated_file.content) %> bytes for <%= @generated_file.agency_code %>
          </p>
          <textarea readonly rows="10" style="width:100%; font-family:monospace; font-size:0.8em"><%= @generated_file.content %></textarea>
        </div>
      </.form_card>

      <.form_card :if={@file_agency_options != []} title="Import Activity File">
        <form phx-change="update_import_form" phx-submit="import_file" phx-target={@myself}>
          <div class="field">
            <label>Agency</label>
            <select name="agency_code">
              <option :for={code <- @file_agency_options} value={code} selected={@import_agency_code == code}><%= code %></option>
            </select>
          </div>
          <div class="field">
            <label>File content (paste CSV/JSON)</label>
            <textarea name="content" rows="8" style="width:100%; font-family:monospace; font-size:0.8em"><%= @import_file_content %></textarea>
          </div>
          <button :if={@can_edit} class="btn-sm btn-success" type="submit">Import</button>
        </form>
        <p :if={@import_result} class="text-muted" style="margin-top:0.5rem">
          Applied: <%= @import_result.applied %> · Rejected: <%= @import_result.rejected %>
        </p>
      </.form_card>
    </div>
    """
  end

  def render(%{mode: :detail} = assigns) do
    ~H"""
    <div id={@id} class="component-panel">
      <.page_header title={"Case — #{@account.last_four}"} subtitle={@case_row.status}>
        <:actions>
          <button class="btn-sm" phx-click="back_to_list" phx-target={@myself}>← Back to list</button>
        </:actions>
      </.page_header>

      <.alert :if={@notice} kind={@notice_kind} message={@notice} />

      <.form_card title="Case">
        <.kv_detail rows={[
          {"Account", "#{@account.last_four} (#{@account.account_id})"},
          {"Customer", @customer && "#{@customer.first_name} #{@customer.last_name}"},
          {"DPD bucket", @case_row.dpd_bucket},
          {"Outstanding", @case_row.outstanding_amount},
          {"Status", @case_row.status},
          {"Assigned to", @case_row.assigned_to},
          {"Promise", @case_row.promise_amount && "#{@case_row.promise_amount} by #{@case_row.promise_date} (#{@case_row.promise_status || "PENDING"})"}
        ]} />
      </.form_card>

      <.form_card title="Promise to Pay (FR-COL-006b)" subtitle="Auto-verified against real payments on the promise date">
        <form :if={@can_edit} phx-change="update_promise_form" phx-submit="log_promise" phx-target={@myself} style="display:flex; gap:0.5rem; align-items:end">
          <div class="field" style="margin:0">
            <label>Amount</label>
            <input type="text" name="amount" value={@promise_form["amount"]} placeholder="500.00" />
          </div>
          <div class="field" style="margin:0">
            <label>Date</label>
            <input type="date" name="date" value={@promise_form["date"]} />
          </div>
          <button class="btn-sm btn-success" type="submit">Log promise</button>
        </form>
      </.form_card>

      <.form_card title="Write-off Requests" subtitle="Approve/reject in the Approval Inbox — read-only here">
        <div :if={@write_off_requests == []} class="text-muted">None.</div>
        <.kv_detail :for={w <- @write_off_requests} rows={[
          {"Requested", format_dt(w.inserted_at)},
          {"Status", w.status},
          {"Amount", w.write_off_amount},
          {"IFRS9 stage", w.ifrs9_stage}
        ]} />
      </.form_card>

      <.form_card title="Agency Placement">
        <%= if @placement do %>
          <.kv_detail rows={[
            {"Agency", @placement.agency_code},
            {"Status", @placement.status},
            {"Placed", "#{@placement.placed_amount} on #{format_dt(@placement.placed_at)}"}
          ]} />
          <button :if={@can_edit and @placement.status == "PLACED"} class="btn-sm btn-warning"
                  phx-click="recall_placement" phx-target={@myself} style="margin-top:0.5rem">
            Recall
          </button>
        <% else %>
          <div :if={@agency_options == []} class="text-muted">No agencies configured for this bank.</div>
          <form :if={@can_edit and @agency_options != []} phx-change="update_place_form" phx-submit="place_with_agency" phx-target={@myself} style="display:flex; gap:0.5rem; align-items:end">
            <div class="field" style="margin:0">
              <label>Place with agency</label>
              <select name="agency_code">
                <option :for={code <- @agency_options} value={code}><%= code %></option>
              </select>
            </div>
            <button class="btn-sm btn-success" type="submit">Place</button>
          </form>
        <% end %>
      </.form_card>

      <.form_card title="Hardship / Workout Plans (FR-COL-014)" subtitle="Approve/reject in the Approval Inbox">
        <.ag_grid
          :if={@workout_plans != []}
          id="col-workout-plans-grid"
          paginate={false}
          columns={[
            %{field: "plan_type", header: "Type", width: 150},
            %{field: "terms", header: "Terms", flex: 1},
            %{field: "period", header: "Period", width: 200},
            %{field: "status", header: "Status", type: "badge", width: 120}
          ]}
          rows={Enum.map(@workout_plans, &workout_plan_row/1)}
        />

        <form :if={@can_edit} phx-change="update_workout_form" phx-submit="request_workout" phx-target={@myself}>
          <div style="display:flex; gap:0.5rem; align-items:end; flex-wrap:wrap">
            <div class="field" style="margin:0">
              <label>Plan type</label>
              <select name="plan_type">
                <option value="PAYMENT_HOLIDAY" selected={@workout_form["plan_type"] == "PAYMENT_HOLIDAY"}>Payment holiday</option>
                <option value="APR_REDUCTION" selected={@workout_form["plan_type"] == "APR_REDUCTION"}>APR reduction</option>
                <option value="RESTRUCTURE" selected={@workout_form["plan_type"] == "RESTRUCTURE"}>Restructure (EMI)</option>
              </select>
            </div>
            <div :if={@workout_form["plan_type"] == "PAYMENT_HOLIDAY"} class="field" style="margin:0">
              <label>Months</label>
              <input type="text" name="holiday_months" value={@workout_form["holiday_months"]} style="width:4rem" />
            </div>
            <div :if={@workout_form["plan_type"] == "APR_REDUCTION"} class="field" style="margin:0">
              <label>New APR %</label>
              <input type="text" name="new_apr" value={@workout_form["new_apr"]} placeholder="9.00" style="width:6rem" />
            </div>
            <div :if={@workout_form["plan_type"] == "APR_REDUCTION"} class="field" style="margin:0">
              <label>Effective until</label>
              <input type="date" name="end_date" value={@workout_form["end_date"]} />
            </div>
            <div :if={@workout_form["plan_type"] == "RESTRUCTURE"} class="field" style="margin:0">
              <label>EMI tenor (months)</label>
              <input type="text" name="emi_tenor_months" value={@workout_form["emi_tenor_months"]} style="width:4rem" />
            </div>
            <div class="field" style="margin:0; flex:1">
              <label>Reason</label>
              <input type="text" name="reason" value={@workout_form["reason"]} />
            </div>
            <button class="btn-sm btn-success" type="submit">Request</button>
          </div>
        </form>
        <p :if={@workout_form["plan_type"] == "RESTRUCTURE"} class="text-muted" style="font-size:0.8em; margin-top:0.5rem">
          Note: restructure requests are tracked and approved but do not auto-generate an EMI schedule — ops must set that up manually (see tracker).
        </p>
      </.form_card>

      <.form_card title="Settlement Offers (FR-COL-015)" subtitle="Approve/reject in the Approval Inbox">
        <div class="table-wrapper" :if={@settlement_offers != []} style="margin-bottom:0.75rem">
          <table class="data-table">
            <thead><tr><th>Outstanding</th><th>Offer</th><th>Discount</th><th>Expires</th><th>Status</th><th>Actions</th></tr></thead>
            <tbody>
              <tr :for={o <- @settlement_offers}>
                <td style="text-align:right"><%= o.outstanding_amount %></td>
                <td style="text-align:right"><%= o.offer_amount %></td>
                <td><%= o.discount_percent %>%</td>
                <td><%= o.expiry_date %></td>
                <td><.status_badge status={o.status} /></td>
                <td>
                  <form :if={@can_edit and o.status == "APPROVED"} phx-change="update_settle_form" phx-submit="settle_offer" phx-target={@myself} style="display:flex; gap:0.25rem">
                    <input type="hidden" name="offer_id" value={o.id} />
                    <input type="text" name="actual_amount" value={@settle_form["actual_amount"]} placeholder="amount" style="width:5rem" />
                    <input type="text" name="reference" value={@settle_form["reference"]} placeholder="ref" style="width:5rem" />
                    <button class="btn-sm btn-success" type="submit">Settle</button>
                  </form>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <form :if={@can_edit} phx-change="update_settlement_form" phx-submit="request_settlement" phx-target={@myself} style="display:flex; gap:0.5rem; align-items:end">
          <div class="field" style="margin:0">
            <label>Offer amount</label>
            <input type="text" name="offer_amount" value={@settlement_form["offer_amount"]} placeholder="500.00" />
          </div>
          <div class="field" style="margin:0">
            <label>Expires</label>
            <input type="date" name="expiry_date" value={@settlement_form["expiry_date"]} />
          </div>
          <button class="btn-sm btn-success" type="submit">Request offer</button>
        </form>
      </.form_card>

      <.form_card title="Contact History (FR-COL-005)">
        <form :if={@can_edit} phx-change="update_call_form" phx-submit="log_call" phx-target={@myself} style="display:flex; gap:0.5rem; align-items:end; margin-bottom:1rem">
          <div class="field" style="margin:0">
            <label>Outcome</label>
            <select name="outcome">
              <option :for={o <- @call_outcomes} value={o} selected={@call_form["outcome"] == o}><%= o %></option>
            </select>
          </div>
          <div class="field" style="margin:0; flex:1">
            <label>Notes</label>
            <input type="text" name="notes" value={@call_form["notes"]} />
          </div>
          <button class="btn-sm btn-success" type="submit">Log call</button>
        </form>

        <.ag_grid
          id="col-contact-history-grid"
          empty_message="No contact recorded."
          columns={[
            %{field: "at", header: "When", width: 160},
            %{field: "channel", header: "Channel", width: 120},
            %{field: "outcome", header: "Outcome", width: 140},
            %{field: "attempted_by", header: "By", type: "mono", width: 130},
            %{field: "notes", header: "Notes", flex: 1}
          ]}
          rows={Enum.map(@contact_history, &contact_history_row/1)}
        />
      </.form_card>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp load_cases(socket) do
    %{status_filter: status, search: search, page: page} = socket.assigns
    offset = (page - 1) * @per_page

    base = from c in CollectionCase, order_by: [desc: c.updated_at]
    base = if status != "", do: where(base, [c], c.status == ^status), else: base

    base =
      if search != "" and search != nil do
        acct_ids =
          @repo.all(from a in Account, where: a.last_four == ^search or ilike(a.account_id, ^"%#{search}%"),
            select: a.account_id)

        where(base, [c], c.account_id in ^acct_ids)
      else
        base
      end

    total = @repo.one(from c in subquery(base), select: count(c.case_id)) || 0
    cases = @repo.all(from c in base, limit: @per_page, offset: ^offset)

    acct_ids = cases |> Enum.map(& &1.account_id) |> Enum.uniq()
    accounts_map =
      if acct_ids == [] do
        %{}
      else
        @repo.all(from a in Account, where: a.account_id in ^acct_ids) |> Map.new(&{&1.account_id, &1})
      end

    assign(socket, cases: cases, total: total, accounts_map: accounts_map)
  end

  defp load_detail(socket, case_id) do
    case @repo.get(CollectionCase, case_id) do
      nil ->
        put_notice(socket, "Case not found.", :error)

      case_row ->
        account = @repo.get!(Account, case_row.account_id)
        customer = if account.customer_id, do: @repo.get(Customer, account.customer_id), else: nil

        socket
        |> assign(mode: :detail, case_row: case_row, account: account, customer: customer)
        |> reload_detail()
    end
  end

  defp reload_detail(socket) do
    %{case_row: case_row, account: account} = socket.assigns
    case_row = @repo.get!(CollectionCase, case_row.case_id)

    placement =
      @repo.one(
        from p in AgencyPlacement,
          where: p.case_id == ^case_row.case_id,
          order_by: [desc: p.inserted_at], limit: 1
      )

    write_off_requests =
      @repo.all(
        from w in WriteOffRequest,
          where: w.account_id == ^account.account_id,
          order_by: [desc: w.inserted_at]
      )

    agency_options =
      case ModuleConfigEngine.get("col", "agency_config", account.sys_id, account.bank_id) do
        {:ok, cfg} -> Map.keys(cfg)
        {:error, _} -> []
      end

    workout_plans =
      @repo.all(from p in WorkoutPlan, where: p.account_id == ^account.account_id, order_by: [desc: p.inserted_at])

    settlement_offers =
      @repo.all(from o in SettlementOffer, where: o.account_id == ^account.account_id, order_by: [desc: o.inserted_at])

    assign(socket,
      case_row: case_row,
      contact_history: ContactHistory.list_for_account(account.account_id),
      placement: placement,
      write_off_requests: write_off_requests,
      agency_options: agency_options,
      workout_plans: workout_plans,
      settlement_offers: settlement_offers
    )
  end

  defp load_bank_options(socket) do
    banks = @repo.all(BankParameter)

    opts =
      Enum.map(banks, fn b ->
        {"#{b.bank_id} — #{b.org_name || b.description}", "#{b.sys_id}|#{b.bank_id}"}
      end)

    assign(socket, bank_options: opts)
  end

  defp load_file_agency_options(socket) do
    {sys_id, bank_id} = split_bank_key(socket.assigns.file_bank)

    agency_options =
      if sys_id == "" do
        []
      else
        case ModuleConfigEngine.get("col", "agency_config", sys_id, bank_id) do
          {:ok, cfg} -> Map.keys(cfg)
          {:error, _} -> []
        end
      end

    assign(socket, file_agency_options: agency_options)
  end

  defp split_bank_key(""), do: {"", ""}
  defp split_bank_key(key) do
    case String.split(key, "|", parts: 2) do
      [sys_id, bank_id] -> {sys_id, bank_id}
      _ -> {"", ""}
    end
  end

  defp parse_decimal(value) do
    case Decimal.parse(value || "") do
      {d, ""} -> {:ok, d}
      _ -> :error
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  defp put_notice(socket, msg, kind), do: assign(socket, notice: msg, notice_kind: kind)

  defp account_label(accounts_map, account_id) do
    case Map.get(accounts_map, account_id) do
      nil -> String.slice(to_string(account_id), 0, 8) <> "…"
      acc -> "#{acc.last_four} (#{String.slice(to_string(account_id), 0, 8)}…)"
    end
  end

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_dt(%Date{} = d), do: Date.to_string(d)

  defp workout_plan_terms(%{plan_type: "APR_REDUCTION", new_apr: apr}), do: "new APR #{apr}%"
  defp workout_plan_terms(%{plan_type: "PAYMENT_HOLIDAY", holiday_months: m}), do: "#{m} month(s)"
  defp workout_plan_terms(%{plan_type: "RESTRUCTURE", emi_tenor_months: m}), do: "#{m} month EMI"
  defp workout_plan_terms(_), do: "—"

  defp workout_plan_row(w) do
    %{
      plan_type: w.plan_type,
      terms: workout_plan_terms(w),
      period: "#{w.start_date} → #{w.end_date}",
      status: w.status
    }
  end

  defp contact_history_row(a) do
    %{
      at: format_dt(a.inserted_at),
      channel: a.channel,
      outcome: a.outcome || "—",
      attempted_by: a.attempted_by,
      notes: a.notes
    }
  end
end
