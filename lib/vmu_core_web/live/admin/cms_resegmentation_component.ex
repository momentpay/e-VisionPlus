defmodule VmuCoreWeb.Live.Admin.CmsResegmentationComponent do
  @moduledoc """
  Admin LiveComponent: cycle resegmentation batch (CMS FR-058). Pick a
  sys/bank/logo scope, view the current cycle_code distribution + whether
  it's imbalanced (per that bank's configured
  `resegmentation_rebalance_threshold_pct`), propose a rebalance, review
  the real proposed moves, and apply them (schedules each — never an
  instant change, see `VmuCore.CMS.CycleResegmentation`). Also lists and
  lets ops cancel already-scheduled-but-not-yet-effective changes.

  All region/regulatory policy (notice period, minimum interval, allowed
  billing days, rebalance threshold, manual-vs-auto mode) is edited on the
  existing **Module Configuration** admin screen (`cms` module, added
  alongside cta/asm/dps) — this screen only *acts* within whatever policy
  is currently configured for the scope in view.
  """

  use Phoenix.LiveComponent
  import VmuCoreWeb.AdminUI
  import VmuCoreWeb.Components.AgGrid

  alias VmuCore.CMS.CycleResegmentation
  alias VmuCore.ASM.Authz

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       sys_id: "",
       bank_id: "",
       logo_id: "",
       scope_loaded: false,
       analysis: nil,
       proposal: nil,
       pending: [],
       notice: nil,
       can_edit: false
     )}
  end

  @impl true
  def update(assigns, socket) do
    operator = assigns[:current_operator]
    socket = assign(socket, assigns)

    socket =
      if operator do
        assign(socket, can_edit: Authz.can?(operator, "cms_resegmentation", "edit"))
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("load_scope", %{"sys_id" => sys_id, "bank_id" => bank_id, "logo_id" => logo_id}, socket) do
    sys_id = String.trim(sys_id)
    bank_id = String.trim(bank_id)
    logo_id = String.trim(logo_id)

    if sys_id == "" or bank_id == "" or logo_id == "" do
      {:noreply, assign(socket, notice: "Enter sys_id, bank_id, and logo_id.")}
    else
      {:noreply,
       socket
       |> assign(sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, scope_loaded: true, proposal: nil, notice: nil)
       |> reload()}
    end
  end

  def handle_event("propose", _, socket) do
    %{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id} = socket.assigns
    {:ok, proposal} = CycleResegmentation.propose_rebalance(sys_id, bank_id, logo_id)
    {:noreply, assign(socket, proposal: proposal)}
  end

  def handle_event("apply_proposal", _, socket) do
    if socket.assigns.can_edit do
      moves = get_in(socket.assigns, [Access.key(:proposal), Access.key(:moves)]) || []
      operator = socket.assigns[:current_operator]

      results = Enum.map(moves, &CycleResegmentation.schedule_resegmentation(&1.account_id, &1.to_cycle_code, operator))
      ok_count = Enum.count(results, &match?({:ok, _}, &1))

      {:noreply,
       socket
       |> assign(proposal: nil, notice: "Scheduled #{ok_count} of #{length(moves)} proposed move(s).")
       |> reload()}
    else
      {:noreply, assign(socket, notice: "Your role cannot apply resegmentation changes.")}
    end
  end

  def handle_event("cancel_pending", %{"id" => account_id}, socket) do
    if socket.assigns.can_edit do
      operator = socket.assigns[:current_operator]

      case CycleResegmentation.cancel_pending(account_id, operator) do
        :ok -> {:noreply, socket |> assign(notice: "Pending change cancelled.") |> reload()}
        {:error, reason} -> {:noreply, assign(socket, notice: "Could not cancel: #{inspect(reason)}")}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot cancel resegmentation changes.")}
    end
  end

  defp reload(socket) do
    %{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id} = socket.assigns

    assign(socket,
      analysis: CycleResegmentation.analyze_distribution(sys_id, bank_id, logo_id),
      pending: CycleResegmentation.list_pending(sys_id, bank_id, logo_id)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="component-panel">
      <.page_header title="Cycle Resegmentation" subtitle="Rebalance billing-day distribution (FR-058) — policy is configured per bank in Module Configuration">
      </.page_header>

      <.alert :if={@notice} kind={:info} message={@notice} />

      <.form_card title="Scope">
        <form phx-submit="load_scope" phx-target={@myself} style="display:flex;gap:12px;align-items:flex-end;flex-wrap:wrap">
          <.field label="Sys ID"><input type="text" name="sys_id" value={@sys_id} /></.field>
          <.field label="Bank ID"><input type="text" name="bank_id" value={@bank_id} /></.field>
          <.field label="Logo ID"><input type="text" name="logo_id" value={@logo_id} /></.field>
          <button type="submit" class="btn-sm btn-primary">Load</button>
        </form>
      </.form_card>

      <%= if @scope_loaded and @analysis do %>
        <.form_card title="Current Distribution">
          <.kv_detail rows={[
            {"Total active accounts", @analysis.total_accounts},
            {"Allowed cycle codes", Enum.join(@analysis.allowed_codes, ", ")},
            {"Average per code", Float.round(@analysis.average_per_code, 1)},
            {"Imbalance threshold", "#{@analysis.threshold_pct}%"}
          ]} />

          <div style="margin-top:0.75rem">
            <.ag_grid
              id="reseg-distribution-grid"
              paginate={false}
              empty_message="No accounts in this scope."
              columns={[
                %{field: "code", header: "Cycle Code", width: 140},
                %{field: "accounts", header: "Accounts", type: "number", width: 140}
              ]}
              rows={Enum.map(Enum.sort_by(@analysis.distribution, fn {c, _} -> c end), fn {code, n} -> %{code: code, accounts: n} end)}
            />
          </div>

          <button :if={@can_edit} class="btn-sm btn-primary" style="margin-top:0.75rem"
                  phx-click="propose" phx-target={@myself}>
            Propose Rebalance
          </button>
        </.form_card>

        <.form_card :if={@proposal} title="Proposed Rebalance">
          <%= case @proposal.status do %>
            <% :no_accounts -> %>
              <p class="text-muted">No active accounts in this scope.</p>
            <% :balanced -> %>
              <.alert kind={:success} message="Distribution is within the configured threshold — no changes proposed." />
            <% :imbalanced -> %>
              <p><%= length(@proposal.moves) %> account(s) proposed to move:</p>
              <.ag_grid
                id="reseg-proposal-grid"
                paginate={false}
                empty_message="No moves proposed."
                columns={[
                  %{field: "account", header: "Account", type: "mono", width: 140},
                  %{field: "from", header: "From", width: 100},
                  %{field: "to", header: "To", width: 100}
                ]}
                rows={Enum.map(@proposal.moves, &proposal_move_row/1)}
              />
              <button :if={@can_edit and @proposal.moves != []} class="btn-sm btn-primary" style="margin-top:0.75rem"
                      phx-click="apply_proposal" phx-target={@myself}>
                Schedule These Moves
              </button>
          <% end %>
        </.form_card>

        <%!-- Left as plain HTML, not <.ag_grid> — the Cancel button here is
             driven directly by cms_resegmentation_component_test.exs via
             element("button[phx-value-id=...]") |> render_click(), which
             cannot see a client-rendered AG Grid actions cell. See
             docs/shared/Admin_Menu_Standard.md §5.1. --%>
        <.form_card title="Pending Changes">
          <.empty_state :if={@pending == []} icon="📭" title="No pending resegmentations" />

          <table :if={@pending != []} class="data-table">
            <thead><tr><th>Account</th><th>From</th><th>To</th><th>Effective</th><th>Proration</th><th></th></tr></thead>
            <tbody>
              <tr :for={a <- @pending}>
                <td><%= short_id(a.account_id) %></td>
                <td><%= a.cycle_code %></td>
                <td><%= a.pending_cycle_code %></td>
                <td><%= a.cycle_change_effective_date %></td>
                <td><%= a.cycle_change_proration_method %></td>
                <td>
                  <button :if={@can_edit} class="btn-sm btn-warning"
                          phx-click="cancel_pending" phx-value-id={a.account_id} phx-target={@myself}>
                    Cancel
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </.form_card>
      <% end %>
    </div>
    """
  end

  defp proposal_move_row(m) do
    %{
      account: short_id(m.account_id),
      from: m.from_cycle_code,
      to: m.to_cycle_code
    }
  end

  defp short_id(id), do: id |> to_string() |> String.slice(0, 8)
end
