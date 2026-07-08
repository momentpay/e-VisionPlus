defmodule VmuCoreWeb.Live.Admin.BlockComponent do
  @moduledoc """
  BLOCK parameter CRUD LiveComponent.

  A BLOCK is a sub-product tier within a LOGO (e.g. Gold / Platinum / Basic
  within the same BIN range). Every field is optional — nil means "inherit from
  the parent LOGO". The form shows the LOGO's current value next to each field
  as a reference, and only submits a value when the operator explicitly toggles
  the override checkbox.

  UX pattern: "Override toggle"
    □ Annual Fee  (Inherited from LOGO: 0.00)
    ☑ Annual Fee  [  150.00  ]  ← override active

  When a logo is selected in Step 1, the parent LogoParameter is loaded into
  @logo_parent so reference values are always current.
  """
  use Phoenix.LiveComponent

  import Ecto.Query, warn: false
  import VmuCoreWeb.AdminUI

  alias VmuCore.{Repo}
  alias VmuCore.Shared.{BlockParameter, LogoParameter, BankParameter, SysParameter, ParameterWriter}
  alias VmuCore.ASM.Authz

  @steps ["Identity", "Rates & Fees", "Billing & Limits", "Channels & STIP"]

  # ── Mount / Update ──────────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       mode: :list,
       editing: nil,
       result: nil,
       form_data: %{},
       overrides: %{},
       current_step: 1,
       steps: @steps,
       logo_parent: nil,
       filter_logo: nil,
       filter_bank: nil,
       current_operator: nil,
       can_edit: false
     )
     |> load_data()}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(can_edit: Authz.can?(assigns[:current_operator], "block", "edit"))}
  end

  defp load_data(socket) do
    blocks = Repo.all(BlockParameter)
    logos  = Repo.all(LogoParameter)
    banks  = Repo.all(BankParameter)
    syss   = Repo.all(SysParameter)
    assign(socket, blocks: blocks, logos: logos, banks: banks, sys_records: syss)
  end

  defp load_logo_parent(socket, logo_id, sys_id, bank_id) do
    logo =
      Repo.get_by(LogoParameter,
        logo_id: logo_id,
        sys_id: sys_id,
        bank_id: bank_id
      )
    assign(socket, logo_parent: logo)
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("block_new", _params, socket) do
    if socket.assigns.can_edit do
      sys_id  = case socket.assigns.sys_records do [s | _] -> s.sys_id;  _ -> "" end
      bank_id = case socket.assigns.banks       do [b | _] -> b.bank_id; _ -> "" end
      logo_id = case socket.assigns.logos       do [l | _] -> l.logo_id; _ -> "" end
      fd = default_form(sys_id, bank_id, logo_id)
      socket =
        socket
        |> assign(mode: :form, editing: nil, form_data: fd, overrides: %{},
                  current_step: 1, result: nil)
        |> load_logo_parent(logo_id, sys_id, bank_id)
      {:noreply, socket}
    else
      {:noreply, assign(socket, result: {:error, "Your role cannot create blocks."})}
    end
  end

  def handle_event("block_edit", %{"id" => block_id}, socket) do
    if not socket.assigns.can_edit do
      {:noreply, assign(socket, result: {:error, "Your role cannot edit blocks."})}
    else
      block = Enum.find(socket.assigns.blocks, &(&1.block_id == block_id))
      if block do
        fd = block_to_form(block)
        ov = detect_overrides(block)
        socket =
          socket
          |> assign(mode: :form, editing: block, form_data: fd, overrides: ov,
                    current_step: 1, result: nil)
          |> load_logo_parent(block.logo_id, block.sys_id, block.bank_id)
        {:noreply, socket}
      else
        {:noreply, assign(socket, result: {:error, "Block not found."})}
      end
    end
  end

  def handle_event("block_cancel", _params, socket) do
    {:noreply, socket |> assign(mode: :list, editing: nil, result: nil) |> load_data()}
  end

  def handle_event("block_filter", %{"bank_id" => bank_id, "logo_id" => logo_id}, socket) do
    {:noreply, assign(socket,
      filter_bank: nilify(bank_id),
      filter_logo: nilify(logo_id)
    )}
  end

  def handle_event("block_change", %{"block" => params}, socket) do
    # Re-load logo_parent when the parent selection changes
    socket =
      if logo_changed?(params, socket.assigns.form_data) do
        load_logo_parent(socket,
          params["logo_id"],
          params["sys_id"],
          params["bank_id"]
        )
      else
        socket
      end

    # Track which fields have overrides toggled on
    overrides = extract_overrides(params)
    {:noreply, assign(socket, form_data: params, overrides: overrides)}
  end

  def handle_event("step_go", %{"step" => s}, socket),
    do: {:noreply, assign(socket, current_step: String.to_integer(s))}

  def handle_event("step_next", _p, socket),
    do: {:noreply, assign(socket, current_step: min(socket.assigns.current_step + 1, length(@steps)))}

  def handle_event("step_prev", _p, socket),
    do: {:noreply, assign(socket, current_step: max(socket.assigns.current_step - 1, 1))}

  def handle_event("block_save", %{"block" => params}, socket) do
    if socket.assigns.can_edit do
      overrides = extract_overrides(params)
      attrs = build_attrs(params, overrides)

      result =
        case socket.assigns.editing do
          nil   -> ParameterWriter.create_block(attrs)
          block -> ParameterWriter.update_block(block, attrs)
        end

      case result do
        {:ok, _} ->
          label = if is_nil(socket.assigns.editing), do: "Block created.", else: "Block updated."
          {:noreply, socket |> load_data() |> assign(mode: :list, result: {:ok, label})}

        {:error, cs} ->
          msg = Enum.map_join(cs.errors, "; ", fn {f, {m, _}} -> "#{f}: #{m}" end)
          {:noreply, assign(socket, result: {:error, "Save failed — #{msg}"})}
      end
    else
      {:noreply, assign(socket, result: {:error, "Your role cannot save blocks."})}
    end
  end

  def handle_event("block_delete", %{"id" => block_id}, socket) do
    if socket.assigns.can_edit do
      block = Enum.find(socket.assigns.blocks, &(&1.block_id == block_id))
      if block do
        Repo.delete(block)
        VmuCore.Shared.ParameterEngine.refresh_all()
      end
      {:noreply, socket |> load_data() |> assign(result: {:ok, "Block #{block_id} deleted."})}
    else
      {:noreply, assign(socket, result: {:error, "Your role cannot delete blocks."})}
    end
  end

  # ── Form helpers ────────────────────────────────────────────────────────────

  defp default_form(sys_id, bank_id, logo_id) do
    %{
      "block_id" => "", "sys_id" => sys_id,
      "bank_id" => bank_id, "logo_id" => logo_id,
      "description" => ""
    }
  end

  defp block_to_form(%BlockParameter{} = b) do
    %{
      "block_id"    => b.block_id, "sys_id" => b.sys_id,
      "bank_id"     => b.bank_id,  "logo_id" => b.logo_id,
      "description" => b.description || "",
      "apr_percentage"           => dec(b.apr_percentage),
      "cash_apr_percentage"      => dec(b.cash_apr_percentage),
      "cash_advance_fee_percent" => dec(b.cash_advance_fee_percent),
      "annual_fee"               => dec(b.annual_fee),
      "late_fee"                 => dec(b.late_fee),
      "overlimit_fee"            => dec(b.overlimit_fee),
      "overlimit_allowed"        => bstr(b.overlimit_allowed),
      "min_payment_pct"          => dec(b.min_payment_pct),
      "min_payment_floor"        => dec(b.min_payment_floor),
      "min_payment_calculation"  => b.min_payment_calculation || "",
      "grace_days"               => istr(b.grace_days),
      "payment_due_days"         => istr(b.payment_due_days),
      "cash_limit_pct"           => dec(b.cash_limit_pct),
      "statement_cycle_days"     => istr(b.statement_cycle_days),
      "credit_limit_default"     => dec(b.credit_limit_default),
      "credit_limit_min"         => dec(b.credit_limit_min),
      "credit_limit_max"         => dec(b.credit_limit_max),
      "ecom_enabled"             => bstr(b.ecom_enabled),
      "atm_enabled"              => bstr(b.atm_enabled),
      "intl_enabled"             => bstr(b.intl_enabled),
      "contactless_enabled"      => bstr(b.contactless_enabled),
      "recurring_enabled"        => bstr(b.recurring_enabled),
      "moto_enabled"             => bstr(b.moto_enabled),
      "stip_enabled"             => bstr(b.stip_enabled),
      "stip_floor_limit"         => dec(b.stip_floor_limit),
      "stip_max_amount"          => dec(b.stip_max_amount)
    }
  end

  defp detect_overrides(%BlockParameter{} = b) do
    %{
      "apr_percentage"           => !is_nil(b.apr_percentage),
      "cash_apr_percentage"      => !is_nil(b.cash_apr_percentage),
      "cash_advance_fee_percent" => !is_nil(b.cash_advance_fee_percent),
      "annual_fee"               => !is_nil(b.annual_fee),
      "late_fee"                 => !is_nil(b.late_fee),
      "overlimit_fee"            => !is_nil(b.overlimit_fee),
      "overlimit_allowed"        => !is_nil(b.overlimit_allowed),
      "min_payment_pct"          => !is_nil(b.min_payment_pct),
      "min_payment_floor"        => !is_nil(b.min_payment_floor),
      "min_payment_calculation"  => !is_nil(b.min_payment_calculation),
      "grace_days"               => !is_nil(b.grace_days),
      "payment_due_days"         => !is_nil(b.payment_due_days),
      "cash_limit_pct"           => !is_nil(b.cash_limit_pct),
      "statement_cycle_days"     => !is_nil(b.statement_cycle_days),
      "credit_limit_default"     => !is_nil(b.credit_limit_default),
      "credit_limit_min"         => !is_nil(b.credit_limit_min),
      "credit_limit_max"         => !is_nil(b.credit_limit_max),
      "ecom_enabled"             => !is_nil(b.ecom_enabled),
      "atm_enabled"              => !is_nil(b.atm_enabled),
      "intl_enabled"             => !is_nil(b.intl_enabled),
      "contactless_enabled"      => !is_nil(b.contactless_enabled),
      "recurring_enabled"        => !is_nil(b.recurring_enabled),
      "moto_enabled"             => !is_nil(b.moto_enabled),
      "stip_enabled"             => !is_nil(b.stip_enabled),
      "stip_floor_limit"         => !is_nil(b.stip_floor_limit),
      "stip_max_amount"          => !is_nil(b.stip_max_amount)
    }
  end

  # Extract which override checkboxes are checked from submitted params
  defp extract_overrides(params) do
    Map.new(params, fn
      {"ov_" <> field, "true"} -> {field, true}
      {"ov_" <> field, _}      -> {field, false}
      {_k, _v}                 -> {"__skip__", false}
    end)
    |> Map.delete("__skip__")
  end

  defp logo_changed?(new_params, old_params) do
    new_params["logo_id"] != old_params["logo_id"] ||
    new_params["bank_id"] != old_params["bank_id"] ||
    new_params["sys_id"]  != old_params["sys_id"]
  end

  defp build_attrs(params, overrides) do
    base = %{
      block_id:    params["block_id"],
      sys_id:      params["sys_id"],
      bank_id:     params["bank_id"],
      logo_id:     params["logo_id"],
      description: nilify(params["description"])
    }

    # Only include override fields where the checkbox was ticked
    overridable = [
      {:apr_percentage,           &dp/1},
      {:cash_apr_percentage,      &dp/1},
      {:cash_advance_fee_percent, &dp/1},
      {:annual_fee,               &dp/1},
      {:late_fee,                 &dp/1},
      {:overlimit_fee,            &dp/1},
      {:overlimit_allowed,        &bp/1},
      {:min_payment_pct,          &dp/1},
      {:min_payment_floor,        &dp/1},
      {:min_payment_calculation,  &nilify/1},
      {:grace_days,               &ip/1},
      {:payment_due_days,         &ip/1},
      {:cash_limit_pct,           &dp/1},
      {:statement_cycle_days,     &ip/1},
      {:credit_limit_default,     &dp/1},
      {:credit_limit_min,         &dp/1},
      {:credit_limit_max,         &dp/1},
      {:ecom_enabled,             &bp/1},
      {:atm_enabled,              &bp/1},
      {:intl_enabled,             &bp/1},
      {:contactless_enabled,      &bp/1},
      {:recurring_enabled,        &bp/1},
      {:moto_enabled,             &bp/1},
      {:stip_enabled,             &bp/1},
      {:stip_floor_limit,         &dp/1},
      {:stip_max_amount,          &dp/1}
    ]

    Enum.reduce(overridable, base, fn {field, cast_fn}, acc ->
      key = to_string(field)
      if Map.get(overrides, key) == true do
        Map.put(acc, field, cast_fn.(params[key]))
      else
        Map.put(acc, field, nil)
      end
    end)
  end

  defp dec(nil), do: ""
  defp dec(d),   do: Decimal.to_string(d)

  defp istr(nil), do: ""
  defp istr(n),   do: to_string(n)

  defp bstr(nil),   do: ""
  defp bstr(true),  do: "true"
  defp bstr(false), do: "false"

  defp dp(""), do: nil
  defp dp(nil), do: nil
  defp dp(s) do
    case Decimal.parse(to_string(s)) do
      {d, ""} -> d
      _       -> nil
    end
  end

  defp ip(""), do: nil
  defp ip(nil), do: nil
  defp ip(s) do
    case Integer.parse(to_string(s)) do
      {n, _} -> n
      _      -> nil
    end
  end

  defp bp("true"), do: true
  defp bp("false"), do: false
  defp bp(_), do: nil

  defp nilify(nil), do: nil
  defp nilify(""), do: nil
  defp nilify(s),   do: s

  # ── Logo parent display helpers ─────────────────────────────────────────────

  defp lval(nil, _field), do: "—"
  defp lval(logo, field) do
    case Map.get(logo, field) do
      nil   -> "—"
      true  -> "Yes"
      false -> "No"
      v     -> to_string(v)
    end
  end

  defp overriding?(overrides, field), do: Map.get(overrides, to_string(field)) == true

  # ── Render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_header title="Sub-Product Blocks"
        subtitle="Tier overrides within a LOGO — Gold / Platinum / Basic / Corporate etc.">
        <:actions>
          <button :if={@mode == :list && @can_edit} phx-click="block_new" phx-target={@myself} class="btn btn-primary">
            + New Block
          </button>
        </:actions>
      </.page_header>

      <%= if @result do %>
        <% {kind, msg} = @result %>
        <.alert kind={kind} message={msg} />
      <% end %>

      <%= if @mode == :list do %>
        <.render_list blocks={@blocks} banks={@banks} logos={@logos}
          myself={@myself} filter_bank={@filter_bank} filter_logo={@filter_logo} can_edit={@can_edit} />
      <% else %>
        <.render_form
          form_data={@form_data} overrides={@overrides}
          editing={@editing} myself={@myself}
          banks={@banks} logos={@logos} sys_records={@sys_records}
          logo_parent={@logo_parent}
          current_step={@current_step} steps={@steps}
        />
      <% end %>
    </div>
    """
  end

  # ── List ─────────────────────────────────────────────────────────────────────

  defp render_list(assigns) do
    filtered =
      assigns.blocks
      |> then(fn bs ->
        if assigns.filter_bank, do: Enum.filter(bs, &(&1.bank_id == assigns.filter_bank)), else: bs
      end)
      |> then(fn bs ->
        if assigns.filter_logo, do: Enum.filter(bs, &(&1.logo_id == assigns.filter_logo)), else: bs
      end)
    assigns = assign(assigns, filtered: filtered)
    ~H"""
    <!-- Filter bar -->
    <form phx-change="block_filter" phx-target={@myself} class="flex items-center gap-3 mb-4">
      <label class="text-sm font-bold" style="color:var(--text-secondary);">Filter:</label>
      <select name="bank_id" style="width:auto;padding:6px 10px;font-size:13px;">
        <option value="">All Organisations</option>
        <%= for bank <- @banks do %>
          <option value={bank.bank_id} selected={@filter_bank == bank.bank_id}>
            <%= bank.bank_id %> — <%= bank.org_name || bank.description %>
          </option>
        <% end %>
      </select>
      <select name="logo_id" style="width:auto;padding:6px 10px;font-size:13px;">
        <option value="">All Products</option>
        <%= for logo <- @logos do %>
          <option value={logo.logo_id} selected={@filter_logo == logo.logo_id}>
            <%= logo.logo_id %> — <%= logo.description %>
          </option>
        <% end %>
      </select>
      <span class="text-sm text-muted"><%= length(@filtered) %> block(s)</span>
    </form>

    <%= if @filtered == [] do %>
      <.empty_state icon="🧩" title="No Blocks Defined"
        message="Blocks let you create Gold / Platinum / Basic tiers within a single card product (LOGO).">
        <:actions>
          <button :if={@can_edit} phx-click="block_new" phx-target={@myself} class="btn btn-primary">+ New Block</button>
        </:actions>
      </.empty_state>
    <% else %>
      <div class="card">
        <table class="data-table">
          <thead>
            <tr>
              <th>BLOCK ID</th>
              <th>LOGO</th>
              <th>ORG</th>
              <th>Description</th>
              <th>Overriding Fields</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for block <- @filtered do %>
              <% fields = BlockParameter.overriding_fields(block) %>
              <tr>
                <td><span class="mono"><%= block.block_id %></span></td>
                <td><span class="mono"><%= block.logo_id %></span></td>
                <td><span class="mono"><%= block.bank_id %></span></td>
                <td>
                  <div style="font-weight:500;"><%= block.description || "—" %></div>
                </td>
                <td>
                  <%= if fields == [] do %>
                    <span class="text-muted text-xs">None (inherits all from LOGO)</span>
                  <% else %>
                    <div style="display:flex;gap:4px;flex-wrap:wrap;">
                      <%= for f <- fields do %>
                        <span class="badge badge-blue" style="font-size:10px;"><%= f %></span>
                      <% end %>
                    </div>
                  <% end %>
                </td>
                <td>
                  <div class="actions">
                    <button :if={@can_edit} phx-click="block_edit" phx-target={@myself}
                      phx-value-id={block.block_id} class="btn btn-sm btn-secondary">Edit</button>
                    <button :if={@can_edit} phx-click="block_delete" phx-target={@myself}
                      phx-value-id={block.block_id} class="btn btn-sm btn-danger"
                      data-confirm={"Delete block #{block.block_id}?"}>Delete</button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% end %>
    """
  end

  # ── Form ─────────────────────────────────────────────────────────────────────

  defp render_form(assigns) do
    assigns = assign(assigns, is_new: is_nil(assigns.editing))
    ~H"""
    <form phx-change="block_change" phx-submit="block_save" phx-target={@myself}>
      <div class="card">
        <div class="card-header">
          <div>
            <div class="card-title">
              <%= if @is_new, do: "New Block / Sub-Product Tier", else: "Edit Block" %>
            </div>
            <div class="card-subtitle">
              Leave a field un-ticked to inherit the parent LOGO's value. The LOGO default is shown in grey.
            </div>
          </div>
        </div>
        <div class="card-body">

          <.step_nav steps={@steps} current_step={@current_step} />

          <!-- ── Step 1: Identity ───────────────────────────────────────── -->
          <div style={"#{if @current_step != 1, do: "display:none"}"}>
            <div class="form-grid">
              <div class="field">
                <label>BLOCK ID <span style="color:var(--danger)">*</span></label>
                <input type="text" name="block[block_id]" value={@form_data["block_id"]}
                  maxlength="4" placeholder="GOLD"
                  disabled={!@is_new}
                  style="font-family:var(--font-mono);letter-spacing:.1em;text-transform:uppercase;"/>
                <p class="hint">4-character tier code: GOLD, PLAT, BSIC, CORP, PRME…</p>
              </div>
              <div class="field">
                <label>Description</label>
                <input type="text" name="block[description]" value={@form_data["description"]}
                  placeholder="e.g. Gold Tier — Premium Customers"/>
              </div>
              <div class="field">
                <label>Parent LOGO / Product <span style="color:var(--danger)">*</span></label>
                <select name="block[logo_id]">
                  <%= for logo <- @logos do %>
                    <option value={logo.logo_id} selected={@form_data["logo_id"] == logo.logo_id}>
                      <%= logo.logo_id %> — <%= logo.description %>
                    </option>
                  <% end %>
                </select>
                <p class="hint">This block inherits all un-overridden fields from this LOGO.</p>
              </div>
              <div class="field">
                <label>Organisation (BANK ID) <span style="color:var(--danger)">*</span></label>
                <select name="block[bank_id]">
                  <%= for bank <- @banks do %>
                    <option value={bank.bank_id} selected={@form_data["bank_id"] == bank.bank_id}>
                      <%= bank.bank_id %> — <%= bank.org_name || bank.description %>
                    </option>
                  <% end %>
                </select>
              </div>
              <div class="field">
                <label>SYS ID <span style="color:var(--danger)">*</span></label>
                <select name="block[sys_id]">
                  <%= for sys <- @sys_records do %>
                    <option value={sys.sys_id} selected={@form_data["sys_id"] == sys.sys_id}>
                      <%= sys.sys_id %> — <%= sys.description %>
                    </option>
                  <% end %>
                </select>
              </div>
            </div>

            <%= if @logo_parent do %>
              <div class="alert alert-info mt-4">
                <span class="icon">ℹ</span>
                <div>
                  <strong>LOGO parent loaded:</strong> <%= @logo_parent.description %>
                  (<%= @logo_parent.logo_id %> / BIN <%= @logo_parent.bin_prefix %>)
                  — override only the fields that differ for this block.
                </div>
              </div>
            <% end %>
          </div>

          <!-- ── Step 2: Rates & Fees ───────────────────────────────────── -->
          <div style={"#{if @current_step != 2, do: "display:none"}"}>
            <div class="form-section" style="padding-top:0;border-top:none;">
              <div class="form-section-title">Interest Rate Overrides</div>
              <.override_row field="apr_percentage" label="Purchase APR (%)"
                logo_val={lval(@logo_parent, :purchase_apr)}
                overrides={@overrides} form_data={@form_data}
                step="0.01" min="0" max="99" />
              <.override_row field="cash_apr_percentage" label="Cash Advance APR (%)"
                logo_val={lval(@logo_parent, :cash_apr)}
                overrides={@overrides} form_data={@form_data}
                step="0.01" min="0" max="99" />
            </div>
            <div class="form-section">
              <div class="form-section-title">Fee Overrides</div>
              <.override_row field="cash_advance_fee_percent" label="Cash Advance Fee (%)"
                logo_val={lval(@logo_parent, :cash_advance_fee_percent)}
                overrides={@overrides} form_data={@form_data} step="0.01" />
              <.override_row field="annual_fee" label="Annual Fee"
                logo_val={lval(@logo_parent, :annual_fee)}
                overrides={@overrides} form_data={@form_data} step="0.01" />
              <.override_row field="late_fee" label="Late Payment Fee"
                logo_val={lval(@logo_parent, :late_fee)}
                overrides={@overrides} form_data={@form_data} step="0.01" />
              <.override_row field="overlimit_fee" label="Overlimit Fee"
                logo_val={lval(@logo_parent, :overlimit_fee)}
                overrides={@overrides} form_data={@form_data} step="0.01" />
            </div>
          </div>

          <!-- ── Step 3: Billing & Limits ───────────────────────────────── -->
          <div style={"#{if @current_step != 3, do: "display:none"}"}>
            <div class="form-section" style="padding-top:0;border-top:none;">
              <div class="form-section-title">Overlimit & Minimum Payment</div>
              <.override_bool_row
                field="overlimit_allowed" label="Allow Overlimit Transactions"
                logo_val={lval(@logo_parent, :overlimit_allowed)}
                overrides={@overrides} form_data={@form_data}
              />
              <.override_row field="min_payment_pct" label="Minimum Payment (%)"
                logo_val={lval(@logo_parent, :min_payment_pct)}
                overrides={@overrides} form_data={@form_data} step="0.01" max="100" />
              <.override_row field="min_payment_floor" label="Minimum Payment Floor"
                logo_val={lval(@logo_parent, :min_payment_floor)}
                overrides={@overrides} form_data={@form_data} step="0.01" />
              <.override_row field="grace_days" label="Grace Days"
                logo_val={lval(@logo_parent, :grace_days)}
                overrides={@overrides} form_data={@form_data} max="60" />
              <.override_row field="cash_limit_pct" label="Cash Limit (% of Credit Limit)"
                logo_val={lval(@logo_parent, :cash_limit_pct)}
                overrides={@overrides} form_data={@form_data} step="0.01" max="100" />
            </div>
            <div class="form-section">
              <div class="form-section-title">Credit Limit Overrides</div>
              <.override_row field="credit_limit_default" label="Default Credit Limit"
                logo_val={lval(@logo_parent, :credit_limit_default)}
                overrides={@overrides} form_data={@form_data} step="0.01" />
              <.override_row field="credit_limit_min" label="Minimum Credit Limit"
                logo_val={lval(@logo_parent, :credit_limit_min)}
                overrides={@overrides} form_data={@form_data} step="0.01" />
              <.override_row field="credit_limit_max" label="Maximum Credit Limit"
                logo_val={lval(@logo_parent, :credit_limit_max)}
                overrides={@overrides} form_data={@form_data} step="0.01" />
            </div>
          </div>

          <!-- ── Step 4: Channels & STIP ────────────────────────────────── -->
          <div style={"#{if @current_step != 4, do: "display:none"}"}>
            <div class="form-section" style="padding-top:0;border-top:none;">
              <div class="form-section-title">Auth Channel Overrides</div>
              <p class="text-sm text-muted mb-4">
                Tick a channel to override the LOGO setting for this block tier only.
              </p>
              <div class="form-grid">
                <div>
                  <.override_bool_row field="ecom_enabled"        label="eCommerce (CNP)" logo_val={lval(@logo_parent, :ecom_enabled)}        overrides={@overrides} form_data={@form_data} />
                  <.override_bool_row field="atm_enabled"         label="ATM Withdrawals"  logo_val={lval(@logo_parent, :atm_enabled)}         overrides={@overrides} form_data={@form_data} />
                  <.override_bool_row field="intl_enabled"        label="International"    logo_val={lval(@logo_parent, :intl_enabled)}        overrides={@overrides} form_data={@form_data} />
                </div>
                <div>
                  <.override_bool_row field="contactless_enabled" label="Contactless / NFC" logo_val={lval(@logo_parent, :contactless_enabled)} overrides={@overrides} form_data={@form_data} />
                  <.override_bool_row field="recurring_enabled"   label="Recurring Payments" logo_val={lval(@logo_parent, :recurring_enabled)}   overrides={@overrides} form_data={@form_data} />
                  <.override_bool_row field="moto_enabled"        label="MOTO"              logo_val={lval(@logo_parent, :moto_enabled)}        overrides={@overrides} form_data={@form_data} />
                </div>
              </div>
            </div>
            <div class="form-section">
              <div class="form-section-title">STIP Stand-In Overrides</div>
              <.override_bool_row field="stip_enabled"     label="Enable STIP"              logo_val={lval(@logo_parent, :stip_enabled)}     overrides={@overrides} form_data={@form_data} />
              <.override_row field="stip_floor_limit" label="STIP Floor Limit"
                logo_val={lval(@logo_parent, :stip_floor_limit)}
                overrides={@overrides} form_data={@form_data} step="0.01" />
              <.override_row field="stip_max_amount" label="STIP Maximum Amount"
                logo_val={lval(@logo_parent, :stip_max_amount)}
                overrides={@overrides} form_data={@form_data} step="0.01" />
            </div>
          </div>

        </div>
        <div class="card-footer">
          <button :if={@current_step > 1} type="button"
            phx-click="step_prev" phx-target={@myself} class="btn btn-secondary">← Previous</button>
          <button type="button" phx-click="block_cancel" phx-target={@myself} class="btn btn-secondary">Cancel</button>
          <div style="margin-left:auto;display:flex;gap:10px;">
            <button :if={@current_step < length(@steps)} type="button"
              phx-click="step_next" phx-target={@myself} class="btn btn-secondary">Next →</button>
            <button :if={@current_step == length(@steps)} type="submit" class="btn btn-primary">
              💾 <%= if @is_new, do: "Create Block", else: "Save Changes" %>
            </button>
          </div>
        </div>
      </div>
    </form>
    """
  end

  # ── Override row sub-components ─────────────────────────────────────────────

  # Numeric / text override row
  attr :field,     :string, required: true
  attr :label,     :string, required: true
  attr :logo_val,  :string, required: true
  attr :overrides, :map,    required: true
  attr :form_data, :map,    required: true
  attr :step,      :string, default: nil
  attr :min,       :string, default: "0"
  attr :max,       :string, default: nil
  attr :input_type, :string, default: "number"

  defp override_row(assigns) do
    assigns = assign(assigns, active: Map.get(assigns.overrides, assigns.field) == true)
    ~H"""
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px 24px;align-items:start;padding:10px 0;border-bottom:1px solid var(--border);">
      <div style="display:flex;align-items:center;gap:10px;">
        <input type="checkbox" id={"ov_#{@field}"} name={"block[ov_#{@field}]"} value="true"
          checked={@active}
          style="width:16px;height:16px;accent-color:var(--accent);flex-shrink:0;"/>
        <label for={"ov_#{@field}"} style="font-size:13.5px;font-weight:500;cursor:pointer;">
          <%= @label %>
        </label>
      </div>
      <div>
        <%= if @active do %>
          <input
            type={@input_type}
            name={"block[#{@field}]"}
            value={@form_data[@field]}
            step={@step}
            min={@min}
            max={@max}
            style="width:100%;padding:6px 10px;font-size:13px;border:1px solid var(--border-dark);border-radius:var(--radius);"
          />
        <% else %>
          <span style="font-size:12.5px;color:var(--text-muted);font-style:italic;">
            Inherited from LOGO: <strong style="color:var(--text-secondary)"><%= @logo_val %></strong>
          </span>
        <% end %>
      </div>
    </div>
    """
  end

  # Boolean toggle override row
  attr :field,     :string, required: true
  attr :label,     :string, required: true
  attr :logo_val,  :string, required: true
  attr :overrides, :map,    required: true
  attr :form_data, :map,    required: true

  defp override_bool_row(assigns) do
    active = Map.get(assigns.overrides, assigns.field) == true
    assigns = assign(assigns, active: active)
    ~H"""
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px 24px;align-items:center;padding:10px 0;border-bottom:1px solid var(--border);">
      <div style="display:flex;align-items:center;gap:10px;">
        <input type="checkbox" id={"ov_#{@field}"} name={"block[ov_#{@field}]"} value="true"
          checked={@active} style="width:16px;height:16px;accent-color:var(--accent);flex-shrink:0;"/>
        <label for={"ov_#{@field}"} style="font-size:13.5px;font-weight:500;cursor:pointer;">
          <%= @label %>
        </label>
      </div>
      <div>
        <%= if @active do %>
          <div style="display:flex;gap:16px;">
            <label style="display:flex;align-items:center;gap:6px;font-size:13px;cursor:pointer;">
              <input type="radio" name={"block[#{@field}]"} value="true"
                checked={@form_data[@field] == "true"}/> Enabled
            </label>
            <label style="display:flex;align-items:center;gap:6px;font-size:13px;cursor:pointer;">
              <input type="radio" name={"block[#{@field}]"} value="false"
                checked={@form_data[@field] == "false"}/> Disabled
            </label>
          </div>
        <% else %>
          <span style="font-size:12.5px;color:var(--text-muted);font-style:italic;">
            Inherited from LOGO: <strong style="color:var(--text-secondary)"><%= @logo_val %></strong>
          </span>
        <% end %>
      </div>
    </div>
    """
  end
end
