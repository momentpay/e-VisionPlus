defmodule VmuCoreWeb.Live.Admin.SystemComponent do
  @moduledoc """
  SYS parameter view/edit LiveComponent.

  The SYS record is the root of the VisionPlus parameter hierarchy.
  There is typically one SYS record per processor instance.
  All sub-levels (BANK → LOGO → BLOCK) inherit from SYS unless overridden.
  """
  use Phoenix.LiveComponent

  import Ecto.Query, warn: false
  import VmuCoreWeb.AdminUI

  alias VmuCore.{Repo}
  alias VmuCore.Shared.{SysParameter, ParameterWriter}
  alias VmuCore.ASM.Authz

  @currencies [
    {"AED — UAE Dirham", "AED"}, {"SAR — Saudi Riyal", "SAR"}, {"BHD — Bahraini Dinar", "BHD"},
    {"KWD — Kuwaiti Dinar", "KWD"}, {"QAR — Qatari Riyal", "QAR"}, {"OMR — Omani Rial", "OMR"},
    {"EGP — Egyptian Pound", "EGP"}, {"JOD — Jordanian Dinar", "JOD"}, {"PKR — Pakistani Rupee", "PKR"},
    {"INR — Indian Rupee", "INR"}, {"USD — US Dollar", "USD"}, {"EUR — Euro", "EUR"},
    {"GBP — British Pound", "GBP"}, {"SGD — Singapore Dollar", "SGD"}, {"MYR — Malaysian Ringgit", "MYR"}
  ]

  # ── Mount / Update ──────────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok, socket |> assign(mode: :view, result: nil, currencies: @currencies,
                           current_operator: nil, can_edit: false) |> load_sys()}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(can_edit: Authz.can?(assigns[:current_operator], "system", "edit"))}
  end

  defp load_sys(socket) do
    sys = Repo.all(SysParameter) |> List.first()
    fd  = if sys, do: sys_to_form(sys), else: %{}
    assign(socket, sys: sys, form_data: fd)
  end

  defp sys_to_form(%SysParameter{} = s) do
    bc = s.batch_controls     || %{}
    cc = s.cycle_controls     || %{}
    pr = s.posting_rules      || %{}
    %{
      "sys_id"              => s.sys_id,
      "description"         => s.description,
      "base_currency"       => s.base_currency,
      "eod_window_start"    => bc["eod_window_start"]    || "22:00",
      "eod_window_end"      => bc["eod_window_end"]      || "04:00",
      "max_job_retries"     => to_string(bc["max_job_retries"]    || 3),
      "lock_timeout_sec"    => to_string(bc["lock_timeout_sec"]   || 120),
      "default_cycle_day"   => to_string(cc["default_cycle_day"]  || 1),
      "cycle_length_days"   => to_string(cc["cycle_length_days"]  || 30),
      "grace_days_default"  => to_string(cc["grace_days_default"] || 25),
      "posting_cutoff_time" => pr["posting_cutoff_time"] || "23:59",
      "max_backdate_days"   => to_string(pr["max_backdate_days"]  || 3),
      "same_day_value"      => to_string(pr["same_day_value"] || false),
      "global_status_codes" => Enum.join(s.global_status_codes || [], ", ")
    }
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("sys_edit", _params, socket) do
    if socket.assigns.can_edit do
      {:noreply, assign(socket, mode: :edit, result: nil)}
    else
      {:noreply, assign(socket, result: {:error, "Your role cannot edit system parameters."})}
    end
  end

  def handle_event("sys_cancel", _params, socket) do
    {:noreply, socket |> assign(mode: :view, result: nil) |> load_sys()}
  end

  def handle_event("sys_change", %{"sys" => params}, socket) do
    {:noreply, assign(socket, form_data: params)}
  end

  def handle_event("sys_save", %{"sys" => params}, socket) do
    cond do
      not socket.assigns.can_edit ->
        {:noreply, assign(socket, result: {:error, "Your role cannot edit system parameters."})}

      is_nil(socket.assigns.sys) ->
        {:noreply, assign(socket, result: {:error, "No SYS record found. Create one via seeds."})}

      true ->
        sys = socket.assigns.sys
        attrs = build_sys_attrs(params)
        case ParameterWriter.update_sys(sys, attrs) do
          {:ok, _updated} ->
            {:noreply, socket |> load_sys() |> assign(mode: :view, result: {:ok, "System parameters saved."})}

          {:error, changeset} ->
            msg = Enum.map_join(changeset.errors, "; ", fn {f, {m, _}} -> "#{f}: #{m}" end)
            {:noreply, assign(socket, result: {:error, "Save failed — #{msg}"})}
        end
    end
  end

  defp build_sys_attrs(p) do
    %{
      description:   p["description"],
      base_currency: p["base_currency"],
      batch_controls: %{
        "eod_window_start" => p["eod_window_start"],
        "eod_window_end"   => p["eod_window_end"],
        "max_job_retries"  => int_val(p["max_job_retries"], 3),
        "lock_timeout_sec" => int_val(p["lock_timeout_sec"], 120)
      },
      cycle_controls: %{
        "default_cycle_day"   => int_val(p["default_cycle_day"], 1),
        "cycle_length_days"   => int_val(p["cycle_length_days"], 30),
        "grace_days_default"  => int_val(p["grace_days_default"], 25)
      },
      posting_rules: %{
        "posting_cutoff_time" => p["posting_cutoff_time"],
        "max_backdate_days"   => int_val(p["max_backdate_days"], 3),
        "same_day_value"      => p["same_day_value"] == "true"
      },
      global_status_codes:
        p["global_status_codes"]
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    }
  end

  defp int_val(str, default) do
    case Integer.parse(to_string(str)) do
      {n, _} -> n
      _      -> default
    end
  end

  # ── Render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_header title="System Parameters" subtitle="Global processor-level defaults (root of the parameter hierarchy)">
        <:actions>
          <button :if={@mode == :view && @sys != nil && @can_edit}
            phx-click="sys_edit" phx-target={@myself} class="btn btn-secondary">
            ✏️ Edit
          </button>
        </:actions>
      </.page_header>

      <%= if @result do %>
        <% {kind, msg} = @result %>
        <.alert kind={kind} message={msg} />
      <% end %>

      <%= if @sys == nil do %>
        <.empty_state icon="⚙️" title="No System Record Found"
          message="Create a SYS record via the database seeds or IEx console first.">
          <:actions>
            <code>mix run priv/repo/seeds.exs</code>
          </:actions>
        </.empty_state>
      <% else %>
        <%= if @mode == :view do %>
          <.render_view sys={@sys} />
        <% else %>
          <.render_edit myself={@myself} form_data={@form_data} currencies={@currencies} />
        <% end %>
      <% end %>
    </div>
    """
  end

  # ── View mode ───────────────────────────────────────────────────────────────

  defp render_view(assigns) do
    bc = assigns.sys.batch_controls    || %{}
    cc = assigns.sys.cycle_controls    || %{}
    pr = assigns.sys.posting_rules     || %{}
    assigns = assign(assigns, bc: bc, cc: cc, pr: pr)
    ~H"""
    <div class="stat-grid">
      <div class="stat-card">
        <div class="stat-label">SYS ID</div>
        <div class="stat-value font-mono"><%= @sys.sys_id %></div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Base Currency</div>
        <div class="stat-value"><%= @sys.base_currency %></div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Cycle Length</div>
        <div class="stat-value"><%= @cc["cycle_length_days"] || 30 %> days</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Grace Days</div>
        <div class="stat-value"><%= @cc["grace_days_default"] || 25 %> days</div>
      </div>
    </div>

    <div style="display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-top:4px;">

      <div class="card">
        <div class="card-header"><div class="card-title">Identity</div></div>
        <div class="card-body">
          <.kv_detail rows={[
            {"SYS ID",       @sys.sys_id},
            {"Description",  @sys.description},
            {"Base Currency",@sys.base_currency}
          ]} />
        </div>
      </div>

      <div class="card">
        <div class="card-header"><div class="card-title">Batch Controls</div></div>
        <div class="card-body">
          <.kv_detail rows={[
            {"EOD Window Start",  @bc["eod_window_start"] || "22:00"},
            {"EOD Window End",    @bc["eod_window_end"]   || "04:00"},
            {"Max Job Retries",   @bc["max_job_retries"]  || 3},
            {"Lock Timeout (sec)",@bc["lock_timeout_sec"] || 120}
          ]} />
        </div>
      </div>

      <div class="card">
        <div class="card-header"><div class="card-title">Cycle Controls</div></div>
        <div class="card-body">
          <.kv_detail rows={[
            {"Default Cycle Day",  @cc["default_cycle_day"]  || 1},
            {"Cycle Length (days)",@cc["cycle_length_days"]  || 30},
            {"Grace Days Default", @cc["grace_days_default"] || 25}
          ]} />
        </div>
      </div>

      <div class="card">
        <div class="card-header"><div class="card-title">Posting Rules</div></div>
        <div class="card-body">
          <.kv_detail rows={[
            {"Posting Cutoff Time",    @pr["posting_cutoff_time"] || "23:59"},
            {"Max Backdate Days",      @pr["max_backdate_days"]   || 3},
            {"Same-Day Value Dating",  inspect(@pr["same_day_value"] || false)}
          ]} />
        </div>
      </div>

    </div>

    <%= if @sys.global_status_codes && @sys.global_status_codes != [] do %>
      <div class="card mt-4">
        <div class="card-header"><div class="card-title">Global Status Codes</div></div>
        <div class="card-body" style="display:flex;gap:8px;flex-wrap:wrap;">
          <%= for code <- @sys.global_status_codes do %>
            <span class="badge badge-gray font-mono"><%= code %></span>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  # ── Edit mode ───────────────────────────────────────────────────────────────

  defp render_edit(assigns) do
    ~H"""
    <form phx-change="sys_change" phx-submit="sys_save" phx-target={@myself}>
      <div class="card">
        <div class="card-header">
          <div class="card-title">Edit System Parameters</div>
          <div class="card-subtitle">Changes affect all organisations and logos that inherit from SYS.</div>
        </div>
        <div class="card-body">

          <!-- Identity -->
          <div class="form-grid">
            <div class="field">
              <label>SYS ID</label>
              <input type="text" name="sys[sys_id]" value={@form_data["sys_id"]} disabled/>
              <p class="hint">Cannot be changed after creation.</p>
            </div>
            <div class="field">
              <label>Description</label>
              <input type="text" name="sys[description]" value={@form_data["description"]} placeholder="e.g. Main Processor"/>
            </div>
            <div class="field">
              <label>Base Currency</label>
              <select name="sys[base_currency]">
                <%= for {label, code} <- @currencies do %>
                  <option value={code} selected={@form_data["base_currency"] == code}><%= label %></option>
                <% end %>
              </select>
            </div>
          </div>

          <!-- Batch Controls -->
          <div class="form-section">
            <div class="form-section-title">Batch Controls — EOD Job Window</div>
            <div class="form-grid">
              <div class="field">
                <label>EOD Window Start</label>
                <input type="time" name="sys[eod_window_start]" value={@form_data["eod_window_start"]}/>
                <p class="hint">When the nightly batch job window opens.</p>
              </div>
              <div class="field">
                <label>EOD Window End</label>
                <input type="time" name="sys[eod_window_end]" value={@form_data["eod_window_end"]}/>
                <p class="hint">When the window closes (may be next-day time).</p>
              </div>
              <div class="field">
                <label>Max Job Retries</label>
                <input type="number" name="sys[max_job_retries]" value={@form_data["max_job_retries"]} min="1" max="10"/>
              </div>
              <div class="field">
                <label>Lock Timeout (seconds)</label>
                <input type="number" name="sys[lock_timeout_sec]" value={@form_data["lock_timeout_sec"]} min="30" max="600"/>
              </div>
            </div>
          </div>

          <!-- Cycle Controls -->
          <div class="form-section">
            <div class="form-section-title">Cycle Controls — Billing Cycle Defaults</div>
            <div class="form-grid">
              <div class="field">
                <label>Default Cycle Day</label>
                <input type="number" name="sys[default_cycle_day]" value={@form_data["default_cycle_day"]} min="1" max="31"/>
                <p class="hint">Day of month for default billing cycle cut.</p>
              </div>
              <div class="field">
                <label>Cycle Length (days)</label>
                <input type="number" name="sys[cycle_length_days]" value={@form_data["cycle_length_days"]} min="28" max="31"/>
              </div>
              <div class="field">
                <label>Grace Days Default</label>
                <input type="number" name="sys[grace_days_default]" value={@form_data["grace_days_default"]} min="0" max="60"/>
                <p class="hint">Days after statement before interest accrues.</p>
              </div>
            </div>
          </div>

          <!-- Posting Rules -->
          <div class="form-section">
            <div class="form-section-title">Posting Rules — Transaction Dating</div>
            <div class="form-grid">
              <div class="field">
                <label>Posting Cutoff Time</label>
                <input type="time" name="sys[posting_cutoff_time]" value={@form_data["posting_cutoff_time"]}/>
                <p class="hint">Transactions after this time post to next business day.</p>
              </div>
              <div class="field">
                <label>Max Backdate Days</label>
                <input type="number" name="sys[max_backdate_days]" value={@form_data["max_backdate_days"]} min="0" max="30"/>
                <p class="hint">Maximum days a transaction can be backdated.</p>
              </div>
              <div class="checkbox-row">
                <input type="checkbox" id="sdv" name="sys[same_day_value]" value="true"
                  checked={@form_data["same_day_value"] == "true"}/>
                <label for="sdv">Same-Day Value Dating
                  <span class="sublabel">Transactions posted today receive today's value date.</span>
                </label>
              </div>
            </div>
          </div>

          <!-- Global Status Codes -->
          <div class="form-section">
            <div class="form-section-title">Global Status Codes</div>
            <div class="field">
              <label>Valid Account Status Codes</label>
              <input type="text" name="sys[global_status_codes]"
                value={@form_data["global_status_codes"]}
                placeholder="ACTIVE, INACTIVE, SUSPENDED, CLOSED, DELINQUENT"/>
              <p class="hint">Comma-separated list of valid account_status values for this processor.</p>
            </div>
          </div>

        </div>
        <div class="card-footer">
          <button type="button" phx-click="sys_cancel" phx-target={@myself} class="btn btn-secondary">
            Cancel
          </button>
          <button type="submit" class="btn btn-primary">
            💾 Save System Parameters
          </button>
        </div>
      </div>
    </form>
    """
  end
end
