defmodule VmuCoreWeb.Live.Admin.ServiceAccountsComponent do
  @moduledoc """
  Service-account (API credential) administration (KYC-P5, `docs/kyc/
  KYC_Implementation_Tracker.md` §7) — ADMIN-only module, same convention as
  `OperatorComponent`: reachability is already gated twice (sidebar
  filtering + AdminLive's module guard, since no role rows grant
  `service_accounts`), and every mutating event re-checks the ADMIN role
  server-side anyway — defense in depth.

  List / create / revoke bearer-token credentials for external API callers
  (`/api/v1/kyc/*`). The raw token is shown exactly once, right after
  creation — only its hash is ever persisted (`ASM.ServiceAccounts.
  create/1`) — with an explicit warning that it can't be retrieved again.
  """

  use Phoenix.LiveComponent
  import VmuCoreWeb.AdminUI
  import VmuCoreWeb.Components.AgGrid

  alias VmuCore.ASM.{ServiceAccount, ServiceAccounts}

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       accounts: [],
       show_create: false,
       just_created_token: nil,
       notice: nil,
       notice_kind: :info,
       current_operator: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> load_accounts()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.page_header title="Service Accounts" subtitle="API credentials for external callers (e.g. /api/v1/kyc/*)">
        <:actions>
          <button type="button" phx-click="toggle_create" phx-target={@myself} class="btn btn-primary">+ New</button>
        </:actions>
      </.page_header>

      <.alert :if={@notice} kind={@notice_kind} message={@notice} />

      <%= if @just_created_token do %>
        <div class="card" style="border:2px solid #d9822b; padding:12px; margin-bottom:16px;">
          <strong>⚠ Copy this token now — it will never be shown again.</strong>
          <pre style="user-select:all; background:#f5f5f5; padding:8px; margin-top:8px;"><%= @just_created_token %></pre>
          <button type="button" phx-click="dismiss_token" phx-target={@myself} class="btn btn-sm">I've copied it</button>
        </div>
      <% end %>

      <%= if @show_create do %>
        <.form_card title="New Service Account">
          <form phx-submit="create" phx-target={@myself}>
            <.field label="Name">
              <input type="text" name="name" required placeholder="e.g. wallet-app-prod" />
            </.field>
            <.field label="Scopes">
              <label :for={s <- ServiceAccount.scopes()} style="display:block;">
                <input type="checkbox" name="scopes[]" value={s} /> <%= s %>
              </label>
            </.field>
            <button type="submit" class="btn btn-primary">Create</button>
            <button type="button" phx-click="toggle_create" phx-target={@myself} class="btn">Cancel</button>
          </form>
        </.form_card>
      <% end %>

      <%= if @accounts == [] do %>
        <.empty_state icon="🔑" title="No service accounts yet" />
      <% else %>
        <.ag_grid
          id="service-accounts-grid"
          columns={[
            %{field: "name", header: "Name", flex: 2},
            %{field: "scopes", header: "Scopes", flex: 2},
            %{field: "status", header: "Status", type: "badge", width: 130},
            %{field: "last_used_at", header: "Last used", width: 180},
            %{field: "service_account_id", header: "", type: "actions", width: 120,
              actions: [
                %{label: "Revoke", event: "revoke", param: "service_account_id",
                  whenField: "status", whenValue: "ACTIVE", danger: true}
              ]}
          ]}
          rows={Enum.map(@accounts, &service_account_row/1)}
        />
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Events (each mutation re-checks ADMIN)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("toggle_create", _params, socket) do
    {:noreply, assign(socket, show_create: !socket.assigns.show_create, notice: nil)}
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, just_created_token: nil)}
  end

  def handle_event("create", %{"name" => name} = params, socket) do
    if admin?(socket) do
      scopes = params["scopes"] || []

      case ServiceAccounts.create(%{"name" => name, "scopes" => scopes, "created_by" => operator_username(socket)}) do
        {:ok, _account, raw_token} ->
          {:noreply,
           socket
           |> assign(show_create: false, just_created_token: raw_token, notice: "Service account created", notice_kind: :success)
           |> load_accounts()}

        {:error, changeset} ->
          {:noreply, assign(socket, notice: cs_error_msg(changeset), notice_kind: :error)}
      end
    else
      {:noreply, assign(socket, notice: "Only ADMIN can manage service accounts", notice_kind: :error)}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    if admin?(socket) do
      case ServiceAccounts.get(id) do
        nil ->
          {:noreply, socket}

        account ->
          {:ok, _} = ServiceAccounts.revoke(account)
          {:noreply, socket |> assign(notice: "Service account revoked", notice_kind: :success) |> load_accounts()}
      end
    else
      {:noreply, assign(socket, notice: "Only ADMIN can manage service accounts", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_accounts(socket), do: assign(socket, accounts: ServiceAccounts.list())

  defp service_account_row(a) do
    %{
      name: a.name,
      scopes: Enum.join(a.scopes, ", "),
      status: a.status,
      last_used_at: if(a.last_used_at, do: to_string(a.last_used_at), else: "—"),
      service_account_id: a.service_account_id
    }
  end

  defp admin?(socket), do: socket.assigns.current_operator && socket.assigns.current_operator.role == "ADMIN"

  defp operator_username(socket) do
    case socket.assigns.current_operator do
      %{username: username} -> username
      _ -> nil
    end
  end

  defp cs_error_msg(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end
end
