defmodule VmuCoreWeb.Live.Admin.GlComponent do
  @moduledoc """
  General Ledger admin surface (GL Phase A4/4A).

  Four tabs, each backed by real data rather than a placeholder:

    * **Chart of Accounts** — the 30-account registry, with the conflict
      worklist surfaced rather than buried
    * **Posting Rules** — `{event_type, product}` → account pair, and which
      rules still await cutover
    * **Periods** — banking date and accounting periods per institution, with
      close / reopen / lock
    * **Exceptions** — postings quarantined for landing outside an open
      period. Empty is the healthy state

  Read-mostly by design. Period close and lock are the only mutations, and
  lock is deliberately irreversible — that is what makes a closed period's
  reported figures defensible.
  """
  use Phoenix.LiveComponent


  alias VmuCore.GL.{ChartOfAccounts, Period, Periods}
  alias VmuCore.Posting.Rules

  @tabs ~w[accounts trial_balance ledger journal rules periods exceptions shadow]

  @impl true
  def mount(socket) do
    {:ok, assign(socket, tab: "accounts", institution: nil, flash_msg: nil, embedded: false)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:embedded, fn -> false end)
     |> load_data()}
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) when tab in @tabs do
    {:noreply, socket |> assign(tab: tab, flash_msg: nil) |> load_data()}
  end

  def handle_event("select_institution", %{"institution" => inst}, socket) do
    {:noreply, socket |> assign(institution: inst) |> load_data()}
  end

  def handle_event("close_period", %{"id" => id}, socket) do
    operator = operator_name(socket)

    case Periods.close_period(get_period(id), operator) do
      {:ok, _} -> {:noreply, socket |> assign(flash_msg: "Period closed.") |> load_data()}
      {:error, _} -> {:noreply, assign(socket, flash_msg: "Could not close period.")}
    end
  end

  def handle_event("reopen_period", %{"id" => id}, socket) do
    case Periods.reopen_period(get_period(id)) do
      {:ok, _} ->
        {:noreply, socket |> assign(flash_msg: "Period reopened.") |> load_data()}

      {:error, :locked} ->
        {:noreply,
         assign(socket, flash_msg: "This period is LOCKED and can never be reopened.")}

      {:error, _} ->
        {:noreply, assign(socket, flash_msg: "Could not reopen period.")}
    end
  end

  def handle_event("lock_period", %{"id" => id}, socket) do
    case Periods.lock_period(get_period(id)) do
      {:ok, _} ->
        {:noreply, socket |> assign(flash_msg: "Period locked permanently.") |> load_data()}

      {:error, :not_closed} ->
        {:noreply, assign(socket, flash_msg: "Only a CLOSED period can be locked.")}

      {:error, _} ->
        {:noreply, assign(socket, flash_msg: "Could not lock period.")}
    end
  end

  # ---------------------------------------------------------------------------

  defp get_period(id), do: VmuCore.Repo.get!(Period, id)

  defp operator_name(socket) do
    case socket.assigns[:current_operator] do
      %{email: email} -> email
      %{username: u} -> u
      _ -> "admin"
    end
  end

  defp load_data(socket) do
    institutions = list_institutions()
    institution = socket.assigns[:institution] || List.first(institutions)

    socket
    |> assign(institutions: institutions, institution: institution)
    |> assign_tab_data(socket.assigns[:tab] || "accounts", institution)
  end

  defp assign_tab_data(socket, "accounts", _inst) do
    accounts = ChartOfAccounts.all(active: :all)

    assign(socket,
      accounts: accounts,
      account_conflicts: Enum.filter(accounts, & &1.legacy_conflict)
    )
  end

  defp assign_tab_data(socket, "trial_balance", nil), do: assign(socket, trial_rows: [], trial_totals: {0, 0})

  defp assign_tab_data(socket, "trial_balance", inst) do
    {sys_id, bank_id} = split(inst)
    rows = trial_balance(sys_id, bank_id)

    totals =
      Enum.reduce(rows, {Decimal.new(0), Decimal.new(0)}, fn r, {d, c} ->
        {Decimal.add(d, r.debits), Decimal.add(c, r.credits)}
      end)

    assign(socket, trial_rows: rows, trial_totals: totals)
  end

  defp assign_tab_data(socket, "ledger", nil), do: assign(socket, ledger_entries: [])

  defp assign_tab_data(socket, "ledger", inst) do
    {sys_id, bank_id} = split(inst)
    assign(socket, ledger_entries: list_ledger_entries(sys_id, bank_id))
  end

  defp assign_tab_data(socket, "journal", nil), do: assign(socket, journal_entries: [])

  defp assign_tab_data(socket, "journal", inst) do
    {sys_id, bank_id} = split(inst)
    assign(socket, journal_entries: list_journal_entries(sys_id, bank_id))
  end

  defp assign_tab_data(socket, "shadow", _inst) do
    # Compare only recent postings. Without a window, everything written
    # before shadow mode was switched on reports as missing and drowns the
    # findings that matter.
    since = Date.add(Date.utc_today(), -30)

    assign(socket,
      shadow_enabled: VmuCore.Posting.Shadow.enabled?(),
      shadow_summary: VmuCore.Posting.ShadowDiff.summary(since: since),
      shadow_rows: VmuCore.Posting.ShadowDiff.compare(since: since, limit: 100),
      shadow_since: since
    )
  end

  defp assign_tab_data(socket, "rules", _inst) do
    assign(socket, rules: Rules.all(), rules_pending: Rules.pending_cutover())
  end

  defp assign_tab_data(socket, "periods", nil), do: assign(socket, periods: [], banking_date: nil)

  defp assign_tab_data(socket, "periods", inst) do
    {sys_id, bank_id} = split(inst)

    assign(socket,
      banking_date: Periods.banking_date(sys_id, bank_id),
      periods: list_periods(sys_id, bank_id)
    )
  end

  defp assign_tab_data(socket, "exceptions", nil), do: assign(socket, exceptions: [])

  defp assign_tab_data(socket, "exceptions", inst) do
    {sys_id, bank_id} = split(inst)
    assign(socket, exceptions: Periods.open_exceptions(sys_id, bank_id))
  end

  defp split(inst), do: inst |> String.split("/") |> List.to_tuple()

  defp list_institutions do
    import Ecto.Query

    VmuCore.Repo.all(
      from(b in "gl_banking_dates",
        select: fragment("? || '/' || ?", b.sys_id, b.bank_id),
        order_by: [b.sys_id, b.bank_id]
      )
    )
  end

  # Turnover per account, from the posting legs — the WAY4 "GL Account Plan"
  # Total Debit / Total Credit view. Sourced from legs rather than the
  # consolidated ledger so it reflects everything posted, not only what has
  # been consolidated.
  defp trial_balance(sys_id, bank_id) do
    import Ecto.Query

    VmuCore.Repo.all(
      from(l in "posting_legs",
        join: e in "posting_entries", on: e.id == l.posting_entry_id,
        join: s in "posting_sets", on: s.id == e.posting_set_id,
        join: a in "gl_accounts", on: a.code == l.gl_account,
        where: s.sys_id == ^sys_id and s.bank_id == ^bank_id,
        group_by: [l.gl_account, a.name, a.account_class, a.normal_balance],
        order_by: l.gl_account,
        select: %{
          code: l.gl_account,
          name: a.name,
          account_class: a.account_class,
          normal_balance: a.normal_balance,
          debits: sum(fragment("CASE WHEN ? = 'debit' THEN ? ELSE 0 END", l.direction, l.amount)),
          credits: sum(fragment("CASE WHEN ? = 'credit' THEN ? ELSE 0 END", l.direction, l.amount))
        }
      )
    )
  end

  defp list_ledger_entries(sys_id, bank_id) do
    import Ecto.Query

    VmuCore.Repo.all(
      from(l in VmuCore.GL.LedgerEntry,
        where: l.sys_id == ^sys_id and l.bank_id == ^bank_id,
        order_by: [desc: l.gl_date, asc: l.dr_account, asc: l.generation],
        limit: 200
      )
    )
  end

  defp list_journal_entries(sys_id, bank_id) do
    import Ecto.Query

    VmuCore.Repo.all(
      from(j in VmuCore.Posting.JournalEntry,
        join: s in VmuCore.Posting.PostingSet, on: s.id == j.posting_set_id,
        where: s.sys_id == ^sys_id and s.bank_id == ^bank_id,
        order_by: [desc: j.posting_date, desc: j.inserted_at],
        limit: 200,
        select: %{
          account_ref: j.account_ref, product: j.product,
          dr: j.dr_gl_account, cr: j.cr_gl_account,
          amount: j.amount, currency: j.currency,
          transaction_date: j.transaction_date, posting_date: j.posting_date,
          gl_date: j.gl_date, narrative: j.narrative,
          event_type: s.event_type, idempotency_key: s.idempotency_key
        }
      )
    )
  end

  defp list_periods(sys_id, bank_id) do
    import Ecto.Query

    VmuCore.Repo.all(
      from(p in Period,
        where: p.sys_id == ^sys_id and p.bank_id == ^bank_id,
        order_by: [desc: p.period_start]
      )
    )
  end

  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="gl-admin">
      <h2 :if={!@embedded}>General Ledger</h2>

      <p :if={@flash_msg} class="flash"><%= @flash_msg %></p>

      <nav class="detail-tabs">
        <button :for={t <- ~w[accounts trial_balance ledger journal rules periods exceptions shadow]}
                class={["detail_tab", @tab == t && "active"]}
                phx-click="tab" phx-value-tab={t} phx-target={@myself}>
          <%= tab_label(t) %>
        </button>
      </nav>

      <%= case @tab do %>
        <% "accounts" -> %>
          <div :if={@account_conflicts != []} class="alert">
            <strong><%= length(@account_conflicts) %> account(s) still carry a posting conflict.</strong>
            Until this is empty the trial balance cannot be trusted at account level.
          </div>

          <table class="data-table">
            <thead>
              <tr><th>Code</th><th>Name</th><th>Class</th><th>Normal</th><th>Owner</th><th>Status</th></tr>
            </thead>
            <tbody>
              <tr :for={a <- @accounts} class={!a.active && "row-muted"}>
                <td><code><%= a.code %></code></td>
                <td>
                  <%= a.name %>
                  <div :if={a.legacy_conflict} class="cell-note conflict"><%= a.legacy_conflict %></div>
                </td>
                <td><%= a.account_class %></td>
                <td><%= a.normal_balance %></td>
                <td><code><%= a.owner_module %></code></td>
                <td><%= if a.active, do: "active", else: "retired" %></td>
              </tr>
            </tbody>
          </table>

        <% "trial_balance" -> %>
          <.institution_picker institutions={@institutions} institution={@institution} target={@myself} />

          <% {td, tc} = @trial_totals %>
          <p class={["ok-note", !Decimal.equal?(td, tc) && "alert"]}>
            Debits <strong><%= td %></strong> · Credits <strong><%= tc %></strong> —
            <%= if Decimal.equal?(td, tc), do: "balanced", else: "OUT OF BALANCE" %>
          </p>

          <table class="data-table">
            <thead>
              <tr><th>Code</th><th>Account</th><th>Class</th><th class="num">Debits</th><th class="num">Credits</th><th class="num">Balance</th></tr>
            </thead>
            <tbody>
              <tr :for={r <- @trial_rows}>
                <td><code><%= r.code %></code></td>
                <td><%= r.name %></td>
                <td><%= r.account_class %></td>
                <td class="num"><%= r.debits %></td>
                <td class="num"><%= r.credits %></td>
                <td class="num"><%= net_balance(r) %></td>
              </tr>
            </tbody>
          </table>
          <p :if={@trial_rows == []} class="cell-note">
            No postings yet. Run <code>mix run priv/repo/seed_gl_demo.exs</code> for demo data.
          </p>

        <% "ledger" -> %>
          <.institution_picker institutions={@institutions} institution={@institution} target={@myself} />
          <p class="cell-note">
            Consolidated per GL date and account correspondence — the bank's-books view.
            A second <em>generation</em> appears when activity arrives after an entry closed.
          </p>

          <table class="data-table">
            <thead>
              <tr><th>GL date</th><th>Debit</th><th>Credit</th><th>Ccy</th><th class="num">Amount</th><th class="num">Entries</th><th>Gen</th><th>Status</th></tr>
            </thead>
            <tbody>
              <tr :for={l <- @ledger_entries}>
                <td><%= l.gl_date %></td>
                <td><code><%= l.dr_account %></code></td>
                <td><code><%= l.cr_account %></code></td>
                <td><%= l.currency %></td>
                <td class="num"><%= l.amount %></td>
                <td class="num"><%= l.entry_count %></td>
                <td><%= l.generation %></td>
                <td><span class={["badge", String.downcase(l.status)]}><%= l.status %></span></td>
              </tr>
            </tbody>
          </table>
          <p :if={@ledger_entries == []} class="cell-note">No consolidated GL entries yet.</p>

        <% "journal" -> %>
          <.institution_picker institutions={@institutions} institution={@institution} target={@myself} />
          <p class="cell-note">
            One row per product-account movement — the customer's-account view, where
            GL Entries above is the bank's. Showing the most recent 200.
          </p>

          <table class="data-table">
            <thead>
              <tr><th>Posting date</th><th>GL date</th><th>Account</th><th>Product</th><th>Event</th><th>Dr</th><th>Cr</th><th class="num">Amount</th><th>Narrative</th></tr>
            </thead>
            <tbody>
              <tr :for={j <- @journal_entries}>
                <td><%= j.posting_date %></td>
                <td><%= j.gl_date %></td>
                <td><code><%= j.account_ref %></code></td>
                <td><%= j.product %></td>
                <td><%= j.event_type %></td>
                <td><code><%= j.dr %></code></td>
                <td><code><%= j.cr %></code></td>
                <td class="num"><%= j.amount %> <%= j.currency %></td>
                <td class="cell-note"><%= j.narrative %></td>
              </tr>
            </tbody>
          </table>
          <p :if={@journal_entries == []} class="cell-note">No journal entries yet.</p>

        <% "shadow" -> %>
          <div :if={!@shadow_enabled} class="alert">
            <strong>Shadow posting is off.</strong>
            Enable with <code>config :vmu_core, VmuCore.Posting.Shadow, enabled: true</code>.
            While off, the legacy poster runs alone and nothing new is written for comparison.
          </div>

          <p class="cell-note">
            Legacy <code>cms_ledger_entries</code> compared against the new posting engine,
            joined on idempotency key, for postings since <%= @shadow_since %>.
            Only postings the shadow itself mirrored are compared — sets the engine
            wrote directly (demo seed data, and Phase C call sites once cut over)
            legitimately have no legacy counterpart and are excluded.
            Cutover is defensible when <strong>mismatch</strong> and
            <strong>orphan</strong> are zero over a meaningful <strong>mirrored</strong> sample.
          </p>

          <div class="stat-row">
            <span class="stat"><strong><%= @shadow_summary.shadow_written %></strong> mirrored</span>
            <span class="stat"><strong><%= @shadow_summary.match %></strong> match</span>
            <span class={["stat", @shadow_summary.mismatch > 0 && "alert"]}>
              <strong><%= @shadow_summary.mismatch %></strong> mismatch
            </span>
            <span class="stat"><strong><%= @shadow_summary.missing_shadow %></strong> missing shadow</span>
            <span class={["stat", @shadow_summary.orphan_shadow > 0 && "alert"]}>
              <strong><%= @shadow_summary.orphan_shadow %></strong> orphan
            </span>
            <span class={["stat", @shadow_summary.equivalent? && @shadow_summary.shadow_written > 0 && "ok-note"]}>
              <%= cond do %>
                <% @shadow_summary.shadow_written == 0 -> %>no shadow data yet
                <% @shadow_summary.equivalent? -> %>equivalent
                <% true -> %>NOT equivalent
              <% end %>
            </span>
          </div>

          <table class="data-table">
            <thead>
              <tr><th>Status</th><th>Idempotency key</th><th>Legacy Dr/Cr</th><th>Shadow Dr/Cr</th><th class="num">Amount</th><th>Differences</th></tr>
            </thead>
            <tbody>
              <tr :for={r <- @shadow_rows} class={r.status == :mismatch && "row-alert"}>
                <td><span class={["badge", to_string(r.status)]}><%= r.status %></span></td>
                <td><code><%= r.idempotency_key %></code></td>
                <td><%= if r.legacy, do: "#{r.legacy.gl_account_dr}/#{r.legacy.gl_account_cr}", else: "—" %></td>
                <td><%= if r.shadow, do: "#{r.shadow.dr_gl_account}/#{r.shadow.cr_gl_account}", else: "—" %></td>
                <td class="num"><%= (r.legacy && r.legacy.dr_amount) || (r.shadow && r.shadow.amount) %></td>
                <td class="cell-note"><%= Enum.join(r.differences, "; ") %></td>
              </tr>
            </tbody>
          </table>
          <p :if={@shadow_rows == []} class="cell-note">Nothing posted in this window.</p>

        <% "rules" -> %>
          <div :if={@rules_pending != []} class="alert">
            <strong><%= length(@rules_pending) %> rule(s) still post to legacy accounts.</strong>
          </div>
          <p :if={@rules_pending == []} class="ok-note">
            All <%= length(@rules) %> rules post to the reconciled chart.
          </p>

          <table class="data-table">
            <thead>
              <tr><th>Product</th><th>Event</th><th>Debit</th><th>Credit</th><th>Txn code</th><th>Source</th></tr>
            </thead>
            <tbody>
              <tr :for={r <- @rules}>
                <td><%= r.product %></td>
                <td><%= r.event_type %></td>
                <td><code><%= r.dr_account %></code></td>
                <td><code><%= r.cr_account %></code></td>
                <td><%= r.legacy_transaction_code %></td>
                <td class="cell-note"><%= r.source_module %></td>
              </tr>
            </tbody>
          </table>

        <% "periods" -> %>
          <.institution_picker institutions={@institutions} institution={@institution} target={@myself} />

          <p :if={@banking_date} class="ok-note">
            Banking date <strong><%= @banking_date.current_banking_date %></strong>
            (<%= @banking_date.status %>)<%= if @banking_date.last_closed_date do %>
              · last close point <%= @banking_date.last_closed_date %><% end %>
          </p>

          <table class="data-table">
            <thead><tr><th>From</th><th>To</th><th>Status</th><th>Closed by</th><th>Actions</th></tr></thead>
            <tbody>
              <tr :for={p <- @periods}>
                <td><%= p.period_start %></td>
                <td><%= p.period_end %></td>
                <td><span class={["badge", String.downcase(p.status)]}><%= p.status %></span></td>
                <td class="cell-note"><%= p.closed_by %></td>
                <td>
                  <button :if={p.status == "OPEN"} phx-click="close_period"
                          phx-value-id={p.id} phx-target={@myself}>Close</button>
                  <button :if={p.status == "CLOSED"} phx-click="reopen_period"
                          phx-value-id={p.id} phx-target={@myself}>Reopen</button>
                  <button :if={p.status == "CLOSED"} phx-click="lock_period"
                          phx-value-id={p.id} phx-target={@myself}
                          data-confirm="Locking is permanent — a locked period can never be reopened. Continue?">
                    Lock
                  </button>
                  <span :if={p.status == "LOCKED"} class="cell-note">permanent</span>
                </td>
              </tr>
            </tbody>
          </table>

        <% "exceptions" -> %>
          <.institution_picker institutions={@institutions} institution={@institution} target={@myself} />

          <p :if={@exceptions == []} class="ok-note">
            No open exceptions. This is the healthy state — a row here means a posting
            arrived for a period that was already closed, which usually indicates
            processes ran out of order.
          </p>

          <table :if={@exceptions != []} class="data-table">
            <thead>
              <tr><th>Attempted GL date</th><th>Banking date</th><th>Close point</th><th>Reason</th><th>Detail</th></tr>
            </thead>
            <tbody>
              <tr :for={e <- @exceptions}>
                <td><%= e.attempted_gl_date %></td>
                <td><%= e.banking_date %></td>
                <td><%= e.close_point %></td>
                <td><span class="badge warn"><%= e.reason %></span></td>
                <td class="cell-note"><%= e.detail %></td>
              </tr>
            </tbody>
          </table>
      <% end %>
    </div>
    """
  end

  attr :institutions, :list, required: true
  attr :institution, :string, default: nil
  attr :target, :any, required: true

  defp institution_picker(assigns) do
    ~H"""
    <form phx-change="select_institution" phx-target={@target} class="inline-form">
      <label>
        Institution
        <select name="institution">
          <option :for={i <- @institutions} value={i} selected={i == @institution}><%= i %></option>
        </select>
      </label>
    </form>
    """
  end

  # Net in the account's own normal direction, so a healthy asset reads
  # positive rather than requiring the reader to remember the sign convention.
  defp net_balance(%{normal_balance: "debit", debits: d, credits: c}), do: Decimal.sub(d, c)
  defp net_balance(%{debits: d, credits: c}), do: Decimal.sub(c, d)

  defp tab_label("accounts"), do: "Chart of Accounts"
  defp tab_label("trial_balance"), do: "Trial Balance"
  defp tab_label("ledger"), do: "GL Entries"
  defp tab_label("journal"), do: "Journal Entries"
  defp tab_label("rules"), do: "Posting Rules"
  defp tab_label("periods"), do: "Periods"
  defp tab_label("exceptions"), do: "Exceptions"
  defp tab_label("shadow"), do: "Shadow Diff"
end
