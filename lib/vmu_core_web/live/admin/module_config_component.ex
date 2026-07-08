defmodule VmuCoreWeb.Live.Admin.ModuleConfigComponent do
  @moduledoc """
  Generic Module Configuration admin screen (Module Configuration Framework,
  2026-07-08). One catalog-driven form for every module's `ConfigCatalog` — adding a
  new module's config keys never requires new UI code here, only a new
  `<module>/config_catalog.ex` registered in `VmuCore.Shared.ModuleConfigCatalog.all/0`.

  v1 permission model: gated by `system:edit` (same coarse ADMIN-only gate as the
  System Parameters screen) rather than per-target-module RBAC rows — see
  `docs/shared/Module_Configuration_Framework.md` "Out of scope".
  """
  use Phoenix.LiveComponent

  import Ecto.Query, warn: false
  import VmuCoreWeb.AdminUI

  alias VmuCore.Repo
  alias VmuCore.Shared.{SysParameter, BankParameter, LogoParameter}
  alias VmuCore.Shared.{ModuleConfigEngine, ModuleConfigWriter, ModuleConfigCatalog}
  alias VmuCore.ASM.Authz

  @modules ~w[cta asm dps]

  # ── Mount / Update ──────────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       current_operator: nil,
       can_edit: false,
       edit_mode: false,
       result: nil,
       active_module: "cta",
       scope_type: "system",
       bank_id: "",
       logo_id: "",
       form_data: %{}
     )
     |> load_sys()
     |> load_banks()
     |> load_logos()
     |> load_values()}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(can_edit: Authz.can?(assigns[:current_operator], "system", "edit"))}
  end

  defp load_sys(socket) do
    assign(socket, sys: Repo.all(SysParameter) |> List.first())
  end

  defp load_banks(socket) do
    sys_id = socket.assigns.sys && socket.assigns.sys.sys_id
    banks = if sys_id, do: Repo.all(from b in BankParameter, where: b.sys_id == ^sys_id), else: []
    assign(socket, banks: banks)
  end

  defp load_logos(socket) do
    bank_id = socket.assigns[:bank_id] || ""
    sys_id = socket.assigns.sys && socket.assigns.sys.sys_id

    logos =
      if sys_id != nil and bank_id != "" do
        Repo.all(from l in LogoParameter, where: l.sys_id == ^sys_id and l.bank_id == ^bank_id)
      else
        []
      end

    assign(socket, logos: logos)
  end

  defp load_values(socket) do
    sys_id = socket.assigns.sys && socket.assigns.sys.sys_id
    bank_id = socket.assigns[:bank_id] || ""
    logo_id = socket.assigns[:logo_id] || ""
    module = socket.assigns.active_module

    values =
      if sys_id do
        ModuleConfigCatalog.for_module(module)
        |> Map.new(fn spec ->
          {:ok, value} = ModuleConfigEngine.get(module, spec.key, sys_id, bank_id, logo_id)
          {spec.key, value}
        end)
      else
        %{}
      end

    assign(socket, values: values)
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("cfg_module", %{"module" => module}, socket) when module in @modules do
    {:noreply,
     socket
     |> assign(active_module: module, edit_mode: false, result: nil)
     |> load_values()}
  end

  def handle_event("cfg_scope_change", params, socket) do
    scope_type = params["scope_type"] || socket.assigns.scope_type
    bank_id = if scope_type == "system", do: "", else: params["bank_id"] || ""
    logo_id = if scope_type == "logo", do: params["logo_id"] || "", else: ""

    {:noreply,
     socket
     |> assign(scope_type: scope_type, bank_id: bank_id, logo_id: logo_id, edit_mode: false, result: nil)
     |> load_logos()
     |> load_values()}
  end

  def handle_event("cfg_edit", _params, socket) do
    if socket.assigns.can_edit do
      form_data =
        Map.new(socket.assigns.values, fn {key, value} -> {key, to_form_value(value)} end)

      {:noreply, assign(socket, edit_mode: true, form_data: form_data, result: nil)}
    else
      {:noreply, assign(socket, result: {:error, "Your role cannot edit module configuration."})}
    end
  end

  def handle_event("cfg_cancel", _params, socket) do
    {:noreply, assign(socket, edit_mode: false, result: nil)}
  end

  def handle_event("cfg_change", %{"cfg" => params}, socket) do
    {:noreply, assign(socket, form_data: Map.merge(socket.assigns.form_data, params))}
  end

  def handle_event("cfg_save", %{"cfg" => params}, socket) do
    cond do
      not socket.assigns.can_edit ->
        {:noreply, assign(socket, result: {:error, "Your role cannot edit module configuration."})}

      is_nil(socket.assigns.sys) ->
        {:noreply, assign(socket, result: {:error, "No SYS record found."})}

      socket.assigns.scope_type in ["bank", "logo"] and socket.assigns.bank_id == "" ->
        {:noreply, assign(socket, result: {:error, "Select a bank/organization for this scope."})}

      socket.assigns.scope_type == "logo" and socket.assigns.logo_id == "" ->
        {:noreply, assign(socket, result: {:error, "Select a logo/product for this scope."})}

      true ->
        save_all(socket, params)
    end
  end

  defp save_all(socket, params) do
    module = socket.assigns.active_module
    scope = %{
      scope_type: socket.assigns.scope_type,
      sys_id: socket.assigns.sys.sys_id,
      bank_id: socket.assigns.bank_id,
      logo_id: socket.assigns.logo_id
    }

    results =
      ModuleConfigCatalog.for_module(module)
      |> Enum.map(fn spec ->
        raw = Map.get(params, spec.key, "")
        with {:ok, parsed} <- parse_form_value(spec, raw) do
          if parsed == socket.assigns.values[spec.key] do
            {:ok, :unchanged}
          else
            ModuleConfigWriter.put(module, spec.key, parsed, scope, socket.assigns.current_operator)
          end
        end
      end)

    errors =
      results
      |> Enum.zip(ModuleConfigCatalog.for_module(module))
      |> Enum.filter(fn {r, _spec} -> match?({:error, _}, r) end)
      |> Enum.map(fn {{:error, reason}, spec} -> "#{spec.key}: #{inspect(reason)}" end)

    socket = socket |> load_values() |> assign(edit_mode: false)

    if errors == [] do
      {:noreply, assign(socket, result: {:ok, "Configuration saved."})}
    else
      {:noreply, assign(socket, result: {:error, "Save failed — " <> Enum.join(errors, "; ")})}
    end
  end

  # ── Value <-> form conversion ────────────────────────────────────────────────

  defp to_form_value(v) when is_list(v), do: v
  defp to_form_value(v) when is_map(v), do: Jason.encode!(v, pretty: true)
  defp to_form_value(v), do: to_string(v)

  defp parse_form_value(%{type: :string}, raw), do: {:ok, to_string(raw)}
  defp parse_form_value(%{type: :enum}, raw), do: {:ok, to_string(raw)}
  defp parse_form_value(%{type: :boolean}, raw), do: {:ok, raw in ["true", true]}

  defp parse_form_value(%{type: :integer}, raw) do
    case Integer.parse(to_string(raw)) do
      {n, _} -> {:ok, n}
      :error -> {:error, :invalid_value}
    end
  end

  defp parse_form_value(%{type: :list, allowed: allowed}, raw) when is_list(raw) do
    {:ok, Enum.filter(raw, &(&1 in (allowed || raw)))}
  end

  defp parse_form_value(%{type: :list}, raw) do
    {:ok, to_string(raw) |> String.split(",", trim: true) |> Enum.map(&String.trim/1)}
  end

  defp parse_form_value(%{type: :map}, raw) do
    case Jason.decode(to_string(raw)) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_value}
    end
  end

  # ── Render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_header title="Module Configuration" subtitle="Per-module operational settings — configurable by customer, market, or product (CTA/ASM/DPS and beyond)">
        <:actions>
          <button :if={!@edit_mode && @can_edit}
            phx-click="cfg_edit" phx-target={@myself} class="btn btn-secondary">
            ✏️ Edit
          </button>
        </:actions>
      </.page_header>

      <%= if @result do %>
        <% {kind, msg} = @result %>
        <.alert kind={kind} message={msg} />
      <% end %>

      <%= if @sys == nil do %>
        <.empty_state icon="🧰" title="No System Record Found"
          message="Create a SYS record via the database seeds or IEx console first." />
      <% else %>
        <div class="card" style="margin-bottom:16px;">
          <div class="card-body" style="display:flex;gap:24px;align-items:flex-end;flex-wrap:wrap;">
            <div class="field">
              <label>Module</label>
              <div style="display:flex;gap:8px;">
                <button :for={m <- ~w[cta asm dps]} type="button"
                  phx-click="cfg_module" phx-value-module={m} phx-target={@myself}
                  class={"btn #{if @active_module == m, do: "btn-primary", else: "btn-secondary"}"}>
                  <%= String.upcase(m) %>
                </button>
              </div>
            </div>

            <form phx-change="cfg_scope_change" phx-target={@myself} style="display:flex;gap:16px;align-items:flex-end;">
              <div class="field">
                <label>Scope</label>
                <select name="scope_type">
                  <option value="system" selected={@scope_type == "system"}>System (global)</option>
                  <option value="bank" selected={@scope_type == "bank"}>Bank / Organization</option>
                  <option value="logo" selected={@scope_type == "logo"}>Logo / Product</option>
                </select>
              </div>
              <div :if={@scope_type in ["bank", "logo"]} class="field">
                <label>Bank</label>
                <select name="bank_id">
                  <option value="">-- Select --</option>
                  <option :for={b <- @banks} value={b.bank_id} selected={@bank_id == b.bank_id}>
                    <%= b.bank_id %> — <%= b.description %>
                  </option>
                </select>
              </div>
              <div :if={@scope_type == "logo"} class="field">
                <label>Logo</label>
                <select name="logo_id">
                  <option value="">-- Select --</option>
                  <option :for={l <- @logos} value={l.logo_id} selected={@logo_id == l.logo_id}>
                    <%= l.logo_id %> — <%= l.description %>
                  </option>
                </select>
              </div>
            </form>
          </div>
        </div>

        <%= if @edit_mode do %>
          <.render_edit myself={@myself} form_data={@form_data} specs={ModuleConfigCatalog.for_module(@active_module)} />
        <% else %>
          <.render_view values={@values} specs={ModuleConfigCatalog.for_module(@active_module)} />
        <% end %>
      <% end %>
    </div>
    """
  end

  defp render_view(assigns) do
    ~H"""
    <div class="card">
      <div class="card-header"><div class="card-title"><%= String.upcase(hd(@specs).module) %> Configuration Keys</div></div>
      <div class="card-body">
        <.kv_detail rows={Enum.map(@specs, fn spec ->
          {"#{spec.key} (#{spec.scope})", format_value(Map.get(@values, spec.key))}
        end)} />
        <div style="margin-top:16px;display:flex;flex-direction:column;gap:6px;">
          <div :for={spec <- @specs} class="hint">
            <strong><%= spec.key %></strong> — <%= spec.description %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_value(v) when is_map(v), do: Jason.encode!(v)
  defp format_value(v) when is_list(v), do: Enum.join(v, ", ")
  defp format_value(v), do: to_string(v)

  defp render_edit(assigns) do
    ~H"""
    <form phx-change="cfg_change" phx-submit="cfg_save" phx-target={@myself}>
      <div class="card">
        <div class="card-header">
          <div class="card-title">Edit <%= String.upcase(hd(@specs).module) %> Configuration</div>
          <div class="card-subtitle">Values apply at the scope selected above; unset keys fall back down the chain to the catalog default.</div>
        </div>
        <div class="card-body">
          <div :for={spec <- @specs} class="form-section">
            <div class="form-section-title"><%= spec.key %></div>
            <p class="hint"><%= spec.description %></p>

            <%= case spec.type do %>
              <% :boolean -> %>
                <div class="checkbox-row">
                  <input type="checkbox" id={"cfg-#{spec.key}"} name={"cfg[#{spec.key}]"} value="true"
                    checked={@form_data[spec.key] in ["true", true]}/>
                  <label for={"cfg-#{spec.key}"}>Enabled</label>
                </div>
              <% :enum -> %>
                <select name={"cfg[#{spec.key}]"}>
                  <option :for={opt <- spec.allowed} value={opt} selected={@form_data[spec.key] == opt}><%= opt %></option>
                </select>
              <% :integer -> %>
                <input type="number" name={"cfg[#{spec.key}]"} value={@form_data[spec.key]}/>
              <% :list -> %>
                <%= if spec.allowed do %>
                  <div style="display:flex;gap:12px;flex-wrap:wrap;">
                    <label :for={opt <- spec.allowed} class="checkbox-row">
                      <input type="checkbox" name={"cfg[#{spec.key}][]"} value={opt}
                        checked={opt in (@form_data[spec.key] || [])}/>
                      <%= opt %>
                    </label>
                  </div>
                <% else %>
                  <input type="text" name={"cfg[#{spec.key}]"} value={@form_data[spec.key]}
                    placeholder="comma-separated"/>
                <% end %>
              <% :map -> %>
                <textarea name={"cfg[#{spec.key}]"} rows="4" class="font-mono"
                  style="width:100%;"><%= @form_data[spec.key] %></textarea>
              <% _ -> %>
                <input type="text" name={"cfg[#{spec.key}]"} value={@form_data[spec.key]}/>
            <% end %>
          </div>
        </div>
        <div class="card-footer">
          <button type="button" phx-click="cfg_cancel" phx-target={@myself} class="btn btn-secondary">
            Cancel
          </button>
          <button type="submit" class="btn btn-primary">
            💾 Save Configuration
          </button>
        </div>
      </div>
    </form>
    """
  end
end
