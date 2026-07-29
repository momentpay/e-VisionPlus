defmodule VmuCoreWeb.Live.Admin.KycComponent do
  @moduledoc """
  Admin LiveComponent: KYC methods + requests (KYC-P1/P2,
  `docs/kyc/KYC_Implementation_Tracker.md`).

  Two tabs:
  - **Methods** — list every `KycMethod` (filterable by product + status),
    and a dynamic field builder to create/edit one: add/remove/reorder
    fields, pick a type from the fixed `VmuCore.Kyc.FieldTypes` catalog, set
    label/required/options. "Clone to product" copies an existing method's
    field set into a new product scope as an independent, inactive starting
    point — never a live shared reference between products (§2).
  - **Requests** — admin-initiated submission (search/select customer, pick
    an active method for a product, fill in the form), a queue filterable by
    product/status, and detail/Approve/Reject. Approve/Reject fire
    `Kyc.StatusSync` — the real integration point that keeps the five
    pre-existing per-product `kyc_status` flags (Customer/Debit/Prepaid/
    Wallet/HCS.Company) accurate (§5). File-type fields accept a text
    reference for now — real upload/preview is KYC-P3 scope, not built here.

  Visibility requires `kyc:view`; create/edit/clone/submit/approve/reject
  actions require `kyc:edit`.
  """

  use Phoenix.LiveComponent
  import Ecto.Query, except: [update: 2, update: 3]
  import VmuCoreWeb.AdminUI

  alias VmuCore.Repo
  alias VmuCore.Kyc.{Method, Methods, FieldTypes, Request, Requests}
  alias VmuCore.CMS.Arrangement
  alias VmuCore.Shared.Customer
  alias VmuCore.ASM.Authz

  @default_operator_id "00000000-0000-0000-0000-000000000001"

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       section: :methods,
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
       cloning_method: nil,

       req_mode: :list,
       requests: [],
       filter_req_product: "",
       filter_req_status: "",
       req_step: 1,
       req_customer_search: "",
       req_customer_results: [],
       req_customer: nil,
       req_product_type: "",
       req_available_methods: [],
       req_method: nil,
       req_data: %{},
       req_detail: nil,
       req_detail_method: nil
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
      <.page_header title="KYC" subtitle="Per-product KYC methods and requests">
        <:actions>
          <button :if={@section == :methods && @can_edit} type="button" phx-click="new_method" phx-target={@myself} class="btn btn-primary">
            + New Method
          </button>
          <button :if={@section == :requests && @can_edit} type="button" phx-click="req_new" phx-target={@myself} class="btn btn-primary">
            + New Request
          </button>
        </:actions>
      </.page_header>

      <div style="margin-bottom:12px;">
        <button type="button" phx-click="section" phx-value-s="methods" phx-target={@myself} class={"btn btn-sm #{if @section == :methods, do: "btn-primary"}"}>Methods</button>
        <button type="button" phx-click="section" phx-value-s="requests" phx-target={@myself} class={"btn btn-sm #{if @section == :requests, do: "btn-primary"}"}>Requests</button>
      </div>

      <.alert :if={@notice} kind={@notice_kind} message={@notice} />

      <%= if @section == :methods do %>
        <%= if @mode == :list do %>
          <%= render_list(assigns) %>
        <% else %>
          <%= render_editor(assigns) %>
        <% end %>
      <% else %>
        <%= case @req_mode do %>
          <% :list -> %><%= render_requests_list(assigns) %>
          <% :new -> %><%= render_requests_new(assigns) %>
          <% :detail -> %><%= render_requests_detail(assigns) %>
        <% end %>
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

  defp render_requests_list(assigns) do
    ~H"""
    <form phx-change="req_filter" phx-target={@myself} style="margin-bottom:12px; display:flex; gap:12px;">
      <select name="product_type">
        <option value="">All products</option>
        <option :for={pt <- Arrangement.product_types()} value={pt} selected={@filter_req_product == pt}><%= pt %></option>
      </select>
      <select name="status">
        <option value="">All statuses</option>
        <option :for={s <- Request.statuses()} value={s} selected={@filter_req_status == s}><%= s %></option>
      </select>
    </form>

    <%= if @requests == [] do %>
      <.empty_state icon="📋" title="No KYC requests yet" message="Start one from the Requests tab." />
    <% else %>
      <table class="admin-table">
        <thead>
          <tr>
            <th>Application #</th>
            <th>Customer</th>
            <th>Product</th>
            <th>Status</th>
            <th>Submitted</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={r <- @requests}>
            <td><%= r.application_number %></td>
            <td><%= customer_name(r.customer_id) %></td>
            <td><%= r.product_type %></td>
            <td><.status_badge status={r.status} /></td>
            <td><%= r.submitted_at %></td>
            <td><button type="button" phx-click="req_view" phx-value-id={r.request_id} phx-target={@myself} class="btn btn-sm">View</button></td>
          </tr>
        </tbody>
      </table>
    <% end %>
    """
  end

  defp render_requests_new(assigns) do
    ~H"""
    <.form_card title="New KYC Request">
      <:header_actions>
        <button type="button" phx-click="req_back_to_list" phx-target={@myself} class="btn btn-sm">&larr; Back to list</button>
      </:header_actions>

      <%= if @req_step == 1 do %>
        <.field label="Search customer">
          <input type="text" value={@req_customer_search} phx-keyup="req_cust_search" phx-debounce="300" phx-target={@myself} placeholder="Name, email, or mobile…" />
        </.field>
        <table :if={@req_customer_results != []} class="admin-table">
          <thead><tr><th>Name</th><th>Email</th><th>Bank</th><th></th></tr></thead>
          <tbody>
            <tr :for={c <- @req_customer_results}>
              <td><%= c.first_name %> <%= c.last_name %></td>
              <td><%= c.email %></td>
              <td><%= c.bank_id %></td>
              <td><button type="button" phx-click="req_select_customer" phx-value-id={c.customer_id} phx-target={@myself} class="btn btn-sm">Select</button></td>
            </tr>
          </tbody>
        </table>
      <% end %>

      <%= if @req_step == 2 do %>
        <p>Customer: <strong><%= @req_customer.first_name %> <%= @req_customer.last_name %></strong></p>
        <.field label="Product">
          <select phx-change="req_select_product" phx-target={@myself}>
            <option value="">Select product...</option>
            <option :for={pt <- Arrangement.product_types()} value={pt} selected={@req_product_type == pt}><%= pt %></option>
          </select>
        </.field>
        <.field :if={@req_product_type != ""} label="Method">
          <select phx-change="req_select_method" phx-target={@myself}>
            <option value="">Select method...</option>
            <option :for={m <- @req_available_methods} value={m.method_id} selected={@req_method && @req_method.method_id == m.method_id}><%= m.name %> (v<%= m.version %>)</option>
          </select>
        </.field>
        <.empty_state :if={@req_product_type != "" && @req_available_methods == []} icon="🪪" title="No active method for this product yet" message="Create one on the Methods tab first." />
      <% end %>

      <%= if @req_step == 3 do %>
        <p>Customer: <strong><%= @req_customer.first_name %> <%= @req_customer.last_name %></strong> — Product: <strong><%= @req_product_type %></strong> — Method: <strong><%= @req_method.name %></strong></p>
        <form phx-submit="req_submit" phx-change="req_field_change" phx-target={@myself}>
          <.field :for={f <- @req_method.fields} label={f["label"] <> if(f["required"], do: " *", else: "")}>
            <%= render_field_input(f, @req_data[f["key"]]) %>
          </.field>
          <button type="submit" class="btn btn-primary" style="margin-top:16px;">Submit Request</button>
        </form>
      <% end %>
    </.form_card>
    """
  end

  defp render_requests_detail(assigns) do
    ~H"""
    <.form_card title={"Request #{@req_detail.application_number}"}>
      <:header_actions>
        <button type="button" phx-click="req_back_to_list" phx-target={@myself} class="btn btn-sm">&larr; Back to list</button>
      </:header_actions>

      <.kv_detail rows={[
        {"Customer", customer_name(@req_detail.customer_id)},
        {"Product", @req_detail.product_type},
        {"Method", @req_detail_method && @req_detail_method.name},
        {"Status", @req_detail.status},
        {"Submitted", to_string(@req_detail.submitted_at)},
        {"Reviewer", @req_detail.reviewer_id},
        {"Decision reason", @req_detail.decision_reason}
      ]} />

      <.form_section title="Submitted Data" />
      <table class="admin-table">
        <tbody>
          <tr :for={f <- @req_detail.fields_snapshot}>
            <td><%= f["label"] %></td>
            <td><%= @req_detail.data[f["key"]] %></td>
          </tr>
        </tbody>
      </table>

      <%= if @can_edit && @req_detail.status in ["submitted", "under_review"] do %>
        <.form_section title="Decision" />
        <form phx-submit="req_approve" phx-target={@myself} style="display:inline;">
          <input type="text" name="reason" placeholder="Approval note (optional)" style="width:260px;" />
          <button type="submit" class="btn btn-primary">Approve</button>
        </form>
        <form phx-submit="req_reject" phx-target={@myself} style="display:inline;">
          <input type="text" name="reason" placeholder="Rejection reason" required style="width:260px;" />
          <button type="submit" class="btn btn-danger">Reject</button>
        </form>
      <% end %>
    </.form_card>
    """
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("section", %{"s" => s}, socket) do
    section = String.to_existing_atom(s)
    socket = assign(socket, section: section)
    socket = if section == :requests, do: load_requests(socket), else: socket
    {:noreply, socket}
  end

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

  def handle_event("req_filter", params, socket) do
    socket =
      socket
      |> assign(filter_req_product: params["product_type"] || "", filter_req_status: params["status"] || "")
      |> load_requests()

    {:noreply, socket}
  end

  def handle_event("req_new", _params, socket) do
    {:noreply,
     assign(socket,
       req_mode: :new,
       req_step: 1,
       req_customer_search: "",
       req_customer_results: [],
       req_customer: nil,
       req_product_type: "",
       req_available_methods: [],
       req_method: nil,
       req_data: %{}
     )}
  end

  def handle_event("req_back_to_list", _params, socket) do
    {:noreply, socket |> assign(req_mode: :list) |> load_requests()}
  end

  def handle_event("req_view", %{"id" => id}, socket) do
    request = Requests.get!(id)
    method = Methods.get(request.kyc_method_id)
    {:noreply, assign(socket, req_mode: :detail, req_detail: request, req_detail_method: method)}
  end

  def handle_event("req_cust_search", %{"value" => q}, socket) do
    results =
      if String.length(q || "") >= 2 do
        term = "%#{q}%"

        Repo.all(
          from c in Customer,
            where:
              ilike(c.first_name, ^term) or ilike(c.last_name, ^term) or
                ilike(fragment("? || ' ' || ?", c.first_name, c.last_name), ^term) or
                ilike(c.email, ^term) or ilike(c.mobile_number, ^term),
            limit: 10
        )
      else
        []
      end

    {:noreply, assign(socket, req_customer_search: q, req_customer_results: results)}
  end

  def handle_event("req_select_customer", %{"id" => id}, socket) do
    case Repo.get(Customer, id) do
      nil ->
        {:noreply, socket}

      customer ->
        {:noreply,
         assign(socket,
           req_customer: customer,
           req_customer_results: [],
           req_step: 2
         )}
    end
  end

  def handle_event("req_select_product", %{"value" => product_type}, socket) do
    methods = Methods.list(%{"product_type" => product_type, "status" => "active"})
    {:noreply, assign(socket, req_product_type: product_type, req_available_methods: methods, req_method: nil)}
  end

  def handle_event("req_select_method", %{"value" => ""}, socket) do
    {:noreply, assign(socket, req_method: nil)}
  end

  def handle_event("req_select_method", %{"value" => method_id}, socket) do
    method = Methods.get!(method_id)
    {:noreply, assign(socket, req_method: method, req_data: %{}, req_step: 3)}
  end

  def handle_event("req_field_change", params, socket) do
    data = Map.get(params, "data", %{})
    {:noreply, update(socket, :req_data, &Map.merge(&1, data))}
  end

  def handle_event("req_submit", params, socket) do
    data = Map.get(params, "data", %{})

    attrs = %{
      "customer_id" => socket.assigns.req_customer.customer_id,
      "data" => data
    }

    case Requests.submit(socket.assigns.req_method, attrs) do
      {:ok, _request} ->
        {:noreply,
         socket
         |> assign(req_mode: :list, notice: "KYC request submitted", notice_kind: :success)
         |> load_requests()}

      {:error, changeset} ->
        {:noreply, assign(socket, notice: cs_error_msg(changeset), notice_kind: :error)}
    end
  end

  def handle_event("req_approve", %{"reason" => reason}, socket) do
    operator_id = operator_id(socket)

    case Requests.approve(socket.assigns.req_detail, operator_id, blank_to_nil(reason)) do
      {:ok, updated} ->
        {:noreply, assign(socket, req_detail: updated, notice: "Request approved", notice_kind: :success)}

      {:error, changeset} ->
        {:noreply, assign(socket, notice: cs_error_msg(changeset), notice_kind: :error)}
    end
  end

  def handle_event("req_reject", %{"reason" => reason}, socket) do
    operator_id = operator_id(socket)

    case Requests.reject(socket.assigns.req_detail, operator_id, reason) do
      {:ok, updated} ->
        {:noreply, assign(socket, req_detail: updated, notice: "Request rejected", notice_kind: :success)}

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

  # ---------------------------------------------------------------------------
  # Requests — private helpers
  # ---------------------------------------------------------------------------

  defp load_requests(socket) do
    filters = %{
      "product_type" => socket.assigns.filter_req_product,
      "status" => socket.assigns.filter_req_status
    }

    assign(socket, requests: Requests.list(filters))
  end

  defp customer_name(customer_id) do
    case Repo.get(Customer, customer_id) do
      nil -> "(unknown)"
      c -> "#{c.first_name} #{c.last_name}"
    end
  end

  defp operator_id(socket) do
    case socket.assigns[:current_operator] do
      %{operator_id: id} -> id
      _ -> @default_operator_id
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  # Dynamic form-field renderer for request submission. "group" (repeatable
  # sub-fields) isn't supported in the admin submission form yet -- v1 scope
  # limit, not an oversight (docs/kyc/KYC_Implementation_Tracker.md notes
  # this module's own field builder already supports the type; only the
  # *submission* renderer here doesn't yet).
  defp render_field_input(%{"type" => "group"} = field, _value) do
    assigns = %{field: field}

    ~H"""
    <em>Repeatable group fields aren't supported in the request form yet.</em>
    """
  end

  defp render_field_input(%{"type" => "textarea"} = field, value) do
    assigns = %{field: field, value: value}

    ~H"""
    <textarea name={"data[#{@field["key"]}]"} required={@field["required"]}><%= @value %></textarea>
    """
  end

  defp render_field_input(%{"type" => "select"} = field, value) do
    assigns = %{field: field, value: value}

    ~H"""
    <select name={"data[#{@field["key"]}]"} required={@field["required"]}>
      <option value="">Select...</option>
      <option :for={opt <- @field["options"] || []} value={opt} selected={@value == opt}><%= opt %></option>
    </select>
    """
  end

  defp render_field_input(%{"type" => "radio"} = field, value) do
    assigns = %{field: field, value: value}

    ~H"""
    <label :for={opt <- @field["options"] || []} style="margin-right:12px;">
      <input type="radio" name={"data[#{@field["key"]}]"} value={opt} checked={@value == opt} /> <%= opt %>
    </label>
    """
  end

  defp render_field_input(%{"type" => "checkbox", "options" => opts} = field, value) when is_list(opts) and opts != [] do
    assigns = %{field: field, options: opts, value: value || []}

    ~H"""
    <label :for={opt <- @options} style="margin-right:12px;">
      <input type="checkbox" name={"data[#{@field["key"]}][]"} value={opt} checked={opt in @value} /> <%= opt %>
    </label>
    """
  end

  defp render_field_input(%{"type" => "checkbox"} = field, value) do
    assigns = %{field: field, value: value}

    ~H"""
    <input type="checkbox" name={"data[#{@field["key"]}]"} value="true" checked={@value == "true"} />
    """
  end

  defp render_field_input(%{"type" => "file"} = field, value) do
    assigns = %{field: field, value: value}

    ~H"""
    <input type="text" name={"data[#{@field["key"]}]"} value={@value} placeholder="document reference (real upload arrives in KYC-P3)" required={@field["required"]} />
    """
  end

  defp render_field_input(%{"type" => type} = field, value) when type in ~w[text number email tel url password date] do
    assigns = %{field: field, value: value}

    ~H"""
    <input type={@field["type"]} name={"data[#{@field["key"]}]"} value={@value} required={@field["required"]} />
    """
  end

  defp render_field_input(field, value) do
    assigns = %{field: field, value: value}

    ~H"""
    <input type="text" name={"data[#{@field["key"]}]"} value={@value} required={@field["required"]} />
    """
  end
end
