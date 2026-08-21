defmodule VmuCoreWeb.Live.Admin.WpsComponent do
  @moduledoc """
  Admin LiveComponent for Wage Protection (WPS) — Phase W5.

  One component serving five nav items, selected by the `screen` assign:

  | screen | what it does |
  |---|---|
  | `wps_employers` | onboard employers, manage the worker roster |
  | `wps_files` | ingest a salary file, pre-flight it, post the batch |
  | `wps_exceptions` | the disbursement exception queue: retry or abandon |
  | `wps_refunds` | employer refunds under maker-checker |
  | `wps_reports` | generate and preview the regulator report |

  ## Why one component rather than five

  The five screens share one selection — *which employer* — and almost all of
  their state derives from it. Split across five LiveComponents that selection
  would have to be re-made, or lifted into the parent and threaded back down,
  for no gain: they are five views of one workflow, not five features.

  The nav still lists five items, because an operator looking for the exception
  queue should find "Disbursement Exceptions" rather than be told to open
  "WPS" and hunt for a tab.

  ## Pre-flight is a screen, not a confirmation dialog

  `Disbursement.pre_flight/1` runs on demand and its result stays on screen
  until the operator posts. A salary batch is irreversible in the way that
  matters — once a worker is paid, recovering it is an employer refund and a
  conversation — so seeing the seventeen unlinked workers *before* paying the
  other 383 is the point of the screen existing at all.
  """

  use Phoenix.LiveComponent

  import VmuCoreWeb.AdminUI
  import VmuCoreWeb.Components.AgGrid

  alias VmuCore.ASM.Authz
  alias VmuCore.WPS.{Disbursement, Ingestion, Refunds, RegulatoryReport, Roster}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       employers: [],
       employer: nil,
       links: [],
       files: [],
       file: nil,
       credits: [],
       parse_errors: [],
       pre_flight: nil,
       exceptions: [],
       exception_summary: %{},
       refunds: [],
       report: nil,
       report_from: Date.add(Date.utc_today(), -30),
       report_to: Date.utc_today(),
       active_action: :none,
       notice: nil,
       notice_kind: :info
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     socket
     |> load_employers()
     |> apply_deep_link()
     |> load_screen()}
  end

  # `?view=<employer_id>` preselects an employer, the same convention the other
  # product components use. It also means every screen is linkable — an
  # exception queue is something you send someone, not something they navigate
  # to from scratch.
  defp apply_deep_link(socket) do
    case {socket.assigns[:deep_link_id], socket.assigns[:employer]} do
      {nil, _} -> socket
      {_id, %{} = _already} -> socket
      {id, _} -> assign(socket, employer: Roster.get_employer(id))
    end
  end

  # ---------------------------------------------------------------------------
  # Loading
  # ---------------------------------------------------------------------------

  # Every employer, not a slice.
  #
  # `ASM.Operator` has a usually-nil `bank_scope` and no `sys_id` at all, so
  # there is no operator-to-institution binding to scope by — the other product
  # screens list across institutions for the same reason. Filtering by a guessed
  # institution would hide employers from the operator looking for them.
  defp load_employers(socket) do
    assign(socket, employers: Roster.list_employers())
  end

  # Each screen loads only what it shows. An operator opening the exception
  # queue should not pay for a file listing they cannot see.
  defp load_screen(%{assigns: %{employer: nil}} = socket), do: socket

  defp load_screen(socket) do
    employer_id = socket.assigns.employer.employer_id

    case socket.assigns[:screen] do
      "wps_employers" ->
        assign(socket, links: Roster.list_links(employer_id))

      "wps_files" ->
        files = Ingestion.list_files(employer_id)

        # Land on the most recent batch rather than an empty pane. The operator
        # opening this screen is almost always working the file that just
        # arrived, and a grid with nothing selected makes them click to get
        # where they were already going.
        case {socket.assigns[:file], files} do
          {nil, [latest | _]} -> socket |> assign(files: files) |> open_file(latest.wps_file_id)
          _ -> assign(socket, files: files)
        end

      "wps_exceptions" ->
        assign(socket,
          exceptions: Disbursement.open_exceptions(employer_id),
          exception_summary: Disbursement.exception_summary(employer_id)
        )

      "wps_refunds" ->
        assign(socket, refunds: Refunds.list(employer_id))

      _ ->
        socket
    end
  end

  # ---------------------------------------------------------------------------
  # Events — shared
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("select_employer", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(employer: Roster.get_employer(id), file: nil, pre_flight: nil, active_action: :none)
     |> load_screen()}
  end

  def handle_event("clear_employer", _params, socket) do
    {:noreply, assign(socket, employer: nil, file: nil, pre_flight: nil, active_action: :none)}
  end

  def handle_event("action", %{"a" => action}, socket) do
    {:noreply, assign(socket, active_action: String.to_existing_atom(action), notice: nil)}
  end

  def handle_event("action_close", _params, socket) do
    {:noreply, assign(socket, active_action: :none)}
  end

  # ---------------------------------------------------------------------------
  # Events — employers and roster
  # ---------------------------------------------------------------------------

  def handle_event("onboard_employer", %{"employer" => params}, socket) do
    guard(socket, "wps_employers", "edit", fn ->
      # The institution comes from the form. It cannot come from the operator —
      # `ASM.Operator` does not carry one — and defaulting it would file an
      # employer under the wrong bank silently.
      attrs =
        Map.take(params, ~w[sys_id bank_id employer_code employer_name regulator_id jurisdiction])

      case Roster.onboard_employer(atomise(attrs)) do
        {:ok, employer} ->
          socket
          |> assign(active_action: :none, employer: employer)
          |> notify(:success, "Employer #{employer.employer_name} onboarded.")
          |> load_employers()
          |> load_screen()

        {:error, changeset} ->
          notify(socket, :error, "Could not onboard: #{errors(changeset)}")
      end
    end)
  end

  def handle_event("link_worker", %{"link" => params}, socket) do
    guard(socket, "wps_employers", "edit", fn ->
      attrs = %{
        employer_id: socket.assigns.employer.employer_id,
        employee_id: params["employee_id"],
        employee_name: blank_to_nil(params["employee_name"]),
        prepaid_account_id: blank_to_nil(params["prepaid_account_id"]),
        linked_by: operator_name(socket)
      }

      case Roster.link(attrs) do
        {:ok, link} ->
          socket
          |> assign(active_action: :none)
          |> notify(:success, "#{link.employee_id} linked (#{link.status}).")
          |> load_screen()

        {:error, {:prepaid_account_not_found, _}} ->
          notify(socket, :error, "No prepaid account with that id.")

        {:error, changeset} ->
          notify(socket, :error, "Could not link: #{errors(changeset)}")
      end
    end)
  end

  def handle_event("suspend_link", %{"id" => employee_id}, socket) do
    guard(socket, "wps_employers", "edit", fn ->
      case Roster.suspend_link(socket.assigns.employer.employer_id, employee_id, "suspended by operator") do
        {:ok, _} ->
          socket
          |> notify(:success, "#{employee_id} suspended — no further salary will post.")
          |> load_screen()

        {:error, reason} ->
          notify(socket, :error, "Could not suspend: #{inspect(reason)}")
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Events — files
  # ---------------------------------------------------------------------------

  def handle_event("ingest_file", %{"file" => params}, socket) do
    guard(socket, "wps_files", "edit", fn ->
      filename = blank_to_nil(params["filename"]) || "pasted.csv"
      content = params["content"] || ""

      case Ingestion.ingest(socket.assigns.employer.employer_id, filename, content,
             uploaded_by: operator_name(socket)
           ) do
        {:ok, file, summary} ->
          socket
          |> assign(active_action: :none)
          |> notify(
            if(summary.errors > 0, do: :warning, else: :success),
            "#{filename}: #{summary.parsed} lines parsed, #{summary.errors} rejected."
          )
          |> load_screen()
          |> open_file(file.wps_file_id)

        {:error, :employer_not_configured} ->
          notify(
            socket,
            :error,
            "No file layout configured for this employer. Set wps.employer_config first — " <>
              "the layout is deliberately not guessed."
          )

        {:error, :duplicate_file} ->
          notify(socket, :error, "This exact file has already been ingested for this employer.")

        {:error, {:duplicate_payment_reference, ref, line}} ->
          notify(socket, :error, "Payment reference #{ref} (line #{line}) already exists.")

        {:error, reason} ->
          notify(socket, :error, "Ingest failed: #{inspect(reason)}")
      end
    end)
  end

  def handle_event("open_file", %{"id" => id}, socket) do
    {:noreply, open_file(socket, id)}
  end

  def handle_event("run_pre_flight", %{"id" => id}, socket) do
    case Disbursement.pre_flight(id) do
      {:ok, report} ->
        {:noreply, socket |> open_file(id) |> assign(pre_flight: report)}

      {:error, reason} ->
        {:noreply, notify(socket, :error, "Pre-flight failed: #{inspect(reason)}")}
    end
  end

  def handle_event("post_batch", %{"id" => id}, socket) do
    guard(socket, "wps_files", "edit", fn ->
      case Disbursement.post_batch(id, posted_by: operator_name(socket)) do
        {:ok, result} ->
          socket
          |> assign(pre_flight: nil)
          |> notify(
            if(result.failed > 0, do: :warning, else: :success),
            "Posted #{result.posted} payments totalling #{result.amount}. " <>
              "#{result.failed} went to the exception queue."
          )
          |> open_file(id)
          |> load_screen()

        {:error, :employer_not_disbursable} ->
          notify(socket, :error, "This employer is suspended — nothing can be disbursed.")

        {:error, reason} ->
          notify(socket, :error, "Batch failed: #{inspect(reason)}")
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Events — exceptions
  # ---------------------------------------------------------------------------

  def handle_event("retry_exception", %{"id" => id}, socket) do
    guard(socket, "wps_exceptions", "edit", fn ->
      case Disbursement.retry(id, posted_by: operator_name(socket)) do
        {:ok, credit} ->
          socket
          |> notify(:success, "#{credit.employee_id} paid — #{credit.net_amount}.")
          |> load_screen()

        {:error, reason} ->
          socket
          |> notify(:warning, "Still not payable: #{describe(reason)}")
          |> load_screen()
      end
    end)
  end

  def handle_event("abandon_exception", %{"id" => id}, socket) do
    guard(socket, "wps_exceptions", "edit", fn ->
      case Disbursement.abandon(id, "abandoned by operator", operator_name(socket)) do
        {:ok, _} ->
          socket
          |> notify(:success, "Closed without payment.")
          |> load_screen()

        {:error, reason} ->
          notify(socket, :error, "Could not close: #{inspect(reason)}")
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Events — refunds
  # ---------------------------------------------------------------------------

  def handle_event("request_refund", %{"refund" => params}, socket) do
    guard(socket, "wps_refunds", "view", fn ->
      amount = parse_decimal(params["amount"])

      opts =
        [reason: params["reason"] || "", requested_by: operator_name(socket)]
        |> then(fn o -> if amount, do: Keyword.put(o, :amount, amount), else: o end)

      case Refunds.request(params["salary_credit_id"], opts) do
        {:ok, _request} ->
          socket
          |> assign(active_action: :none)
          |> notify(:success, "Refund requested. It needs a different operator to approve it.")
          |> load_screen()

        {:error, {:not_posted, status}} ->
          notify(socket, :error, "That payment is #{status}, not POSTED — nothing to recover.")

        {:error, {:exceeds_credit, paid}} ->
          notify(socket, :error, "More than was paid (#{paid}).")

        {:error, changeset} ->
          notify(socket, :error, "Could not request: #{errors(changeset)}")
      end
    end)
  end

  def handle_event("approve_refund", %{"id" => id}, socket) do
    guard(socket, "wps_refunds", "edit", fn ->
      case Refunds.approve(id, operator_name(socket), "approved in admin console") do
        {:ok, _} ->
          socket
          |> notify(:success, "Refund approved — the money has been recovered.")
          |> load_screen()

        {:error, :maker_cannot_be_checker} ->
          notify(
            socket,
            :error,
            "You raised this request, so you cannot approve it. That is the control, not a bug."
          )

        {:error, :insufficient_funds} ->
          socket
          |> notify(
            :warning,
            "The worker has already spent these wages, so they cannot be recovered. " <>
              "The request is recorded as FAILED."
          )
          |> load_screen()

        {:error, reason} ->
          notify(socket, :error, "Could not approve: #{inspect(reason)}")
      end
    end)
  end

  def handle_event("reject_refund", %{"id" => id}, socket) do
    guard(socket, "wps_refunds", "edit", fn ->
      case Refunds.reject(id, operator_name(socket), "rejected in admin console") do
        {:ok, _} ->
          socket |> notify(:success, "Refund rejected.") |> load_screen()

        {:error, :maker_cannot_be_checker} ->
          notify(socket, :error, "You raised this request, so you cannot decide it.")

        {:error, reason} ->
          notify(socket, :error, "Could not reject: #{inspect(reason)}")
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Events — reports
  # ---------------------------------------------------------------------------

  def handle_event("generate_report", %{"report" => params}, socket) do
    from = parse_date(params["from"]) || socket.assigns.report_from
    to = parse_date(params["to"]) || socket.assigns.report_to

    case RegulatoryReport.generate(socket.assigns.employer.employer_id, from, to) do
      {:ok, report} ->
        {:noreply, assign(socket, report: report, report_from: from, report_to: to)}

      {:error, reason} ->
        {:noreply, notify(socket, :error, "Could not generate: #{inspect(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp open_file(socket, id) do
    case Ingestion.get_file(id) do
      nil ->
        socket

      file ->
        assign(socket,
          file: file,
          credits: Ingestion.list_credits(file.wps_file_id),
          parse_errors: Ingestion.parse_errors(file)
        )
    end
  end

  # Every mutating event goes through here. The screen also hides the control,
  # but hiding a button is presentation — this is the check that matters.
  defp guard(socket, module, action, fun) do
    if Authz.can?(socket.assigns[:current_operator], module, action) do
      {:noreply, fun.()}
    else
      {:noreply, notify(socket, :error, "You do not have #{module}:#{action} permission.")}
    end
  end

  # Takes the assigns map, because that is what a template has. `guard/4` is
  # the socket-side equivalent and the one that actually protects anything.
  defp can?(assigns, module, action),
    do: Authz.can?(assigns[:current_operator], module, action)

  defp notify(socket, kind, message), do: assign(socket, notice: message, notice_kind: kind)

  defp operator_name(socket) do
    op = socket.assigns[:current_operator] || %{}
    Map.get(op, :username) || Map.get(op, :name) || "unknown"
  end

  defp atomise(map), do: Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(v) do
    case String.trim(to_string(v)) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp parse_decimal(v) do
    case blank_to_nil(v) do
      nil ->
        nil

      s ->
        case Decimal.parse(s) do
          {d, _} -> d
          :error -> nil
        end
    end
  end

  defp parse_date(v) do
    case blank_to_nil(v) do
      nil -> nil
      s -> case Date.from_iso8601(s) do
             {:ok, d} -> d
             _ -> nil
           end
    end
  end

  defp errors(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp errors(other), do: inspect(other)

  defp describe(:not_linked), do: "the worker is still not linked to an account"
  defp describe({:not_payable, status}), do: "the link is #{status}"
  defp describe(:prepaid_account_not_active), do: "the account is not active"
  defp describe(other), do: inspect(other)

  defp money(nil), do: "—"
  defp money(%Decimal{} = d), do: Decimal.to_string(Decimal.round(d, 2))
  defp money(other), do: to_string(other)

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.alert :if={@notice} kind={@notice_kind} message={@notice} />

      <%= if is_nil(@employer) do %>
        <.employer_picker employers={@employers} screen={@screen} myself={@myself}
                          can_edit={can?(assigns, "wps_employers", "edit")}
                          active_action={@active_action} />
      <% else %>
        <.page_header title={@employer.employer_name}
                      subtitle={"#{@employer.employer_code} · #{@employer.status} · #{screen_label(@screen)}"}>
          <:actions>
            <button class="btn btn-ghost btn-sm" phx-click="clear_employer" phx-target={@myself}>
              ← All employers
            </button>
          </:actions>
        </.page_header>

        <%= case @screen do %>
          <% "wps_employers" -> %>
            <.roster {assigns} />
          <% "wps_files" -> %>
            <.files {assigns} />
          <% "wps_exceptions" -> %>
            <.exceptions {assigns} />
          <% "wps_refunds" -> %>
            <.refunds {assigns} />
          <% "wps_reports" -> %>
            <.reports {assigns} />
          <% _ -> %>
            <.empty_state title="Unknown WPS screen" />
        <% end %>
      <% end %>
    </div>
    """
  end

  defp screen_label("wps_employers"), do: "Employers & Roster"
  defp screen_label("wps_files"), do: "Salary Files"
  defp screen_label("wps_exceptions"), do: "Disbursement Exceptions"
  defp screen_label("wps_refunds"), do: "Employer Refunds"
  defp screen_label("wps_reports"), do: "Regulatory Reports"
  defp screen_label(other), do: to_string(other)

  # ── Employer picker ────────────────────────────────────────────────────────

  attr :employers, :list, required: true
  attr :screen, :string, required: true
  attr :myself, :any, required: true
  attr :can_edit, :boolean, required: true
  attr :active_action, :atom, required: true

  defp employer_picker(assigns) do
    ~H"""
    <.page_header title="Wage Protection (WPS)"
                  subtitle="Select an employer to work with">
      <:actions>
        <button :if={@can_edit and @screen == "wps_employers"} class="btn btn-primary btn-sm"
                phx-click="action" phx-value-a="onboard" phx-target={@myself}>
          + Onboard employer
        </button>
      </:actions>
    </.page_header>

    <div :if={@active_action == :onboard} class="action-panel" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>Onboard employer</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕</button>
      </div>
      <form id="wps-onboard-form" phx-submit="onboard_employer" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">System ID *</label>
            <input class="input" name="employer[sys_id]" required maxlength="4" placeholder="MMPD" />
          </div>
          <div class="form-group">
            <label class="form-label">Bank ID *</label>
            <input class="input" name="employer[bank_id]" required maxlength="4" placeholder="MMBD" />
          </div>
          <div class="form-group">
            <label class="form-label">Employer code *</label>
            <input class="input" name="employer[employer_code]" required maxlength="40" />
          </div>
          <div class="form-group">
            <label class="form-label">Employer name *</label>
            <input class="input" name="employer[employer_name]" required maxlength="200" />
          </div>
          <div class="form-group">
            <label class="form-label">Regulator ID</label>
            <input class="input" name="employer[regulator_id]" maxlength="60"
                   placeholder="MOHRE establishment id, or the local equivalent" />
          </div>
          <div class="form-group">
            <label class="form-label">Jurisdiction</label>
            <input class="input" name="employer[jurisdiction]" maxlength="8" placeholder="AE" />
          </div>
        </div>
        <div style="display:flex; gap:8px; margin-top:12px;">
          <button type="submit" class="btn btn-primary">Onboard</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>

    <%= if @employers == [] do %>
      <.empty_state title="No employers yet" message="Onboard an employer to start receiving salary files." />
    <% else %>
      <.ag_grid
        id="wps-employers-grid"
        columns={[
          %{field: "employer_code", header: "Code", type: "mono"},
          %{field: "employer_name", header: "Employer"},
          %{field: "jurisdiction", header: "Jurisdiction"},
          %{field: "regulator_id", header: "Regulator ID"},
          %{field: "status", header: "Status", type: "badge"},
          %{field: "actions", header: "", type: "actions",
            actions: [%{label: "Open", event: "select_employer", param: "id"}]}
        ]}
        rows={Enum.map(@employers, fn e -> %{
          "id" => e.employer_id,
          "employer_code" => e.employer_code,
          "employer_name" => e.employer_name,
          "jurisdiction" => e.jurisdiction || "—",
          "regulator_id" => e.regulator_id || "—",
          "status" => e.status
        } end)}
      />
    <% end %>
    """
  end

  # ── Roster ─────────────────────────────────────────────────────────────────

  defp roster(assigns) do
    ~H"""
    <div class="page-header-actions" style="margin-bottom:12px;">
      <button :if={can?(assigns, "wps_employers", "edit")} class="btn btn-primary btn-sm"
              phx-click="action" phx-value-a="link" phx-target={@myself}>
        + Link worker
      </button>
    </div>

    <div :if={@active_action == :link} class="action-panel" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>Link a worker to a disbursement account</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕</button>
      </div>
      <p class="cell-note">
        Leave the account blank to record the worker as <strong>UNVERIFIED</strong> — the
        salary file can still be ingested, and the line lands in the exception queue instead
        of being dropped.
      </p>
      <form id="wps-link-form" phx-submit="link_worker" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">Employee ID * <span class="cell-note">(the employer's own)</span></label>
            <input class="input" name="link[employee_id]" required maxlength="60" />
          </div>
          <div class="form-group">
            <label class="form-label">Employee name</label>
            <input class="input" name="link[employee_name]" maxlength="200" />
          </div>
          <div class="form-group" style="grid-column:1/-1;">
            <label class="form-label">Prepaid account ID</label>
            <input class="input" name="link[prepaid_account_id]" placeholder="UUID of the worker's prepaid account"
                   style="font-family:monospace;" />
          </div>
        </div>
        <div style="display:flex; gap:8px; margin-top:12px;">
          <button type="submit" class="btn btn-primary">Link</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>

    <%= if @links == [] do %>
      <.empty_state title="No workers on the roster" message="Link a worker, or ingest a salary file and link the ones it names." />
    <% else %>
      <.ag_grid
        id="wps-roster-grid"
        columns={[
          %{field: "employee_id", header: "Employee ID", type: "mono"},
          %{field: "employee_name", header: "Name"},
          %{field: "prepaid_account_id", header: "Account", type: "mono"},
          %{field: "status", header: "Status", type: "badge"},
          %{field: "actions", header: "", type: "actions",
            actions: [%{label: "Suspend", event: "suspend_link", param: "employee_id",
                        whenField: "status", whenValue: "ACTIVE", danger: true,
                        confirm: "Suspend {employee_id}? No further salary will post to them."}]}
        ]}
        rows={Enum.map(@links, fn l -> %{
          "employee_id" => l.employee_id,
          "employee_name" => l.employee_name || "—",
          "prepaid_account_id" => (l.prepaid_account_id && String.slice(l.prepaid_account_id, 0, 8)) || "—",
          "status" => l.status
        } end)}
      />
    <% end %>
    """
  end

  # ── Files ──────────────────────────────────────────────────────────────────

  defp files(assigns) do
    ~H"""
    <div class="page-header-actions" style="margin-bottom:12px;">
      <button :if={can?(assigns, "wps_files", "edit")} class="btn btn-primary btn-sm"
              phx-click="action" phx-value-a="ingest" phx-target={@myself}>
        + Ingest salary file
      </button>
    </div>

    <div :if={@active_action == :ingest} class="action-panel" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>Ingest a salary file</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕</button>
      </div>
      <p class="cell-note">
        Parsed with this employer's configured layout (<code>wps.employer_config</code>).
        Nothing is paid here — ingesting is safe, and posting is a separate step behind
        a pre-flight report.
      </p>
      <form id="wps-ingest-form" phx-submit="ingest_file" phx-target={@myself}>
        <div class="form-group">
          <label class="form-label">Filename</label>
          <input class="input" name="file[filename]" placeholder="july-2026.csv" />
        </div>
        <div class="form-group">
          <label class="form-label">File content *</label>
          <textarea class="input" name="file[content]" rows="10" required
                    style="font-family:monospace; font-size:12px;"></textarea>
        </div>
        <div style="display:flex; gap:8px; margin-top:12px;">
          <button type="submit" class="btn btn-primary">Ingest</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>

    <%= if @files == [] do %>
      <.empty_state title="No salary files yet" message="Ingesting a file parses and stores it. Nothing is paid until you post the batch." />
    <% else %>
      <.ag_grid
        id="wps-files-grid"
        columns={[
          %{field: "filename", header: "File"},
          %{field: "ingested_at", header: "Ingested", type: "date"},
          %{field: "parsed_count", header: "Lines", type: "number"},
          %{field: "error_count", header: "Rejected", type: "number"},
          %{field: "total_net_amount", header: "Total Net", type: "money"},
          %{field: "status", header: "Status", type: "badge"},
          %{field: "actions", header: "", type: "actions",
            actions: [
              %{label: "Open", event: "open_file", param: "id"},
              %{label: "Pre-flight", event: "run_pre_flight", param: "id"}
            ]}
        ]}
        rows={Enum.map(@files, fn f -> %{
          "id" => f.wps_file_id,
          "filename" => f.filename,
          "ingested_at" => f.ingested_at && DateTime.to_iso8601(f.ingested_at),
          "parsed_count" => f.parsed_count,
          "error_count" => f.error_count,
          "total_net_amount" => Decimal.to_string(f.total_net_amount || Decimal.new(0)),
          "status" => f.status
        } end)}
      />
    <% end %>

    <.pre_flight_panel :if={@pre_flight} report={@pre_flight} file={@file} myself={@myself}
                       can_post={can?(assigns, "wps_files", "edit")} />

    <div :if={@file} style="margin-top:20px;">
      <div class="form-pane-section-title" style="display:flex;justify-content:space-between;align-items:center;">
        <span><%= @file.filename %> — <%= length(@credits) %> lines</span>
        <button id="wps-preflight-btn" class="btn btn-ghost btn-sm"
                phx-click="run_pre_flight" phx-value-id={@file.wps_file_id} phx-target={@myself}>
          Run pre-flight
        </button>
      </div>

      <.ag_grid
        id="wps-credits-grid"
        columns={[
          %{field: "line_number", header: "Line", type: "number"},
          %{field: "employee_id", header: "Employee", type: "mono"},
          %{field: "payment_reference", header: "Reference", type: "mono"},
          %{field: "net_amount", header: "Net", type: "money"},
          %{field: "payment_date", header: "Pay Date", type: "date"},
          %{field: "status", header: "Status", type: "badge"},
          %{field: "failure_reason", header: "Reason"}
        ]}
        rows={Enum.map(@credits, fn c -> %{
          "line_number" => c.line_number,
          "employee_id" => c.employee_id,
          "payment_reference" => c.payment_reference,
          "net_amount" => Decimal.to_string(c.net_amount),
          "payment_date" => c.payment_date && Date.to_iso8601(c.payment_date),
          "status" => c.status,
          "failure_reason" => c.failure_reason || ""
        } end)}
      />

      <div :if={@parse_errors != []} style="margin-top:16px;">
        <div class="form-pane-section-title">
          Rejected lines (<%= length(@parse_errors) %>)
        </div>
        <p class="cell-note">
          These never became payment instructions. The rest of the file was still ingested —
          a typo on one line does not discard the others.
        </p>
        <.ag_grid
          id="wps-parse-errors-grid"
          columns={[
            %{field: "line_number", header: "Line", type: "number"},
            %{field: "field", header: "Field"},
            %{field: "error", header: "Problem"},
            %{field: "raw", header: "Raw line", type: "mono"}
          ]}
          rows={Enum.map(@parse_errors, fn e -> %{
            "line_number" => e["line_number"],
            "field" => e["field"],
            "error" => e["error"],
            "raw" => e["raw"]
          } end)}
        />
      </div>
    </div>
    """
  end

  attr :report, :map, required: true
  attr :file, :any, required: true
  attr :myself, :any, required: true
  attr :can_post, :boolean, required: true

  defp pre_flight_panel(assigns) do
    ~H"""
    <div class="action-panel" style="margin-top:16px;border-color:#a5b4fc;background:#eef2ff;">
      <div class="action-panel-title"><span>Pre-flight — nothing has moved yet</span></div>

      <div class="stat-row">
        <span class="stat"><strong><%= @report.payable_count %></strong> payable</span>
        <span class="stat"><strong><%= money(@report.payable_total) %></strong> to pay</span>
        <span class={["stat", @report.blocked_count > 0 && "alert"]}>
          <strong><%= @report.blocked_count %></strong> blocked
        </span>
        <span :if={@report.already_posted_count > 0} class="stat">
          <strong><%= @report.already_posted_count %></strong> already paid
        </span>
      </div>

      <div :if={not @report.employer_disbursable} class="alert alert-error" style="margin-top:10px;">
        <span>This employer is suspended — nothing can be disbursed.</span>
      </div>

      <div :if={@report.blockers != %{}} style="margin-top:12px;">
        <table class="data-table">
          <thead><tr><th>Blocked by</th><th>Workers</th><th>Amount</th><th>Employees</th></tr></thead>
          <tbody>
            <tr :for={{type, detail} <- @report.blockers}>
              <td><span class="badge badge-yellow"><%= type %></span></td>
              <td><%= detail.count %></td>
              <td class="mono"><%= money(detail.total) %></td>
              <td style="font-size:12px;"><%= Enum.join(Enum.take(detail.employees, 8), ", ") %><%= if length(detail.employees) > 8, do: " …" %></td>
            </tr>
          </tbody>
        </table>
        <p class="cell-note">
          Blocked lines are not paid and are not lost — posting sends them to the exception
          queue, where they can be fixed and retried.
        </p>
      </div>

      <div style="display:flex; gap:8px; margin-top:12px;">
        <button :if={@can_post and @report.employer_disbursable and @report.payable_count > 0}
                class="btn btn-primary"
                phx-click="post_batch" phx-value-id={@file.wps_file_id} phx-target={@myself}
                data-confirm={"Pay #{@report.payable_count} workers, #{money(@report.payable_total)}? This cannot be undone without an employer refund."}>
          Post <%= @report.payable_count %> payments
        </button>
      </div>
    </div>
    """
  end

  # ── Exceptions ─────────────────────────────────────────────────────────────

  defp exceptions(assigns) do
    ~H"""
    <div :if={@exception_summary != %{}} class="stat-row" style="margin-bottom:12px;">
      <span :for={{type, detail} <- @exception_summary} class="stat">
        <strong><%= detail.count %></strong> <%= type %> · <%= money(detail.total) %>
      </span>
    </div>

    <%= if @exceptions == [] do %>
      <.empty_state title="No open exceptions" message="Every line in every batch was paid." />
    <% else %>
      <p class="cell-note">
        Each of these is a worker who was not paid. Fix the cause — usually by linking the
        worker on the Roster screen — then retry.
      </p>
      <.ag_grid
        id="wps-exceptions-grid"
        columns={[
          %{field: "employee_id", header: "Employee", type: "mono"},
          %{field: "payment_reference", header: "Reference", type: "mono"},
          %{field: "net_amount", header: "Amount", type: "money"},
          %{field: "exception_type", header: "Cause", type: "badge", classField: "badge_class"},
          %{field: "reason", header: "Detail"},
          %{field: "attempt_count", header: "Attempts", type: "number"},
          %{field: "actions", header: "", type: "actions",
            actions: [
              %{label: "Retry", event: "retry_exception", param: "id"},
              %{label: "Abandon", event: "abandon_exception", param: "id", danger: true,
                confirm: "Close {employee_id} without paying? This is a regulated payment instruction."}
            ]}
        ]}
        rows={Enum.map(@exceptions, fn e -> %{
          "id" => e.exception_id,
          "employee_id" => e.salary_credit && e.salary_credit.employee_id,
          "payment_reference" => e.salary_credit && e.salary_credit.payment_reference,
          "net_amount" => e.salary_credit && Decimal.to_string(e.salary_credit.net_amount),
          "exception_type" => e.exception_type,
          "badge_class" => "badge-yellow",
          "reason" => e.reason,
          "attempt_count" => e.attempt_count
        } end)}
      />
    <% end %>
    """
  end

  # ── Refunds ────────────────────────────────────────────────────────────────

  defp refunds(assigns) do
    ~H"""
    <div class="page-header-actions" style="margin-bottom:12px;">
      <button class="btn btn-primary btn-sm" phx-click="action" phx-value-a="refund" phx-target={@myself}>
        + Request refund
      </button>
    </div>

    <div :if={@active_action == :refund} class="action-panel" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>Request an employer refund</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕</button>
      </div>
      <p class="cell-note">
        Recovers money already paid to a worker, so it needs a <strong>different</strong>
        operator to approve. Wages the worker has already spent cannot be recovered.
      </p>
      <form id="wps-refund-form" phx-submit="request_refund" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group" style="grid-column:1/-1;">
            <label class="form-label">Salary credit ID *</label>
            <input class="input" name="refund[salary_credit_id]" required
                   placeholder="UUID from the Salary Files screen" style="font-family:monospace;" />
          </div>
          <div class="form-group">
            <label class="form-label">Amount <span class="cell-note">(blank = the whole payment)</span></label>
            <input class="input" name="refund[amount]" placeholder="500.00" />
          </div>
          <div class="form-group">
            <label class="form-label">Reason * (min 5 chars)</label>
            <input class="input" name="refund[reason]" required minlength="5" maxlength="500" />
          </div>
        </div>
        <div style="display:flex; gap:8px; margin-top:12px;">
          <button type="submit" class="btn btn-primary">Request</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>

    <% pending = Enum.filter(@refunds, &(&1.status == "PENDING")) %>

    <div :if={pending != []} class="action-panel" style="margin-bottom:16px;border-color:#fcd34d;background:#fef3c7;">
      <div class="action-panel-title"><span>Awaiting a decision (<%= length(pending) %>)</span></div>
      <p class="cell-note">
        Approving recovers money from a worker's account. You cannot decide a request you
        raised yourself — that is the control, and it is enforced on the record, not just here.
      </p>
      <table class="data-table">
        <thead><tr><th>Employee</th><th>Amount</th><th>Reason</th><th>Requested by</th><th></th></tr></thead>
        <tbody>
          <tr :for={r <- pending}>
            <td class="mono"><%= r.salary_credit && r.salary_credit.employee_id %></td>
            <td class="mono"><%= money(r.amount) %></td>
            <td style="font-size:12px;"><%= r.reason %></td>
            <td><%= r.requested_by %></td>
            <td style="white-space:nowrap;">
              <button class="btn btn-primary btn-xs"
                      id={"wps-approve-#{r.refund_request_id}"}
                      phx-click="approve_refund" phx-value-id={r.refund_request_id} phx-target={@myself}
                      data-confirm={"Recover #{money(r.amount)} from this worker?"}>
                Approve
              </button>
              <button class="btn btn-ghost btn-xs"
                      id={"wps-reject-#{r.refund_request_id}"}
                      phx-click="reject_refund" phx-value-id={r.refund_request_id} phx-target={@myself}>
                Reject
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <%= if @refunds == [] do %>
      <.empty_state title="No refund requests" />
    <% else %>
      <.ag_grid
        id="wps-refunds-grid"
        columns={[
          %{field: "employee_id", header: "Employee", type: "mono"},
          %{field: "amount", header: "Amount", type: "money"},
          %{field: "reason", header: "Reason"},
          %{field: "requested_by", header: "Requested by"},
          %{field: "status", header: "Status", type: "badge", classField: "badge_class"},
          %{field: "decided_by", header: "Decided by"},
          %{field: "actions", header: "", type: "actions",
            actions: [
              %{label: "Approve", event: "approve_refund", param: "id",
                whenField: "status", whenValue: "PENDING",
                confirm: "Recover {amount} from {employee_id}?"},
              %{label: "Reject", event: "reject_refund", param: "id",
                whenField: "status", whenValue: "PENDING", danger: true}
            ]}
        ]}
        rows={Enum.map(@refunds, fn r -> %{
          "id" => r.refund_request_id,
          "employee_id" => r.salary_credit && r.salary_credit.employee_id,
          "amount" => Decimal.to_string(r.amount),
          "reason" => r.reason,
          "requested_by" => r.requested_by,
          "status" => r.status,
          "badge_class" => refund_badge(r.status),
          "decided_by" => r.decided_by || "—"
        } end)}
      />
    <% end %>
    """
  end

  # FAILED is amber rather than red: nobody did anything wrong, the wages had
  # already been spent. REJECTED is a decision and reads as one.
  defp refund_badge("APPROVED"), do: "badge-green"
  defp refund_badge("REJECTED"), do: "badge-red"
  defp refund_badge("FAILED"), do: "badge-yellow"
  defp refund_badge(_), do: "badge-gray"

  # ── Reports ────────────────────────────────────────────────────────────────

  defp reports(assigns) do
    ~H"""
    <form id="wps-report-form" phx-submit="generate_report" phx-target={@myself} class="action-panel" style="margin-bottom:16px;">
      <div class="action-panel-title"><span>Generate the regulator report</span></div>
      <p class="cell-note">
        Covers every salary credit whose <strong>pay date</strong> falls in the period — paid
        and unpaid alike, because a Wage Protection scheme exists to make non-payment visible.
      </p>
      <div style="display:flex; gap:8px; flex-wrap:wrap; align-items:flex-end;">
        <div class="form-group">
          <label class="form-label">From</label>
          <input type="date" class="input" name="report[from]" value={Date.to_iso8601(@report_from)} />
        </div>
        <div class="form-group">
          <label class="form-label">To</label>
          <input type="date" class="input" name="report[to]" value={Date.to_iso8601(@report_to)} />
        </div>
        <button type="submit" class="btn btn-primary">Generate</button>
      </div>
    </form>

    <%= if @report do %>
      <div class="stat-row" style="margin-bottom:12px;">
        <span class="stat"><strong><%= @report.summary.total_count %></strong> workers</span>
        <span class="stat"><strong><%= @report.summary.paid_count %></strong> paid · <%= money(@report.summary.paid_total) %></span>
        <span class={["stat", @report.summary.unpaid_count > 0 && "alert"]}>
          <strong><%= @report.summary.unpaid_count %></strong> not paid · <%= money(@report.summary.unpaid_total) %>
        </span>
      </div>

      <%= if @report.rows == [] do %>
        <.empty_state title="Nothing in this period" message="No salary credits have a pay date between these dates." />
      <% else %>
        <.ag_grid
          id="wps-report-grid"
          columns={[
            %{field: "employee_id", header: "Employee", type: "mono"},
            %{field: "employee_name", header: "Name"},
            %{field: "payment_reference", header: "Reference", type: "mono"},
            %{field: "net_amount", header: "Amount", type: "money"},
            %{field: "payment_date", header: "Pay Date", type: "date"},
            %{field: "status", header: "Status", type: "badge", classField: "badge_class"},
            %{field: "failure_reason", header: "Why not paid"}
          ]}
          rows={Enum.map(@report.rows, fn r -> %{
            "employee_id" => r.employee_id,
            "employee_name" => r.employee_name || "—",
            "payment_reference" => r.payment_reference,
            "net_amount" => Decimal.to_string(r.net_amount),
            "payment_date" => r.payment_date && Date.to_iso8601(r.payment_date),
            "status" => r.status,
            "badge_class" => if(r.status == "PAID", do: "badge-green", else: "badge-red"),
            "failure_reason" => r.failure_reason || ""
          } end)}
        />
      <% end %>

      <p class="cell-note" style="margin-top:12px;">
        Generation only. Filing this with the regulator — directly or through an exchange
        house — is a business arrangement and is not built.
      </p>
    <% end %>
    """
  end
end
