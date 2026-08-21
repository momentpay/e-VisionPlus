defmodule VmuCoreWeb.Live.Admin.KycMethodsComponent do
  @moduledoc """
  Admin LiveComponent: KYC method template builder (KYC-P1/P3.5,
  `docs/kyc/KYC_Implementation_Tracker.md`).

  Split out from the combined `KycComponent` (KYC-P3.5, confirmed with the
  user 2026-07-29): method-template design and request review are different
  roles ("KYC Method created can be admin role whereas KYC request
  management is another user role") and now live on separate screens with
  separate `kyc_methods`/`kyc_requests` permissions, not one shared `kyc`
  module gating both.

  List every `KycMethod` (filterable by product + status), and a tabbed
  builder to create/edit one — Form Fields (add/remove/reorder, pick a type
  from the fixed `VmuCore.Kyc.FieldTypes` catalog, set label/required/
  options) and Conditional Logic (`VmuCore.Kyc.ConditionalLogic`, "show
  field X when field Y <op> value"). Deliberately no Third-Party-Validation
  or OCR-Configuration tabs the way the MMS reference has — this build's
  OCR (`Kyc.Adapters.OcrHttpAdapter`) runs automatically on every file
  upload with no per-field toggle needed, and third-party identity
  validation stays an unimplemented `ProviderAdapter` callback (KYC-P3) —
  nothing to configure per-field yet.

  `step`/`required` (KYC-P3.5) turn a product's methods into an ordered,
  sequentially-gated journey (`VmuCore.Kyc.Journey`) — several methods can
  share one `product_type` at different steps. "Clone to product" copies an
  existing method's field set into a new product scope as an independent,
  inactive starting point — never a live shared reference between products.

  Visibility requires `kyc_methods:view`; create/edit/clone actions require
  `kyc_methods:edit`.
  """

  use Phoenix.LiveComponent
  import VmuCoreWeb.AdminUI

  alias VmuCore.Kyc.{Method, Methods, FieldTypes, ConditionalLogic}
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
       editor_tab: :fields,
       form_data: %{},
       fields: [],
       conditional_rules: [],
       clone_target: nil,
       cloning_method: nil
     )
     |> load_methods()}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    operator = socket.assigns[:current_operator]
    {:ok, assign(socket, can_edit: operator && Authz.can?(operator, "kyc_methods", "edit"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.page_header title="KYC Methods" subtitle="Per-product KYC form templates and step sequencing">
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
      <%!-- Plain HTML, deliberately — edit_method and clone_open are both
          exercised directly by kyc_methods_component_test.exs via
          `element(...) |> render_click()`, which AG Grid's client-rendered
          actions cells cannot satisfy. See
          docs/shared/Admin_Menu_Standard.md §5. --%>
      <table class="admin-table">
        <thead>
          <tr>
            <th>Product</th>
            <th>Step</th>
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
            <td><%= m.step %><%= if !m.required, do: " (optional)" %></td>
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
        <div style="display:grid; grid-template-columns:280px 1fr; gap:28px; align-items:start;">
          <div style="border-right:1px solid #eee; padding-right:20px;">
            <.form_section title="Method" />
            <.field label="Internal name">
              <input type="text" name="method[name]" value={@form_data["name"]} required style="width:100%;" />
            </.field>
            <.field label="Title (shown to whoever fills the form)">
              <input type="text" name="method[title]" value={@form_data["title"]} required style="width:100%;" />
            </.field>
            <.field label="Product">
              <select name="method[product_type]" required style="width:100%;">
                <option value="">Select product...</option>
                <option :for={pt <- Arrangement.product_types()} value={pt} selected={@form_data["product_type"] == pt}><%= pt %></option>
              </select>
            </.field>
            <.field label="Status">
              <select name="method[status]" style="width:100%;">
                <option :for={s <- Method.statuses()} value={s} selected={@form_data["status"] == s}><%= s %></option>
              </select>
            </.field>
            <.field label="Step" hint="Order within this product's KYC journey. Methods sharing a step unlock together.">
              <input type="number" min="1" name="method[step]" value={@form_data["step"] || 1} required style="width:100%;" />
            </.field>
            <.field label="Required to advance">
              <select name="method[required]" style="width:100%;">
                <option value="true" selected={to_string(@form_data["required"]) != "false"}>Yes — later steps wait for this one</option>
                <option value="false" selected={to_string(@form_data["required"]) == "false"}>No — optional, doesn't block later steps</option>
              </select>
            </.field>
          </div>

          <div>
            <div style="margin-bottom:16px; border-bottom:1px solid #ddd;">
              <button type="button" phx-click="editor_tab" phx-value-t="fields" phx-target={@myself} class={"btn btn-sm #{if @editor_tab == :fields, do: "btn-primary"}"}>Form Fields</button>
              <button type="button" phx-click="editor_tab" phx-value-t="logic" phx-target={@myself} class={"btn btn-sm #{if @editor_tab == :logic, do: "btn-primary"}"}>Conditional Logic</button>
            </div>

            <%= if @editor_tab == :fields do %>
              <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:10px;">
                <strong>Document Fields</strong>
                <button type="button" phx-click="add_field" phx-target={@myself} class="btn btn-sm btn-primary">+ Add Field</button>
              </div>

              <.empty_state :if={@fields == []} icon="📝" title="No fields yet" message="Add the first field for this method." />

              <div :for={{f, idx} <- Enum.with_index(@fields)} style="border:1px solid #ddd; border-radius:8px; padding:14px; margin-bottom:12px;">
                <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:10px;">
                  <strong>Field #<%= idx + 1 %></strong>
                  <button type="button" phx-click="remove_field" phx-value-idx={idx} phx-target={@myself} class="btn btn-sm btn-danger">Remove</button>
                </div>

                <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px;">
                  <.field label="Field Label">
                    <input type="text" name={"field_label_#{idx}"} value={f["label"]} phx-blur="field_prop" phx-value-idx={idx} phx-value-prop="label" phx-target={@myself} style="width:100%;" />
                  </.field>
                  <.field label="Field Key" hint="Used in form processing. Keep consistent once set.">
                    <input type="text" value={f["key"]} readonly style="width:100%; background:#f5f5f5;" />
                  </.field>
                </div>

                <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:8px;">
                  <.field label="Field Type">
                    <select name={"field_type_#{idx}"} phx-change="field_prop" phx-value-idx={idx} phx-value-prop="type" phx-target={@myself} style="width:100%;">
                      <option :for={t <- FieldTypes.types()} value={t} selected={f["type"] == t}><%= FieldTypes.label(t) %></option>
                    </select>
                  </.field>
                  <.field label="Required">
                    <label style="font-weight:normal;">
                      <input type="checkbox" name={"field_required_#{idx}"} checked={f["required"]} phx-click="field_prop" phx-value-idx={idx} phx-value-prop="required" phx-target={@myself} />
                      Required to submit
                    </label>
                  </.field>
                </div>

                <.field :if={FieldTypes.has_options?(f["type"])} label="Options (comma-separated)">
                  <input type="text" name={"field_options_#{idx}"} value={Enum.join(f["options"] || [], ", ")} phx-blur="field_prop" phx-value-idx={idx} phx-value-prop="options" phx-target={@myself} style="width:100%;" />
                </.field>

                <p :if={FieldTypes.file_type?(f["type"])} style="font-size:12px; color:#888; margin-top:8px;">
                  📄 OCR runs automatically against the real OCR service when a document is uploaded for this field — no extra configuration needed.
                </p>

                <div style="margin-top:10px;">
                  <button type="button" phx-click="move_field" phx-value-idx={idx} phx-value-dir="up" phx-target={@myself} class="btn btn-sm">&uarr; Move up</button>
                  <button type="button" phx-click="move_field" phx-value-idx={idx} phx-value-dir="down" phx-target={@myself} class="btn btn-sm">&darr; Move down</button>
                </div>
              </div>
            <% end %>

            <%= if @editor_tab == :logic do %>
              <p style="color:#666; font-size:13px;">Show a field only when another field's value satisfies a condition. A field with no rule is always shown.</p>
              <table :if={@conditional_rules != []} class="admin-table" style="margin-bottom:8px;">
                <thead>
                  <tr>
                    <th>Show field</th>
                    <th>When field</th>
                    <th>Operator</th>
                    <th>Value</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={{r, idx} <- Enum.with_index(@conditional_rules)}>
                    <td>
                      <select phx-change="rule_prop" phx-value-idx={idx} phx-value-prop="target_field" phx-target={@myself}>
                        <option :for={f <- @fields} value={f["key"]} selected={r["target_field"] == f["key"]}><%= f["label"] %></option>
                      </select>
                    </td>
                    <td>
                      <select phx-change="rule_prop" phx-value-idx={idx} phx-value-prop="field" phx-target={@myself}>
                        <option :for={f <- @fields} value={f["key"]} selected={get_in(r, ["condition", "field"]) == f["key"]}><%= f["label"] %></option>
                      </select>
                    </td>
                    <td>
                      <select phx-change="rule_prop" phx-value-idx={idx} phx-value-prop="operator" phx-target={@myself}>
                        <option :for={op <- ConditionalLogic.operators()} value={op} selected={get_in(r, ["condition", "operator"]) == op}><%= op %></option>
                      </select>
                    </td>
                    <td>
                      <input type="text" value={get_in(r, ["condition", "value"])} phx-blur="rule_prop" phx-value-idx={idx} phx-value-prop="value" phx-target={@myself} />
                    </td>
                    <td><button type="button" phx-click="remove_rule" phx-value-idx={idx} phx-target={@myself} class="btn btn-sm btn-danger">Remove</button></td>
                  </tr>
                </tbody>
              </table>
              <button type="button" phx-click="add_rule" phx-target={@myself} class="btn btn-sm" disabled={@fields == []}>+ Add Rule</button>
            <% end %>
          </div>
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
       editor_tab: :fields,
       form_data: %{"name" => "", "title" => "", "product_type" => "", "status" => "active", "step" => 1, "required" => "true"},
       fields: [],
       conditional_rules: []
     )}
  end

  def handle_event("edit_method", %{"id" => id}, socket) do
    method = Methods.get!(id)

    {:noreply,
     assign(socket,
       mode: :edit,
       editing: method,
       editor_tab: :fields,
       form_data: %{
         "name" => method.name,
         "title" => method.title,
         "product_type" => method.product_type,
         "status" => method.status,
         "step" => method.step,
         "required" => to_string(method.required)
       },
       fields: method.fields,
       conditional_rules: method.conditional_rules || []
     )}
  end

  def handle_event("back_to_list", _params, socket) do
    {:noreply, socket |> assign(mode: :list) |> load_methods()}
  end

  def handle_event("editor_tab", %{"t" => t}, socket) do
    {:noreply, assign(socket, editor_tab: String.to_existing_atom(t))}
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

  def handle_event("add_rule", _params, socket) do
    default_key =
      case List.first(socket.assigns.fields) do
        nil -> nil
        f -> f["key"]
      end

    new_rule = %{"target_field" => default_key, "condition" => %{"field" => default_key, "operator" => "equals", "value" => ""}}
    {:noreply, update(socket, :conditional_rules, &(&1 ++ [new_rule]))}
  end

  def handle_event("remove_rule", %{"idx" => idx}, socket) do
    idx = String.to_integer(idx)
    {:noreply, update(socket, :conditional_rules, &List.delete_at(&1, idx))}
  end

  def handle_event("rule_prop", %{"idx" => idx} = params, socket) do
    idx = String.to_integer(idx)
    prop = params["prop"]
    value = params["value"] || ""

    rules =
      List.update_at(socket.assigns.conditional_rules, idx, fn rule ->
        case prop do
          "target_field" -> Map.put(rule, "target_field", value)
          _ -> Map.update!(rule, "condition", &Map.put(&1, prop, value))
        end
      end)

    {:noreply, assign(socket, conditional_rules: rules)}
  end

  def handle_event("save_method", %{"method" => attrs}, socket) do
    attrs =
      attrs
      |> Map.put("fields", socket.assigns.fields)
      |> Map.put("conditional_rules", socket.assigns.conditional_rules)

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
