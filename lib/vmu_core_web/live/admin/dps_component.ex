defmodule VmuCoreWeb.Live.Admin.DpsComponent do
  @moduledoc """
  Admin LiveComponent: DPS ops UI (DPS-P5).

  DPS-P1 through P4 built the dispute state machine, deadline enforcement,
  evidence store, network filing scaffolding, and case notes/assignment —
  all verified via scripts, none of it with a browser. This is the first
  screen: case list + detail, a deadline monitor, an evidence upload/list
  panel, a case-notes/assignment panel, and reason-code reference-data
  admin. See `docs/dps/DPS_Gap_Implementation_Tracker.md` DPS-P5.
  """

  use Phoenix.LiveComponent
  import Ecto.Query
  import VmuCoreWeb.AdminUI

  alias VmuCore.Repo
  alias VmuCore.DPS.{Dispute, Evidence, CaseNotes, ReasonCode}
  alias VmuCore.CMS.Account
  alias VmuCore.ASM.Authz

  @per_page 25
  @open_statuses ~w[FILED RETRIEVAL_REQUESTED CHARGEBACK_FILED REPRESENTED PRE_ARB ARBITRATION]
  @closed_statuses ~w[CLOSED_WIN CLOSED_LOSE CANCELLED]
  @all_statuses @open_statuses ++ @closed_statuses
  @max_evidence_bytes 10_000_000

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       view: :list,
       filter: "open",
       disputes: [],
       total: 0,
       page: 1,
       dispute: nil,
       account: nil,
       evidence_list: [],
       notes_list: [],
       reason_info: nil,
       note_draft: "",
       assign_draft: "",
       transition_target: "",
       show_file_form: false,
       reason_codes: [],
       reason_form: nil,
       notice: nil,
       can_create: false,
       can_edit: false,
       can_approve: false
     )
     |> allow_upload(:evidence, accept: :any, max_entries: 1, max_file_size: @max_evidence_bytes)
     |> load_list()}
  end

  @impl true
  def update(assigns, socket) do
    operator = assigns[:current_operator]

    socket = assign(socket, assigns)

    socket =
      if operator do
        assign(socket,
          can_create: Authz.can?(operator, "dps", "create"),
          can_edit: Authz.can?(operator, "dps", "edit"),
          can_approve: Authz.can?(operator, "dps", "approve")
        )
      else
        socket
      end

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # Events — list view
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, socket |> assign(filter: status, page: 1) |> load_list()}
  end

  def handle_event("open_case", %{"id" => id}, socket) do
    {:noreply, load_case(socket, id)}
  end

  def handle_event("back_to_list", _, socket) do
    {:noreply, socket |> assign(view: :list, dispute: nil, notice: nil) |> load_list()}
  end

  def handle_event("next_page", _, socket) do
    {:noreply, socket |> assign(page: socket.assigns.page + 1) |> load_list()}
  end

  def handle_event("prev_page", _, socket) do
    {:noreply, socket |> assign(page: max(1, socket.assigns.page - 1)) |> load_list()}
  end

  # ---------------------------------------------------------------------------
  # Events — file a new dispute
  # ---------------------------------------------------------------------------

  def handle_event("toggle_file_form", _, socket) do
    {:noreply, assign(socket, show_file_form: !socket.assigns.show_file_form, notice: nil)}
  end

  def handle_event("file_dispute_submit", %{"dispute" => params}, socket) do
    cond do
      not socket.assigns.can_create ->
        {:noreply, assign(socket, notice: "Your role cannot file disputes.")}

      # `dps_disputes.account_id` has a real FK to `cms_accounts` — a
      # malformed or non-existent id would otherwise crash this LiveView
      # (Ecto.ChangeError / a Postgres FK violation, neither caught by
      # `Dispute.file/1`'s own `{:error, changeset}` path) instead of
      # showing a clean form error.
      not valid_uuid?(params["account_id"]) ->
        {:noreply, assign(socket, notice: "Account ID must be a valid UUID.")}

      is_nil(safe_get_account(params["account_id"])) ->
        {:noreply, assign(socket, notice: "No account found for that ID.")}

      true ->
        attrs = %{
          account_id: params["account_id"],
          transaction_date: params["transaction_date"],
          dispute_amount: params["dispute_amount"],
          currency: blank_to_nil(params["currency"]) || "MC",
          reason_code: params["reason_code"],
          network: blank_to_nil(params["network"]) || "MC"
        }

        case Dispute.file(attrs) do
          {:ok, dispute} ->
            {:noreply,
             socket
             |> assign(show_file_form: false)
             |> load_case(dispute.dispute_id, "Dispute filed.")}

          {:error, %Ecto.Changeset{} = cs} ->
            {:noreply, assign(socket, notice: "Could not file dispute: #{changeset_errors(cs)}")}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Events — case detail: transitions, assignment, notes, evidence
  # ---------------------------------------------------------------------------

  def handle_event("transition", %{"status" => status}, socket) do
    gate = if status in @closed_statuses, do: socket.assigns.can_approve, else: socket.assigns.can_edit

    if gate do
      case Dispute.transition(socket.assigns.dispute.dispute_id, status) do
        {:ok, _dispute} ->
          {:noreply, load_case(socket, socket.assigns.dispute.dispute_id, "Status updated to #{status}.")}

        {:error, reason} ->
          {:noreply, assign(socket, notice: "Transition failed: #{inspect(reason)}")}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot change this dispute's status.")}
    end
  end

  def handle_event("assign_to_me", _, socket) do
    do_assign(socket, socket.assigns.current_operator.username)
  end

  def handle_event("assign_submit", %{"assignee" => assignee}, socket) do
    do_assign(socket, blank_to_nil(assignee))
  end

  def handle_event("unassign", _, socket) do
    do_assign(socket, nil)
  end

  def handle_event("note_change", %{"note" => note}, socket) do
    {:noreply, assign(socket, note_draft: note)}
  end

  def handle_event("add_note", %{"note" => text}, socket) do
    text = String.trim(text || "")

    cond do
      text == "" ->
        {:noreply, assign(socket, notice: "Note cannot be empty.")}

      not socket.assigns.can_edit ->
        {:noreply, assign(socket, notice: "Your role cannot add case notes.")}

      true ->
        case CaseNotes.add_note(socket.assigns.dispute.dispute_id, text, socket.assigns.current_operator) do
          {:ok, _note} ->
            {:noreply,
             socket
             |> assign(note_draft: "")
             |> load_case(socket.assigns.dispute.dispute_id)}

          {:error, cs} ->
            {:noreply, assign(socket, notice: "Could not add note: #{changeset_errors(cs)}")}
        end
    end
  end

  def handle_event("save_evidence", _, socket) do
    if socket.assigns.can_edit do
      dispute_id = socket.assigns.dispute.dispute_id

      results =
        consume_uploaded_entries(socket, :evidence, fn %{path: path}, entry ->
          data = File.read!(path)

          file = %{
            filename: entry.client_name,
            content_type: entry.client_type,
            data: data
          }

          {:ok, Evidence.attach(dispute_id, file, socket.assigns.current_operator)}
        end)

      # `consume_uploaded_entries/3` returns a plain list of each callback's
      # already-unwrapped `{:ok, term}` payload — `term` here is
      # `Evidence.attach/3`'s own `{:ok, evidence} | {:error, reason}`, not
      # double-wrapped.
      case results do
        [{:ok, _evidence}] ->
          {:noreply, load_case(socket, dispute_id, "Evidence uploaded.")}

        [{:error, reason}] ->
          {:noreply, assign(socket, notice: "Upload failed: #{inspect(reason)}")}

        [] ->
          {:noreply, assign(socket, notice: "Choose a file first.")}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot attach evidence.")}
    end
  end

  def handle_event("cancel_evidence_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :evidence, ref)}
  end

  # Required phx-change target for the live_file_input's own progress events —
  # no other field on that form needs server-side reaction.
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("delete_evidence", %{"id" => evidence_id}, socket) do
    if socket.assigns.can_edit do
      case Evidence.delete(evidence_id, socket.assigns.current_operator) do
        :ok ->
          {:noreply, load_case(socket, socket.assigns.dispute.dispute_id, "Evidence deleted.")}

        {:error, reason} ->
          {:noreply, assign(socket, notice: "Could not delete: #{inspect(reason)}")}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot delete evidence.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Events — reason-code reference data
  # ---------------------------------------------------------------------------

  def handle_event("show_reason_codes", _, socket) do
    {:noreply, socket |> assign(view: :reason_codes, notice: nil) |> load_reason_codes()}
  end

  def handle_event("reason_code_new", _, socket) do
    {:noreply, assign(socket, reason_form: %ReasonCode{})}
  end

  def handle_event("reason_code_edit", %{"id" => id}, socket) do
    {:noreply, assign(socket, reason_form: Repo.get(ReasonCode, id))}
  end

  def handle_event("reason_code_cancel", _, socket) do
    {:noreply, assign(socket, reason_form: nil)}
  end

  def handle_event("reason_code_save", %{"reason_code" => params}, socket) do
    if socket.assigns.can_edit do
      params = Map.update(params, "evidence_required", [], &split_csv/1)
      record = socket.assigns.reason_form || %ReasonCode{}

      case record |> ReasonCode.changeset(params) |> Repo.insert_or_update() do
        {:ok, _rc} ->
          {:noreply,
           socket
           |> assign(reason_form: nil, notice: "Reason code saved.")
           |> load_reason_codes()}

        {:error, cs} ->
          {:noreply, assign(socket, notice: "Could not save: #{changeset_errors(cs)}")}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot edit reason codes.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="component-panel">
      <%= case @view do %>
        <% :list -> %>
          <.render_list {assigns} />
        <% :detail -> %>
          <.render_detail {assigns} />
        <% :reason_codes -> %>
          <.render_reason_codes {assigns} />
      <% end %>
    </div>
    """
  end

  defp render_list(assigns) do
    ~H"""
    <.page_header title="Dispute Processing System" subtitle="Case list, deadlines, evidence, and case notes">
      <:actions>
        <button class="btn-sm" phx-click="show_reason_codes" phx-target={@myself}>Reason Codes</button>
        <button :if={@can_create} class="btn-sm btn-primary" phx-click="toggle_file_form" phx-target={@myself}>
          + File Dispute
        </button>
      </:actions>
    </.page_header>

    <.alert :if={@notice} kind={:info} message={@notice} />

    <.form_card :if={@show_file_form} title="File a New Dispute">
      <form phx-submit="file_dispute_submit" phx-target={@myself}>
        <.field label="Account ID" hint="Paste the account's UUID (from the Accounts screen)">
          <input type="text" name="dispute[account_id]" required />
        </.field>

        <.field label="Transaction Date"><input type="date" name="dispute[transaction_date]" required /></.field>
        <.field label="Dispute Amount"><input type="number" step="0.01" name="dispute[dispute_amount]" required /></.field>
        <.field label="Currency"><input type="text" name="dispute[currency]" value="MC" maxlength="3" /></.field>
        <.field label="Network">
          <select name="dispute[network]">
            <option value="MC">Mastercard</option>
            <option value="VI">Visa</option>
          </select>
        </.field>
        <.field label="Reason Code"><input type="text" name="dispute[reason_code]" required placeholder="e.g. 10.4" /></.field>

        <button type="submit" class="btn-sm btn-primary">File Dispute</button>
        <button type="button" class="btn-sm" phx-click="toggle_file_form" phx-target={@myself}>Cancel</button>
      </form>
    </.form_card>

    <div class="filter-tabs" style="margin-bottom:1rem">
      <button class={"btn-sm#{if @filter == "open", do: " active", else: ""}"}
              phx-click="filter" phx-value-status="open" phx-target={@myself}>Open</button>
      <button class={"btn-sm#{if @filter == "closed", do: " active", else: ""}"}
              phx-click="filter" phx-value-status="closed" phx-target={@myself}>Closed</button>
      <button :for={status <- @all_statuses || []}
              class={"btn-sm#{if @filter == status, do: " active", else: ""}"}
              phx-click="filter" phx-value-status={status} phx-target={@myself}>
        <%= status %>
      </button>
    </div>

    <.empty_state :if={@disputes == []} icon="📭" title="No disputes" message="Nothing matches this filter." />

    <div :if={@disputes != []} class="table-wrapper">
      <table class="data-table">
        <thead>
          <tr>
            <th>Filed</th><th>Account</th><th>Amount</th><th>Network</th>
            <th>Reason</th><th>Status</th><th>Assigned</th><th>Chargeback Deadline</th><th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{d, acc} <- @disputes} phx-click="open_case" phx-value-id={d.dispute_id}
              phx-target={@myself} style="cursor:pointer">
            <td><%= format_dt(d.filed_at) %></td>
            <td><%= acc && "****#{acc.last_four}" || "—" %></td>
            <td><%= d.currency %> <%= d.dispute_amount %></td>
            <td><%= d.network %></td>
            <td><%= d.reason_code %></td>
            <td><.status_badge status={d.status} /></td>
            <td><%= d.assigned_to || "—" %></td>
            <td><.deadline_badge date={d.chargeback_deadline} /></td>
            <td>→</td>
          </tr>
        </tbody>
      </table>
    </div>

    <div :if={@disputes != []} class="pagination" style="margin-top:0.75rem">
      <button class="btn-sm" phx-click="prev_page" phx-target={@myself} disabled={@page <= 1}>← Prev</button>
      <span style="margin:0 0.5rem">Page <%= @page %> · <%= @total %> total</span>
      <button class="btn-sm" phx-click="next_page" phx-target={@myself} disabled={@page * 25 >= @total}>Next →</button>
    </div>
    """
  end

  defp render_detail(assigns) do
    ~H"""
    <.page_header title={"Dispute #{short_id(@dispute.dispute_id)}"} subtitle={"Account **** #{@account && @account.last_four}"}>
      <:actions>
        <button class="btn-sm" phx-click="back_to_list" phx-target={@myself}>← Back to list</button>
      </:actions>
    </.page_header>

    <.alert :if={@notice} kind={:info} message={@notice} />

    <div class="detail-grid">
      <.form_card title="Case Summary">
        <.kv_detail rows={[
          {"Status", @dispute.status},
          {"Amount", "#{@dispute.currency} #{@dispute.dispute_amount}"},
          {"Network", @dispute.network},
          {"Reason Code", "#{@dispute.reason_code}#{@reason_info && " — #{@reason_info.description}" || ""}"},
          {"Transaction Date", @dispute.transaction_date},
          {"Filed At", format_dt(@dispute.filed_at)},
          {"Closed At", format_dt(@dispute.closed_at)},
          {"Provisional Credit Posted", if(@dispute.provisional_credit_posted, do: "Yes", else: "No")},
          {"Network Ref", @dispute.network_ref}
        ]} />

        <div :if={@dispute.status not in ["CLOSED_WIN", "CLOSED_LOSE", "CANCELLED"] and (@can_edit or @can_approve)} style="margin-top:1rem">
          <div class="form-section-title">Transition To</div>
          <form phx-submit="transition" phx-target={@myself}>
            <select name="status">
              <option :for={s <- @all_statuses} value={s} selected={s == @dispute.status}><%= s %></option>
            </select>
            <button type="submit" class="btn-sm btn-primary">Apply</button>
          </form>
        </div>
      </.form_card>

      <.form_card title="Deadline Monitor">
        <div class="kv-list">
          <div class="kv-row">
            <div class="kv-key">Provisional Credit Deadline</div>
            <div class="kv-val"><.deadline_badge date={@dispute.provisional_credit_deadline} /></div>
          </div>
          <div class="kv-row">
            <div class="kv-key">Chargeback Deadline</div>
            <div class="kv-val"><.deadline_badge date={@dispute.chargeback_deadline} /></div>
          </div>
          <div class="kv-row">
            <div class="kv-key">Representment Deadline</div>
            <div class="kv-val"><.deadline_badge date={@dispute.representment_deadline} /></div>
          </div>
          <div class="kv-row">
            <div class="kv-key">Pre-Arbitration Deadline</div>
            <div class="kv-val"><.deadline_badge date={@dispute.pre_arb_deadline} /></div>
          </div>
        </div>
      </.form_card>

      <.form_card title="Assignment">
        <p>Currently assigned to: <strong><%= @dispute.assigned_to || "Unassigned" %></strong></p>
        <button :if={@can_edit} class="btn-sm" phx-click="assign_to_me" phx-target={@myself}>Assign to me</button>
        <button :if={@can_edit and @dispute.assigned_to} class="btn-sm" phx-click="unassign" phx-target={@myself}>Unassign</button>
        <form :if={@can_edit} phx-submit="assign_submit" phx-target={@myself} style="margin-top:0.5rem">
          <input type="text" name="assignee" placeholder="operator username" />
          <button type="submit" class="btn-sm">Assign</button>
        </form>
      </.form_card>

      <.form_card title="Evidence">
        <form :if={@can_edit} phx-submit="save_evidence" phx-change="noop" phx-target={@myself}>
          <.live_file_input upload={@uploads.evidence} />
          <div :for={err <- upload_errors(@uploads.evidence)} class="field-error"><%= error_to_string(err) %></div>
          <div :for={entry <- @uploads.evidence.entries}>
            <%= entry.client_name %>
            <button type="button" phx-click="cancel_evidence_upload" phx-value-ref={entry.ref} phx-target={@myself}>✕</button>
          </div>
          <button type="submit" class="btn-sm btn-primary" style="margin-top:0.5rem">Upload</button>
        </form>

        <.empty_state :if={@evidence_list == []} icon="📎" title="No evidence attached" />

        <table :if={@evidence_list != []} class="data-table" style="margin-top:0.75rem">
          <thead><tr><th>File</th><th>Backend</th><th>Size</th><th>Uploaded By</th><th>At</th><th></th></tr></thead>
          <tbody>
            <tr :for={e <- @evidence_list}>
              <td><a href={"/visionplus/admin/dps/evidence/#{e.evidence_id}/download"} target="_blank"><%= e.filename %></a></td>
              <td><%= e.backend %></td>
              <td><%= format_bytes(e.size_bytes) %></td>
              <td><%= e.uploaded_by %></td>
              <td><%= format_dt(e.uploaded_at) %></td>
              <td>
                <button :if={@can_edit} class="btn-sm btn-warning" phx-click="delete_evidence"
                        phx-value-id={e.evidence_id} phx-target={@myself}>Delete</button>
              </td>
            </tr>
          </tbody>
        </table>
      </.form_card>

      <.form_card title="Case Notes">
        <form :if={@can_edit} phx-submit="add_note" phx-target={@myself}>
          <textarea name="note" rows="3" placeholder="Add a case note…"></textarea>
          <button type="submit" class="btn-sm btn-primary" style="margin-top:0.5rem">Add Note</button>
        </form>

        <.empty_state :if={@notes_list == []} icon="🗒️" title="No notes yet" />

        <div :for={n <- @notes_list} class="kv-row" style="flex-direction:column;align-items:flex-start">
          <div><strong><%= n.author %></strong> — <%= format_dt(n.created_at) %></div>
          <div><%= n.note %></div>
        </div>
      </.form_card>
    </div>
    """
  end

  defp render_reason_codes(assigns) do
    ~H"""
    <.page_header title="DPS Reason Codes" subtitle="Network dispute reason-code reference data (FR-DPS-004)">
      <:actions>
        <button class="btn-sm" phx-click="back_to_list" phx-target={@myself}>← Back to cases</button>
        <button :if={@can_edit} class="btn-sm btn-primary" phx-click="reason_code_new" phx-target={@myself}>+ New Reason Code</button>
      </:actions>
    </.page_header>

    <.alert :if={@notice} kind={:info} message={@notice} />

    <.form_card :if={@reason_form} title={if @reason_form.id, do: "Edit Reason Code", else: "New Reason Code"}>
      <form phx-submit="reason_code_save" phx-target={@myself}>
        <input type="hidden" name="reason_code[id]" value={@reason_form.id} />
        <.field label="Network">
          <select name="reason_code[network]">
            <option value="MC" selected={@reason_form.network == "MC"}>Mastercard</option>
            <option value="VI" selected={@reason_form.network == "VI"}>Visa</option>
          </select>
        </.field>
        <.field label="Reason Code"><input type="text" name="reason_code[reason_code]" value={@reason_form.reason_code} required /></.field>
        <.field label="Description"><input type="text" name="reason_code[description]" value={@reason_form.description} required /></.field>
        <.field label="Category"><input type="text" name="reason_code[category]" value={@reason_form.category} /></.field>
        <.field label="Dispute Window (days)"><input type="number" name="reason_code[dispute_window_days]" value={@reason_form.dispute_window_days} required /></.field>
        <.field label="Evidence Required (comma-separated)">
          <input type="text" name="reason_code[evidence_required]" value={Enum.join(@reason_form.evidence_required || [], ", ")} />
        </.field>
        <button type="submit" class="btn-sm btn-primary">Save</button>
        <button type="button" class="btn-sm" phx-click="reason_code_cancel" phx-target={@myself}>Cancel</button>
      </form>
    </.form_card>

    <table class="data-table">
      <thead><tr><th>Network</th><th>Code</th><th>Description</th><th>Category</th><th>Window (days)</th><th></th></tr></thead>
      <tbody>
        <tr :for={rc <- @reason_codes}>
          <td><%= rc.network %></td>
          <td><%= rc.reason_code %></td>
          <td><%= rc.description %></td>
          <td><%= rc.category %></td>
          <td><%= rc.dispute_window_days %></td>
          <td>
            <button :if={@can_edit} class="btn-sm" phx-click="reason_code_edit" phx-value-id={rc.id} phx-target={@myself}>Edit</button>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  # ---------------------------------------------------------------------------
  # Private — data loading
  # ---------------------------------------------------------------------------

  defp load_list(socket) do
    %{filter: filter, page: page} = socket.assigns
    offset = (page - 1) * @per_page

    statuses =
      case filter do
        "open" -> @open_statuses
        "closed" -> @closed_statuses
        status -> [status]
      end

    total =
      Repo.one(from d in Dispute, where: d.status in ^statuses, select: count(d.dispute_id))

    disputes =
      Repo.all(
        from d in Dispute,
          where: d.status in ^statuses,
          order_by: [desc: d.filed_at],
          limit: @per_page,
          offset: ^offset
      )

    # `dps_disputes.account_id` has no FK/format constraint (confirmed live —
    # a non-UUID value raises Ecto.Query.CastError, not a graceful miss) —
    # filter to castable UUIDs first so one bad/legacy account_id can't crash
    # the whole case list.
    account_ids = disputes |> Enum.map(& &1.account_id) |> Enum.uniq() |> Enum.filter(&valid_uuid?/1)
    accounts = Repo.all(from a in Account, where: a.account_id in ^account_ids) |> Map.new(&{&1.account_id, &1})

    rows = Enum.map(disputes, fn d -> {d, Map.get(accounts, d.account_id)} end)

    assign(socket, disputes: rows, total: total || 0, all_statuses: @all_statuses)
  end

  defp load_case(socket, dispute_id, notice \\ nil) do
    case Repo.get(Dispute, dispute_id) do
      nil ->
        assign(socket, notice: "Dispute not found.")

      dispute ->
        account = safe_get_account(dispute.account_id)
        reason_info = ReasonCode.get(dispute.network, dispute.reason_code)

        assign(socket,
          view: :detail,
          dispute: dispute,
          account: account,
          evidence_list: Evidence.list(dispute.dispute_id),
          notes_list: CaseNotes.list_notes(dispute.dispute_id),
          reason_info: reason_info,
          all_statuses: @all_statuses,
          notice: notice
        )
    end
  end

  defp load_reason_codes(socket) do
    codes = Repo.all(from r in ReasonCode, order_by: [asc: r.network, asc: r.reason_code])
    assign(socket, reason_codes: codes)
  end

  defp do_assign(socket, assignee) do
    if socket.assigns.can_edit do
      {:ok, _} = CaseNotes.assign(socket.assigns.dispute.dispute_id, assignee, socket.assigns.current_operator)
      {:noreply, load_case(socket, socket.assigns.dispute.dispute_id, "Assignment updated.")}
    else
      {:noreply, assign(socket, notice: "Your role cannot change case assignment.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — formatting
  # ---------------------------------------------------------------------------

  defp valid_uuid?(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp valid_uuid?(_), do: false

  defp safe_get_account(id) do
    if valid_uuid?(id), do: Repo.get(Account, id), else: nil
  end

  defp short_id(id), do: id |> to_string() |> String.slice(0, 8)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  defp split_csv(nil), do: []
  defp split_csv(s) when is_binary(s) do
    s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end
  defp split_csv(list) when is_list(list), do: list

  defp format_dt(nil), do: "—"
  defp format_dt(%Date{} = d), do: Date.to_string(d)
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp format_bytes(nil), do: "—"
  defp format_bytes(n) when n < 1024, do: "#{n} B"
  defp format_bytes(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp format_bytes(n), do: "#{Float.round(n / (1024 * 1024), 1)} MB"

  attr :date, :any, default: nil

  defp deadline_badge(assigns) do
    {cls, label} = deadline_info(assigns.date)
    assigns = assign(assigns, cls: cls, label: label)

    ~H"""
    <span class={"badge #{@cls}"}><%= @label %></span>
    """
  end

  defp deadline_info(nil), do: {"badge-gray", "—"}

  defp deadline_info(%Date{} = date) do
    days = Date.diff(date, Date.utc_today())

    cls =
      cond do
        days < 0 -> "badge-red"
        days <= 7 -> "badge-yellow"
        true -> "badge-green"
      end

    label =
      cond do
        days < 0 -> "#{Date.to_string(date)} (#{-days}d overdue)"
        days == 0 -> "#{Date.to_string(date)} (today)"
        true -> "#{Date.to_string(date)} (#{days}d left)"
      end

    {cls, label}
  end

  defp changeset_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, errs} -> "#{field}: #{Enum.join(errs, ", ")}" end)
    |> Enum.join("; ")
  end

  defp error_to_string(:too_large), do: "File too large"
  defp error_to_string(:too_many_files), do: "Only one file at a time"
  defp error_to_string(:not_accepted), do: "File type not accepted"
  defp error_to_string(other), do: inspect(other)
end
