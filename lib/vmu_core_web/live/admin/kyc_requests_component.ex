defmodule VmuCoreWeb.Live.Admin.KycRequestsComponent do
  @moduledoc """
  Admin LiveComponent: KYC request submission/review (KYC-P2/P3/P3.5,
  `docs/kyc/KYC_Implementation_Tracker.md`).

  Split out from the combined `KycComponent` (KYC-P3.5, confirmed with the
  user 2026-07-29) — request review is a different role than method-template
  design, now gated by its own `kyc_requests` permission and its own sidebar
  entry instead of sharing one `kyc` module with `KycMethodsComponent`.

  Admin-initiated submission (search/select customer, pick a product, work
  through its step journey in order — `VmuCore.Kyc.Journey` — fill in the
  form for the current unlocked step; fields hidden by a conditional rule
  stay hidden as data is entered), a queue filterable by product/status, and
  detail/Approve/Reject. Approve/Reject fire `Kyc.StatusSync` — the real
  integration point that keeps the five pre-existing per-product
  `kyc_status` flags (Customer/Debit/Prepaid/Wallet/HCS.Company) accurate.
  Request detail also has a Documents panel: real file upload (one shared
  upload slot + a field picker, same shape as `DpsComponent`'s evidence
  panel) triggering OCR extraction via `Kyc.Adapters.OcrHttpAdapter`, plus a
  comment/approval/rejection annotation trail per document.

  Visibility requires `kyc_requests:view`; submit/approve/reject/upload/
  annotate actions require `kyc_requests:edit`.
  """

  use Phoenix.LiveComponent
  import Ecto.Query, except: [update: 2, update: 3]
  import VmuCoreWeb.AdminUI
  import VmuCoreWeb.Components.AgGrid

  alias VmuCore.Repo
  alias VmuCore.Kyc.{Request, Requests, ConditionalLogic, Documents, Journey}
  alias VmuCore.CMS.Arrangement
  alias VmuCore.Shared.Customer
  alias VmuCore.ASM.Authz

  @default_operator_id "00000000-0000-0000-0000-000000000001"
  @max_document_bytes 10_000_000

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       req_mode: :list,
       requests: [],
       filter_req_product: "",
       filter_req_status: "",
       can_edit: false,
       notice: nil,
       notice_kind: :info,
       req_step: 1,
       req_customer_search: "",
       req_customer_results: [],
       req_customer: nil,
       req_product_type: "",
       req_journey: [],
       req_method: nil,
       req_data: %{},
       req_detail: nil,
       req_detail_method: nil,
       req_documents: [],
       req_annotations_by_doc: %{},
       upload_field_key: ""
     )
     |> allow_upload(:kyc_document, accept: :any, max_entries: 1, max_file_size: @max_document_bytes)
     |> load_requests()}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    operator = socket.assigns[:current_operator]
    {:ok, assign(socket, can_edit: operator && Authz.can?(operator, "kyc_requests", "edit"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_header title="KYC Requests" subtitle="Admin-initiated submission, review, and approval">
        <:actions>
          <button :if={@can_edit} type="button" phx-click="req_new" phx-target={@myself} class="btn btn-primary">
            + New Request
          </button>
        </:actions>
      </.page_header>

      <.alert :if={@notice} kind={@notice_kind} message={@notice} />

      <%= case @req_mode do %>
        <% :list -> %><%= render_list(assigns) %>
        <% :new -> %><%= render_new(assigns) %>
        <% :detail -> %><%= render_detail(assigns) %>
      <% end %>
    </div>
    """
  end

  defp render_list(assigns) do
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
      <.empty_state icon="📋" title="No KYC requests yet" message="Start one with + New Request." />
    <% else %>
      <table class="admin-table">
        <thead>
          <tr>
            <th>Application #</th>
            <th>Customer</th>
            <th>Product</th>
            <th>Step</th>
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
            <td><%= r.step %></td>
            <td><.status_badge status={r.status} /></td>
            <td><%= r.submitted_at %></td>
            <td><button type="button" phx-click="req_view" phx-value-id={r.request_id} phx-target={@myself} class="btn btn-sm">View</button></td>
          </tr>
        </tbody>
      </table>
    <% end %>
    """
  end

  defp render_new(assigns) do
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

        <.empty_state :if={@req_product_type != "" && @req_journey == []} icon="🪪" title="No active method for this product yet" message="Create one on the KYC Methods screen first." />

        <table :if={@req_journey != []} class="admin-table">
          <thead><tr><th>Step</th><th>Method</th><th>Status</th><th></th></tr></thead>
          <tbody>
            <tr :for={%{method: m, status: status} <- @req_journey}>
              <td><%= m.step %></td>
              <td><%= m.name %><%= if !m.required, do: " (optional)" %></td>
              <td><%= journey_status_label(status) %></td>
              <td>
                <button :if={status in [:current, :done]} type="button" phx-click="req_select_method" phx-value-id={m.method_id} phx-target={@myself} class="btn btn-sm">
                  <%= if status == :done, do: "Resubmit", else: "Start" %>
                </button>
                <span :if={status == :locked} style="color:#999; font-size:12px;">🔒 complete an earlier step first</span>
              </td>
            </tr>
          </tbody>
        </table>
      <% end %>

      <%= if @req_step == 3 do %>
        <p>Customer: <strong><%= @req_customer.first_name %> <%= @req_customer.last_name %></strong> — Product: <strong><%= @req_product_type %></strong> — Step <%= @req_method.step %>: <strong><%= @req_method.name %></strong></p>
        <form phx-submit="req_submit" phx-change="req_field_change" phx-target={@myself}>
          <.field :for={f <- ConditionalLogic.visible_fields(@req_method.fields, @req_method.conditional_rules || [], @req_data)} label={f["label"] <> if(f["required"], do: " *", else: "")}>
            <%= render_field_input(f, @req_data[f["key"]]) %>
          </.field>
          <button type="submit" class="btn btn-primary" style="margin-top:16px;">Submit Request</button>
        </form>
      <% end %>
    </.form_card>
    """
  end

  defp render_detail(assigns) do
    ~H"""
    <.form_card title={"Request #{@req_detail.application_number}"}>
      <:header_actions>
        <button type="button" phx-click="req_back_to_list" phx-target={@myself} class="btn btn-sm">&larr; Back to list</button>
      </:header_actions>

      <.kv_detail rows={[
        {"Customer", customer_name(@req_detail.customer_id)},
        {"Product", @req_detail.product_type},
        {"Step", "#{@req_detail.step}"},
        {"Method", @req_detail_method && @req_detail_method.name},
        {"Status", @req_detail.status},
        {"Submitted", to_string(@req_detail.submitted_at)},
        {"Reviewer", @req_detail.reviewer_id},
        {"Decision reason", @req_detail.decision_reason}
      ]} />

      <.form_section title="Submitted Data" />
      <.ag_grid
        id="kyc-request-submitted-data-grid"
        paginate={false}
        empty_message="No fields submitted."
        columns={[
          %{field: "label", header: "Field", width: 240},
          %{field: "value", header: "Value", flex: 1}
        ]}
        rows={Enum.map(@req_detail.fields_snapshot, &submitted_field_row(&1, @req_detail.data))}
      />

      <.form_section title="Documents" />
      <%= if @can_edit do %>
        <form phx-submit="doc_upload" phx-change="doc_field_pick" phx-target={@myself} style="margin-bottom:12px;">
          <select name="field_key">
            <option value="">Which field is this for?</option>
            <option :for={f <- file_fields(@req_detail.fields_snapshot)} value={f["key"]} selected={@upload_field_key == f["key"]}><%= f["label"] %></option>
          </select>
          <.live_file_input upload={@uploads.kyc_document} />
          <div :for={err <- upload_errors(@uploads.kyc_document)} class="field-error"><%= inspect(err) %></div>
          <button type="submit" class="btn btn-sm btn-primary" disabled={@upload_field_key == ""}>Upload</button>
        </form>
      <% end %>

      <.empty_state :if={@req_documents == []} icon="📄" title="No documents uploaded yet" />
      <div :for={doc <- @req_documents} style="border:1px solid #ddd; border-radius:6px; padding:10px; margin-bottom:10px;">
        <strong><%= doc.field_key %></strong> — <%= doc.original_filename %>
        <p :if={doc.ocr_result} style="font-size:12px; color:#555;">OCR: <%= get_in(doc.ocr_result, ["simplified_text", "raw_text"]) || inspect(doc.ocr_result) %></p>
        <p :if={!doc.ocr_result} style="font-size:12px; color:#999;">No OCR result.</p>

        <div :for={ann <- Map.get(@req_annotations_by_doc, doc.document_id, [])} style="font-size:12px; margin:4px 0;">
          <.status_badge status={ann.type} /> <%= ann.content %>
        </div>

        <%= if @can_edit do %>
          <form phx-submit="doc_annotate" phx-value-document_id={doc.document_id} phx-target={@myself} style="margin-top:6px;">
            <select name="type">
              <option :for={t <- VmuCore.Kyc.DocumentAnnotation.types()} value={t}><%= t %></option>
            </select>
            <input type="text" name="content" placeholder="Note (optional)" style="width:220px;" />
            <button type="submit" class="btn btn-sm">Add</button>
          </form>
        <% end %>
      </div>

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
       req_journey: [],
       req_method: nil,
       req_data: %{}
     )}
  end

  def handle_event("req_back_to_list", _params, socket) do
    {:noreply, socket |> assign(req_mode: :list) |> load_requests()}
  end

  def handle_event("req_view", %{"id" => id}, socket) do
    request = Requests.get!(id)
    method = VmuCore.Kyc.Methods.get(request.kyc_method_id)

    {:noreply,
     socket
     |> assign(req_mode: :detail, req_detail: request, req_detail_method: method, upload_field_key: "")
     |> load_documents()}
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
    journey = Journey.progress(socket.assigns.req_customer.customer_id, product_type)
    {:noreply, assign(socket, req_product_type: product_type, req_journey: journey, req_method: nil)}
  end

  def handle_event("req_select_method", %{"id" => method_id}, socket) do
    method = VmuCore.Kyc.Methods.get!(method_id)
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

      {:error, :step_locked} ->
        {:noreply, assign(socket, notice: "An earlier required step for this product isn't approved yet", notice_kind: :error)}

      {:error, changeset} ->
        {:noreply, assign(socket, notice: cs_error_msg(changeset), notice_kind: :error)}
    end
  end

  def handle_event("req_approve", %{"reason" => reason}, socket) do
    operator_id = operator_id(socket)

    case Requests.approve(socket.assigns.req_detail, operator_id, blank_to_nil(reason)) do
      {:ok, updated} ->
        {:noreply, assign(socket, req_detail: updated, notice: "Request approved", notice_kind: :success)}

      {:error, {:sanctions_hit, hit}} ->
        notice = "Approval blocked: sanctions screening matched \"#{hit.matched_name}\" (#{hit.list_type}). Escalate to compliance before proceeding."
        {:noreply, assign(socket, notice: notice, notice_kind: :error)}

      {:error, :screening_unavailable} ->
        notice = "Approval blocked: sanctions screening could not complete. Try again, or escalate to compliance."
        {:noreply, assign(socket, notice: notice, notice_kind: :error)}

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

  def handle_event("doc_field_pick", %{"field_key" => field_key}, socket) do
    {:noreply, assign(socket, upload_field_key: field_key)}
  end

  def handle_event("doc_upload", _params, socket) do
    field_key = socket.assigns.upload_field_key
    request_id = socket.assigns.req_detail.request_id

    # `consume_uploaded_entries/3` requires the callback to return `{:ok,
    # term}` and itself unwraps that one level -- `term` here is
    # `Documents.upload/3`'s own `{:ok, document} | {:error, changeset}`,
    # not double-wrapped. Same gotcha DPS's evidence panel already documents.
    results =
      consume_uploaded_entries(socket, :kyc_document, fn %{path: tmp_path}, entry ->
        {:ok,
         Documents.upload(request_id, field_key, %{
           filename: entry.client_name,
           content_type: entry.client_type,
           tmp_path: tmp_path
         })}
      end)

    case results do
      [{:ok, _document}] ->
        {:noreply,
         socket
         |> assign(upload_field_key: "", notice: "Document uploaded", notice_kind: :success)
         |> load_documents()}

      [{:error, changeset}] ->
        {:noreply, assign(socket, notice: cs_error_msg(changeset), notice_kind: :error)}

      [] ->
        {:noreply, assign(socket, notice: "Choose a file first", notice_kind: :error)}
    end
  end

  def handle_event("doc_annotate", %{"document_id" => document_id, "type" => type, "content" => content}, socket) do
    operator_id = operator_id(socket)

    case Documents.annotate(document_id, type, blank_to_nil(content), operator_id) do
      {:ok, _annotation} ->
        {:noreply, socket |> assign(notice: "Annotation added", notice_kind: :success) |> load_documents()}

      {:error, changeset} ->
        {:noreply, assign(socket, notice: cs_error_msg(changeset), notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_requests(socket) do
    filters = %{
      "product_type" => socket.assigns.filter_req_product,
      "status" => socket.assigns.filter_req_status
    }

    assign(socket, requests: Requests.list(filters))
  end

  defp load_documents(socket) do
    documents = Documents.list_for_request(socket.assigns.req_detail.request_id)

    annotations_by_doc =
      Map.new(documents, fn doc -> {doc.document_id, Documents.list_annotations(doc.document_id)} end)

    assign(socket, req_documents: documents, req_annotations_by_doc: annotations_by_doc)
  end

  defp file_fields(fields_snapshot) do
    Enum.filter(fields_snapshot, &(&1["type"] == "file"))
  end

  defp submitted_field_row(f, data) do
    %{label: f["label"], value: data[f["key"]] || ""}
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

  defp journey_status_label(:done), do: "✅ Done"
  defp journey_status_label(:current), do: "▶ Current"
  defp journey_status_label(:locked), do: "🔒 Locked"

  # Dynamic form-field renderer for request submission. "group" (repeatable
  # sub-fields) isn't supported in the admin submission form yet -- v1 scope
  # limit, not an oversight (docs/kyc/KYC_Implementation_Tracker.md notes
  # this the method builder already supports the type; only the
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
    <input type="text" name={"data[#{@field["key"]}]"} value={@value} placeholder="document reference (upload the actual file from the request detail's Documents panel)" required={@field["required"]} />
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
