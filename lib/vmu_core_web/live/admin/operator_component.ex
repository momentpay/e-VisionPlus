defmodule VmuCoreWeb.Live.Admin.OperatorComponent do
  @moduledoc """
  Operator administration (ASM-P2.5) — ADMIN-only module.

  List / create / unlock / disable / reset-password / change-role for
  back-office operators. Reachability is already gated twice (sidebar
  filtering + AdminLive's module guard, since no role rows grant
  `operators`), and every mutating event re-checks the ADMIN role
  server-side anyway — defense in depth.
  """

  use Phoenix.LiveComponent
  import Ecto.Query
  import VmuCoreWeb.AdminUI

  alias VmuCore.Repo
  alias VmuCore.ASM.{Auth, Operator, RoleTaxonomy}
  alias VmuCore.Shared.BankParameter

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       operators: [],
       show_create: false,
       notice: nil,
       notice_kind: :info,
       current_operator: nil,
       role_hint: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> load_operators()}
  end

  # ---------------------------------------------------------------------------
  # Events (each mutation re-checks ADMIN)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("toggle_create", _, socket) do
    {:noreply, assign(socket, show_create: !socket.assigns.show_create, notice: nil, role_hint: nil)}
  end

  def handle_event("create_form_change", %{"operator" => params}, socket) do
    {:noreply, assign(socket, role_hint: bank_scope_role_hint(params["bank_scope"]))}
  end

  def handle_event("create", %{"operator" => params}, socket) do
    with_admin(socket, fn ->
      case Auth.create_operator(%{
             username: params["username"] || "",
             display_name: params["display_name"] || "",
             password: params["password"] || "",
             role: params["role"] || "CS_AGENT",
             bank_scope: blank_to_nil(params["bank_scope"])
           }) do
        {:ok, op} ->
          socket
          |> put_notice("Operator '#{op.username}' created.", :success)
          |> assign(show_create: false)
          |> load_operators()

        {:error, :weak_password} ->
          put_notice(socket, "Password too weak — minimum 10 characters with a letter and a digit.", :error)

        {:error, %Ecto.Changeset{} = cs} ->
          put_notice(socket, "Create failed: #{inspect(cs.errors)}", :error)
      end
    end)
  end

  def handle_event("unlock", %{"id" => id}, socket) do
    with_admin(socket, fn ->
      op = Repo.get!(Operator, id)
      {:ok, _} = Auth.unlock(op)
      socket |> put_notice("Operator '#{op.username}' unlocked.", :success) |> load_operators()
    end)
  end

  def handle_event("disable", %{"id" => id}, socket) do
    with_admin(socket, fn ->
      op = Repo.get!(Operator, id)

      if op.operator_id == socket.assigns.current_operator.operator_id do
        put_notice(socket, "You cannot disable your own account.", :error)
      else
        {:ok, _} = Auth.disable(op)
        socket |> put_notice("Operator '#{op.username}' disabled.", :success) |> load_operators()
      end
    end)
  end

  def handle_event("reactivate", %{"id" => id}, socket) do
    with_admin(socket, fn ->
      op = Repo.get!(Operator, id)
      {:ok, _} = Auth.unlock(op)
      socket |> put_notice("Operator '#{op.username}' reactivated.", :success) |> load_operators()
    end)
  end

  def handle_event("reset_password", %{"id" => id, "password" => password}, socket) do
    with_admin(socket, fn ->
      op = Repo.get!(Operator, id)

      case Auth.reset_password(op, password) do
        {:ok, _} ->
          socket |> put_notice("Password reset for '#{op.username}'.", :success)

        {:error, :weak_password} ->
          put_notice(socket, "Password too weak — minimum 10 characters with a letter and a digit.", :error)

        {:error, reason} ->
          put_notice(socket, "Reset failed: #{inspect(reason)}", :error)
      end
    end)
  end

  def handle_event("change_role", %{"id" => id, "role" => role}, socket) do
    with_admin(socket, fn ->
      op = Repo.get!(Operator, id)

      if op.operator_id == socket.assigns.current_operator.operator_id do
        put_notice(socket, "You cannot change your own role.", :error)
      else
        case op |> Operator.changeset(%{role: role}) |> Repo.update() do
          {:ok, updated} ->
            socket
            |> put_notice("Role for '#{updated.username}' → #{updated.role}.", :success)
            |> load_operators()

          {:error, cs} ->
            put_notice(socket, "Role change failed: #{inspect(cs.errors)}", :error)
        end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="component-panel">
      <.page_header title="Operators" subtitle="Back-office identities, roles, and account state (ADMIN only)">
        <:actions>
          <button class="btn-primary" phx-click="toggle_create" phx-target={@myself}>
            <%= if @show_create, do: "Cancel", else: "+ New Operator" %>
          </button>
        </:actions>
      </.page_header>

      <%= if @notice do %>
        <.alert kind={@notice_kind} message={@notice} />
      <% end %>

      <%# Create form %>
      <%= if @show_create do %>
        <form phx-submit="create" phx-change="create_form_change" phx-target={@myself} class="search-form"
              style="margin-bottom:1.25rem; border:1px solid #ccd; border-radius:6px; padding:1rem">
          <div class="form-row">
            <div class="form-group">
              <label>Username</label>
              <input type="text" name="operator[username]" placeholder="jane.doe" required/>
            </div>
            <div class="form-group">
              <label>Display Name</label>
              <input type="text" name="operator[display_name]" placeholder="Jane Doe" required/>
            </div>
            <div class="form-group">
              <label>Role</label>
              <select name="operator[role]">
                <%= for r <- Operator.roles() do %>
                  <option value={r}><%= r %></option>
                <% end %>
              </select>
            </div>
          </div>
          <div class="form-row">
            <div class="form-group">
              <label>Initial Password</label>
              <input type="password" name="operator[password]" required
                     placeholder="min 10 chars, letter + digit"/>
            </div>
            <div class="form-group">
              <label>Bank Scope (optional)</label>
              <input type="text" name="operator[bank_scope]" maxlength="4"
                     placeholder="4-char bank_id, blank = all"/>
              <p :if={@role_hint} class="text-muted" style="font-size:0.8em;margin-top:2px;">
                <%= @role_hint %> (advisory — any role can still be selected above)
              </p>
            </div>
            <div class="form-group" style="align-self:flex-end">
              <button type="submit" class="btn-primary">Create Operator</button>
            </div>
          </div>
        </form>
      <% end %>

      <%# Operator table %>
      <div class="table-wrapper">
        <table class="data-table">
          <thead>
            <tr>
              <th>Username</th><th>Name</th><th>Role</th><th>Status</th>
              <th>Bank Scope</th><th>Last Login</th><th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for op <- @operators do %>
              <tr>
                <td><code><%= op.username %></code></td>
                <td><%= op.display_name %></td>
                <td>
                  <form phx-change="change_role" phx-target={@myself} style="display:inline">
                    <input type="hidden" name="id" value={op.operator_id}/>
                    <select name="role" disabled={op.operator_id == @current_operator.operator_id}>
                      <%= for r <- Operator.roles() do %>
                        <option value={r} selected={op.role == r}><%= r %></option>
                      <% end %>
                    </select>
                  </form>
                </td>
                <td><span class={"badge badge-#{status_class(op.status)}"}><%= op.status %></span></td>
                <td><%= op.bank_scope || "all" %></td>
                <td><%= (op.last_login_at && Calendar.strftime(op.last_login_at, "%Y-%m-%d %H:%M")) || "never" %></td>
                <td>
                  <%= if op.status == "LOCKED" do %>
                    <button class="btn-sm btn-success" phx-click="unlock"
                            phx-value-id={op.operator_id} phx-target={@myself}>Unlock</button>
                  <% end %>
                  <%= if op.status == "DISABLED" do %>
                    <button class="btn-sm btn-success" phx-click="reactivate"
                            phx-value-id={op.operator_id} phx-target={@myself}>Reactivate</button>
                  <% end %>
                  <%= if op.status == "ACTIVE" and op.operator_id != @current_operator.operator_id do %>
                    <button class="btn-sm btn-warning" phx-click="disable"
                            phx-value-id={op.operator_id} phx-target={@myself}
                            data-confirm="Disable this operator?">Disable</button>
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <p class="text-muted" style="margin-top:0.75rem; font-size:0.85em">
        Password resets: select an operator row action or use
        <code>ASM.Auth.reset_password/2</code> from the console — a dedicated
        reset dialog ships with the approval inbox (ASM-P3).
      </p>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_operators(socket) do
    assign(socket, operators:
      Repo.all(from o in Operator, order_by: [asc: o.username]))
  end

  defp with_admin(socket, fun) do
    if socket.assigns.current_operator.role == "ADMIN" do
      {:noreply, fun.()}
    else
      {:noreply, put_notice(socket, "ADMIN role required.", :error)}
    end
  end

  defp put_notice(socket, msg, kind), do: assign(socket, notice: msg, notice_kind: kind)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  # docs/asm/ASM_Role_Taxonomy.md — advisory recommended-roles hint, sourced from the
  # target bank's org_size. nil whenever bank_scope is blank or unresolvable.
  defp bank_scope_role_hint(nil), do: nil
  defp bank_scope_role_hint(""), do: nil

  defp bank_scope_role_hint(bank_scope) do
    case Repo.one(from b in BankParameter, where: b.bank_id == ^bank_scope, limit: 1) do
      %BankParameter{org_size: org_size} -> RoleTaxonomy.hint(org_size)
      nil -> nil
    end
  end

  defp status_class("ACTIVE"),   do: "success"
  defp status_class("LOCKED"),   do: "warning"
  defp status_class("DISABLED"), do: "error"
  defp status_class(_),          do: "info"
end
