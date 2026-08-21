defmodule VmuCoreWeb.Components.Drawer do
  @moduledoc """
  `<.detail_drawer>` — the right-side slide-over every View/Detail action
  opens into. Sibling to `VmuCoreWeb.Components.AgGrid`; see
  `docs/shared/Admin_Detail_UX_Philosophy.md` §2 for the reasoning.

  It replaces two older patterns, both of which made the operator lose
  their place in the list they were working:

    * the same-page mode swap (`@mode = :detail` replacing the whole list)
    * the in-page detail block (detail rendered above its own results table)

      <.detail_drawer
        id="customer-detail-drawer"
        open={@mode == :detail}
        title={full_name(@viewing)}
        subtitle={@viewing.customer_id}
        on_close="cust_back"
        target={@myself}
      >
        <%= render_detail_body(assigns) %>
      </.detail_drawer>

  ## Always mounted, toggled by class

  `open` adds `.is-open` rather than gating the markup with `:if`. A `:if`
  unmounts the node, which leaves the CSS transition nothing to animate
  from — the panel would snap rather than slide. Closed, the root is
  `visibility: hidden` so it is out of the tab order and un-clickable
  without `display: none` killing the transition.

  The consequence worth knowing: **the body and `title` render even while
  closed**, so both must tolerate the selected record being `nil` — which
  it is on most renders. Guard the body with `:if` and the title with
  `&&`:

      <.detail_drawer open={@detail != nil} title={@detail && @detail.id} ...>
        <div :if={@detail}>…</div>
      </.detail_drawer>

  ## Closing

  Backdrop click, the header's `×`, and Escape all push `on_close`. Escape
  is bound with `phx-window-keydown` only while open, so a closed drawer on
  a screen does not swallow Escape from anything else.

  ## Deep linking

  A drawer opened from a row should also be reachable by URL, so an
  operator can share "the screen I am looking at". Pair the open event with
  `push_patch(socket, to: "/visionplus/admin/<mod>?view=<id>")`, which
  `AdminLive.handle_params/3` already threads back in as `deep_link_id` —
  the same mechanism the Koṣa cross-product "View in X" links use.
  """

  use Phoenix.Component

  attr :id, :string, required: true
  attr :open, :boolean, default: false
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :on_close, :string, required: true, doc: "event pushed by backdrop, × and Escape"
  attr :target, :any, default: nil, doc: "@myself when the handler lives in a LiveComponent"
  attr :width, :string, default: nil, doc: "CSS length overriding --drawer-width for this drawer only"
  attr :rest, :global
  slot :inner_block, required: true
  slot :actions, doc: "optional buttons rendered in the header, left of the × "

  def detail_drawer(assigns) do
    ~H"""
    <div
      id={@id}
      class={["drawer-root", @open && "is-open"]}
      style={@width && "--drawer-width: #{@width};"}
      role="dialog"
      aria-modal="true"
      aria-hidden={to_string(!@open)}
      aria-label={@title}
      phx-window-keydown={@open && @on_close}
      phx-key="Escape"
      phx-target={@target}
      {@rest}
    >
      <div class="drawer-backdrop" phx-click={@on_close} phx-target={@target} aria-hidden="true"></div>

      <div class="drawer-panel">
        <div class="drawer-header">
          <div style="min-width:0;">
            <h2 class="drawer-title"><%= @title %></h2>
            <div :if={@subtitle} class="drawer-subtitle"><%= @subtitle %></div>
          </div>

          <div class="actions">
            <%= render_slot(@actions) %>
            <button
              type="button"
              class="btn btn-sm btn-ghost"
              phx-click={@on_close}
              phx-target={@target}
              aria-label="Close"
            >✕</button>
          </div>
        </div>

        <div class="drawer-body">
          <%= render_slot(@inner_block) %>
        </div>
      </div>
    </div>
    """
  end
end
