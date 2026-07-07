defmodule VmuCoreWeb.AdminUI do
  @moduledoc """
  Shared function components for the VisionPlus admin UI.
  Import this module in any LiveView or LiveComponent that renders admin pages.
  """
  use Phoenix.Component

  # ── Page header ────────────────────────────────────────────────────────────

  attr :title,    :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class="page-header">
      <div>
        <h1><%= @title %></h1>
        <p :if={@subtitle} class="subtitle"><%= @subtitle %></p>
      </div>
      <div class="page-header-actions"><%= render_slot(@actions) %></div>
    </div>
    """
  end

  # ── Alert / result message ─────────────────────────────────────────────────

  attr :kind,    :atom,   default: :info
  attr :message, :string, required: true
  attr :rest,    :global

  def alert(assigns) do
    {icon, cls} = case assigns.kind do
      :success -> {"✓", "alert-success"}
      :error   -> {"✕", "alert-error"}
      :warning -> {"⚠", "alert-warning"}
      _        -> {"ℹ", "alert-info"}
    end
    assigns = assign(assigns, icon: icon, cls: cls)
    ~H"""
    <div class={"alert #{@cls}"} {@rest}>
      <span class="icon"><%= @icon %></span>
      <span><%= @message %></span>
    </div>
    """
  end

  # ── Status badge ────────────────────────────────────────────────────────────

  attr :status, :string, required: true

  def status_badge(assigns) do
    cls = case String.upcase(assigns.status || "") do
      s when s in ~w(ACTIVE ENABLED TRUE OK) -> "badge-green"
      s when s in ~w(INACTIVE DISABLED FALSE) -> "badge-red"
      s when s in ~w(PENDING DRAFT)           -> "badge-yellow"
      _                                        -> "badge-gray"
    end
    assigns = assign(assigns, cls: cls)
    ~H"""
    <span class={"badge #{@cls}"}><%= @status %></span>
    """
  end

  # ── Empty state ─────────────────────────────────────────────────────────────

  attr :icon,    :string, default: "📋"
  attr :title,   :string, required: true
  attr :message, :string, default: nil
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div class="empty-state">
      <div class="empty-icon"><%= @icon %></div>
      <h3><%= @title %></h3>
      <p :if={@message}><%= @message %></p>
      <div class="mt-4"><%= render_slot(@actions) %></div>
    </div>
    """
  end

  # ── Form card wrapper ────────────────────────────────────────────────────────

  attr :title,    :string, required: true
  attr :subtitle, :string, default: nil
  slot :header_actions
  slot :inner_block, required: true
  slot :footer

  def form_card(assigns) do
    ~H"""
    <div class="card">
      <div class="card-header">
        <div>
          <div class="card-title"><%= @title %></div>
          <div :if={@subtitle} class="card-subtitle"><%= @subtitle %></div>
        </div>
        <div><%= render_slot(@header_actions) %></div>
      </div>
      <div class="card-body"><%= render_slot(@inner_block) %></div>
      <div :if={@footer != []} class="card-footer"><%= render_slot(@footer) %></div>
    </div>
    """
  end

  # ── Field wrapper ─────────────────────────────────────────────────────────

  attr :label,  :string, required: true
  attr :hint,   :string, default: nil
  attr :error,  :string, default: nil
  slot :inner_block, required: true

  def field(assigns) do
    ~H"""
    <div class="field">
      <label><%= @label %></label>
      <p :if={@hint} class="hint"><%= @hint %></p>
      <%= render_slot(@inner_block) %>
      <span :if={@error} class="field-error"><%= @error %></span>
    </div>
    """
  end

  # ── Section heading inside a form ─────────────────────────────────────────

  attr :title, :string, required: true

  def form_section(assigns) do
    ~H"""
    <div class="form-section">
      <div class="form-section-title"><%= @title %></div>
    </div>
    """
  end

  # ── Key/value detail display ──────────────────────────────────────────────

  attr :rows, :list, required: true

  def kv_detail(assigns) do
    ~H"""
    <div class="kv-list">
      <%= for {key, val} <- @rows do %>
        <div class="kv-row">
          <div class="kv-key"><%= key %></div>
          <div class="kv-val"><%= val || "—" %></div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Step navigation bar ───────────────────────────────────────────────────

  attr :steps,        :list,    required: true
  attr :current_step, :integer, required: true

  def step_nav(assigns) do
    ~H"""
    <div class="steps-nav">
      <%= for {label, idx} <- Enum.with_index(@steps, 1) do %>
        <% status = cond do
          idx == @current_step -> "active"
          idx < @current_step  -> "done"
          true -> ""
        end %>
        <div class={"step-tab #{status}"}>
          <span class="step-num"><%= if idx < @current_step, do: "✓", else: idx %></span>
          <%= label %>
        </div>
      <% end %>
    </div>
    """
  end
end
