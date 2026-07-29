defmodule VmuCoreWeb.Live.Admin.KycComponent do
  @moduledoc """
  Admin LiveComponent: KYC method builder (KYC-P1,
  `docs/kyc/KYC_Implementation_Tracker.md`).

  List every `KycMethod` (filterable by product + status), and a dynamic
  field builder to create/edit one: add/remove/reorder fields, pick a type
  from the fixed `VmuCore.Kyc.FieldTypes` catalog, set label/required/
  options. "Clone to product" copies an existing method's field set into a
  new product scope as an independent, inactive starting point — never a
  live shared reference between products (`docs/kyc/
  KYC_Implementation_Tracker.md` §2).

  Submissions/requests (KYC-P2) are not part of this phase — this screen
  only manages templates.

  Visibility requires `kyc:view`; create/edit/clone actions require `kyc:edit`.
  """

  use Phoenix.LiveComponent
  import VmuCoreWeb.AdminUI

  alias VmuCore.Kyc.{Method, Methods, FieldTypes}
  alias VmuCore.CMS.Arrangement
  alias VmuCore.ASM.Authz

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       mode: :list,
       methods: [],
       filter_product: "",
       filter_status: "",
       notice: nil,
       notice_kind: :info,
       can_edit: false,
       editing: nil,
       form_data: %{},
       fields: [],
       clone_target: nil,
       cloning_method: nil
     )
     |> load_methods()}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    operator = socket.assigns[:current_operator]
    {:ok, assign(socket, can_edit: operator && Authz.can?(operator, "kyc", "edit"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_header title="KYC Methods" subtitle="Per-product KYC form templates">
        <:actions>
          <button :if={@can_edit} type="button" phx-click="new_method" phx-target={@myself} class="btn btn-primary">
            + New Method
          </button>
        </:actions>
      </.page_header>

      <.alert :if={@notice} kind={@notice_kind} message={@notice} />

      <%= if @mode == :list do %>
        <%= render_list(assigns) %>
      <% else %>
        <%= render_editor(assigns) %>
      <% end %>

      <%= if @clone_target do %>
        <%= render_clone_modal(assigns) %>
      <% end %>
    </div>
    """
  end

  defp render_list(assigns) do
    ~H"""
    <form phx-change="filter" phx-target={@myself} style="margin-bottom:12px; display:flex; gap:12px;">
      <select name="product_type">
        <option value="">All products</option>
        <option :for={pt <- Arrangement.product_types()} value={pt} selected={@filter_product == pt}><%= pt %></option>
      </select>
      <select name="status">
        <option value="">All statuses</option>
        <option :for={s <- Method.statuses()} value={s} selected={@filter_status == s}><%= s %></option>
      </select>
    </form>

    <%= if @methods == [] do %>
      <.empty_state icon="🪪" title="No KYC methods yet" message="Create the first method for a product." />
    <% else %>
      <table class="admin-table">
        <thead>
          <tr>
            <th>Product</th>
            <th>Name</th>
            <th>Title</th>
            <th>Fields</th>
            <th>Version</th>
            <th>Status</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={m <- @methods}>
            <td><%= m.product_type %></td>
            <td><%= m.name %></td>
            <td><%= m.title %></td>
            <td><%= length(m.fields) %></td>
            <td>v<%= m.version %></td>
            <td><.status_badge status={m.status} /></td>
            <td>
              <button type="button" phx-click="edit_method" phx-value-id={m.method_id} phx-target={@myself} class="btn btn-sm">Edit</button>
              <button :if={@can_edit} type="button" phx-click="clone_open" phx-value-id={m.method_id} phx-target={@myself} class="btn btn-sm">Clone to product</button>
            </td>
          </tr>
        </tbody>
      </table>
    <% end %>
    """
  end

  defp render_editor(assigns) do
    ~H"""
    <.form_card title={if @editing, do: "Edit Method", else: "New Method"}>
      <:header_actions>
        <button type="button" phx-click="back_to_list" phx-target={@myself} class="btn btn-sm">&larr; Back to list</button>
      </:header_actions>

      <form phx-submit="save_method" phx-change="form_change" phx-target={@myself}>
        <.form_section title="Method" />
        <.field label="Internal name">
          <input type="text" name="method[name]" value={@form_data["name"]} required />
        </.field>
        <.field label="Title (shown to whoever fills the form)">
          <input type="text" name="method[title]" value={@form_data["title"]} required />
        </.field>
        <.field label="Product">
          <select name="method[product_type]" required>
            <option value="">Select product...</option>
            <option :for={pt <- Arrangement.product_types()} value={pt} selected={@form_data["product_type"] == pt}><%= pt %></option>
          </select>
        </.field>
        <.field label="Status">
          <select name="method[status]">
            <option :for={s <- Method.statuses()} value={s} selected={@form_data["status"] == s}><%= s %></option>
          </select>
        </.field>

        <.form_section title="Fields" />
        <div>
          <table class="admin-table" style="margin-bottom:8px;">
            <thead>
              <tr>
                <th>#</th>
                <th>Label</th>
                <th>Key</th>
                <th>Type</th>
                <th>Required</th>
                <th>Options (comma-separated)</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{f, idx} <- Enum.with_index(@fields)}>
                <td><%= idx + 1 %></td>
                <td><input type="text" name={"field_label_#{idx}"} value={f["label"]} phx-blur="field_prop" phx-value-idx={idx} phx-value-prop="label" phx-target={@myself} /></td>
                <td><code><%= f["key"] %></code></td>
                <td>
                  <select name={"field_type_#{idx}"} phx-change="field_prop" phx-value-idx={idx} phx-value-prop="type" phx-target={@myself}>
                    <option :for={t <- FieldTypes.types()} value={t} selected={f["type"] == t}><%= FieldTypes.label(t) %></option>
                  </select>
                </td>
                <td>
                  <input type="checkbox" name={"field_required_#{idx}"} checked={f["required"]} phx-click="field_prop" phx-value-idx={idx} phx-value-prop="required" phx-target={@myself} />
                </td>
                <td>
                  <input :if={FieldTypes.has_options?(f["type"])} type="text" name={"field_options_#{idx}"} value={Enum.join(f["options"] || [], ", ")} phx-blur="field_prop" phx-value-idx={idx} phx-value-prop="options" phx-target={@myself} />
                </td>
                <td>
                  <button type="button" phx-click="move_field" phx-value-idx={idx} phx-value-dir="up" phx-target={@myself} class="btn btn-sm">&uarr;</button>
                  <button type="button" phx-click="move_field" phx-value-idx={idx} phx-value-dir="down" phx-target={@myself} class="btn btn-sm">&darr;</button>
                  <button type="button" phx-click="remove_field" phx-value-idx={idx} phx-target={@myself} class="btn btn-sm btn-danger">Remove</button>
                </td>
              </tr>
            </tbody>
          </table>
          <button type="button" phx-click="add_field" phx-target={@myself} class="btn btn-sm">+ Add Field</button>
        </div>

        <button type="submit" class="btn btn-primary" style="margin-top:16px;">Save Method</button>
      </form>
    </.form_card>
    """
  end

  defp render_clone_modal(assigns) do
    ~H"""
    <div class="modal-backdrop">
      <div class="modal">
        <h3>Clone "<%= @cloning_method.name %>" to a new product</h3>
        <p>Copies this method's fields into a new, independent, inactive method — the source method is unchanged and the two stay separate from here on.</p>
        <form phx-submit="clone_save" phx-target={@myself}>
          <select name="target_product_type" required>
            <option value="">Select product...</option>
            <option :for={pt <- Arrangement.product_types()} value={pt}><%= pt %></option>
          </select>
          <button type="submit" class="btn btn-primary">Clone</button>
          <button type="button" phx-click="clone_cancel" phx-target={@myself} class="btn">Cancel</button>
        </form>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("filter", params, socket) do
    socket =
      socket
      |> assign(filter_product: params["product_type"] || "", filter_status: params["status"] || "")
      |> load_methods()

    {:noreply, socket}
  end

  def handle_event("new_method", _params, socket) do
    {:noreply,
     assign(socket,
       mode: :edit,
       editing: nil,
       form_data: %{"name" => "", "title" => "", "product_type" => "", "status" => "active"},
       fields: []
     )}
  end

  def handle_event("edit_method", %{"id" => id}, socket) do
    method = Methods.get!(id)

    {:noreply,
     assign(socket,
       mode: :edit,
       editing: method,
       form_data: %{
         "name" => method.name,
         "title" => method.title,
         "product_type" => method.product_type,
         "status" => method.status
       },
       fields: method.fields
     )}
  end

  def handle_event("back_to_list", _params, socket) do
    {:noreply, socket |> assign(mode: :list) |> load_methods()}
  end

  def handle_event("form_change", %{"method" => attrs}, socket) do
    {:noreply, update(socket, :form_data, &Map.merge(&1, attrs))}
  end

  def handle_event("add_field", _params, socket) do
    new_field = %{"key" => nil, "label" => "", "type" => "text", "required" => false, "options" => []}
    {:noreply, update(socket, :fields, &(&1 ++ [new_field]))}
  end

  def handle_event("remove_field", %{"idx" => idx}, socket) do
    idx = String.to_integer(idx)
    {:noreply, update(socket, :fields, &List.delete_at(&1, idx))}
  end

  def handle_event("move_field", %{"idx" => idx, "dir" => dir}, socket) do
    idx = String.to_integer(idx)
    target = if dir == "up", do: idx - 1, else: idx + 1
    fields = socket.assigns.fields

    fields =
      if target >= 0 and target < length(fields) do
        swap(fields, idx, target)
      else
        fields
      end

    {:noreply, assign(socket, fields: fields)}
  end

  def handle_event("field_prop", %{"idx" => idx} = params, socket) do
    idx = String.to_integer(idx)
    prop = params["prop"]
    value = field_prop_value(prop, params, idx)

    fields =
      List.update_at(socket.assigns.fields, idx, fn f ->
        f = Map.put(f, prop, value)
        if prop == "label", do: Map.put(f, "key", f["key"] || derive_key(value)), else: f
      end)

    {:noreply, assign(socket, fields: fields)}
  end

  def handle_event("save_method", %{"method" => attrs}, socket) do
    attrs = Map.put(attrs, "fields", socket.assigns.fields)

    result =
      case socket.assigns.editing do
        nil -> Methods.create(attrs)
        method -> Methods.update(method, attrs)
      end

    case result do
      {:ok, _method} ->
        {:noreply,
         socket
         |> assign(mode: :list, notice: "Method saved successfully", notice_kind: :success)
         |> load_methods()}

      {:error, changeset} ->
        {:noreply, assign(socket, notice: cs_error_msg(changeset), notice_kind: :error)}
    end
  end

  def handle_event("clone_open", %{"id" => id}, socket) do
    {:noreply, assign(socket, clone_target: id, cloning_method: Methods.get!(id))}
  end

  def handle_event("clone_cancel", _params, socket) do
    {:noreply, assign(socket, clone_target: nil, cloning_method: nil)}
  end

  def handle_event("clone_save", %{"target_product_type" => target}, socket) do
    case Methods.clone(socket.assigns.cloning_method, target) do
      {:ok, _method} ->
        {:noreply,
         socket
         |> assign(clone_target: nil, cloning_method: nil, notice: "Method cloned to #{target}", notice_kind: :success)
         |> load_methods()}

      {:error, changeset} ->
        {:noreply, assign(socket, notice: cs_error_msg(changeset), notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_methods(socket) do
    filters = %{"product_type" => socket.assigns.filter_product, "status" => socket.assigns.filter_status}
    assign(socket, methods: Methods.list(filters))
  end

  defp swap(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)
    list |> List.replace_at(i, b) |> List.replace_at(j, a)
  end

  defp field_prop_value("required", params, idx), do: Map.has_key?(params, "field_required_#{idx}")
  defp field_prop_value("options", params, _idx), do: (params["value"] || "") |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  defp field_prop_value(_prop, params, _idx), do: params["value"] || ""

  defp derive_key(label) do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.replace(~r/\s+/, "_")
    |> String.trim("_")
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
