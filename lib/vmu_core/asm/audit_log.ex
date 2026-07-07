defmodule VmuCore.ASM.AuditLog do
  @moduledoc """
  Central operator-audit API (ASM-P4.1/P4.2).

  - `record/4` — the single write path for operator activity: writes and
    4-eyes decisions (`action` like `"fee_waiver"`, `"adjustment_approve"`)
    AND read-access to PII (`"customer_pii_view"`, `"account_detail_view"` —
    FR-ASM-015: who looked at which cardholder, when). Fail-safe: an audit
    insert failure logs and never breaks the operation being audited.
  - `search/2` — powers the compliance search UI (FR-ASM-016).

  Sink: the append-only `cms_operator_audit` table (adopted from the legacy
  OperatorPortal — one audit trail, not two).
  """

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.ASM.{Operator, AuditEntry}

  @doc """
  Record an operator action. `operator` is the authenticated `%Operator{}`
  (nil tolerated for system-context calls — recorded as "system").
  """
  @spec record(Operator.t() | nil, String.t(), String.t(), map()) :: :ok
  def record(operator, action, subject, details \\ %{}) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all("cms_operator_audit", [
      %{
        operator_id:   (operator && operator.username) || "system",
        operator_role: (operator && operator.role) || "SYSTEM",
        action:        String.slice(action, 0, 50),
        subject:       String.slice(to_string(subject), 0, 100),
        details:       Jason.encode!(details),
        performed_at:  now,
        inserted_at:   now
      }
    ])

    :ok
  rescue
    e ->
      Logger.error("[ASM.AuditLog] audit insert failed (#{action}): #{Exception.message(e)}")
      :ok
  end

  @doc """
  Search the audit trail. Filters (all optional): `:operator_id` (exact
  username), `:action` (prefix match), `:subject` (exact), `:date_from` /
  `:date_to` (Dates). Options: `:page` / `:per_page` (default 50).

  Returns `%{entries: [...], total: n, page: p}`, newest first.
  """
  @spec search(map(), keyword()) :: %{entries: [AuditEntry.t()], total: non_neg_integer(), page: pos_integer()}
  def search(filters, opts \\ []) do
    page     = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)

    query =
      from(a in AuditEntry, order_by: [desc: a.performed_at])
      |> apply_filters(filters)

    total   = Repo.aggregate(exclude(query, :order_by), :count, :id)
    entries = Repo.all(from q in query, limit: ^per_page, offset: ^((page - 1) * per_page))

    %{entries: entries, total: total, page: page}
  end

  @doc "Distinct action names present in the trail — filter dropdown."
  @spec distinct_actions() :: [String.t()]
  def distinct_actions do
    Repo.all(from a in AuditEntry, distinct: true, select: a.action, order_by: a.action)
  end

  @doc """
  Entries whose `subject` is one of `subjects` (CTA-P3.3 — a multi-card event
  timeline on one account screen needs several subjects at once, which
  `search/2`'s single-`subject` filter can't express). Optional
  `:action_prefix` narrows to one action family (e.g. `"card_"`).
  """
  @spec for_subjects([String.t()], keyword()) :: [AuditEntry.t()]
  def for_subjects(subjects, opts \\ [])
  def for_subjects([], _opts), do: []

  def for_subjects(subjects, opts) do
    subjects = Enum.map(subjects, &to_string/1)
    prefix   = Keyword.get(opts, :action_prefix)
    limit    = Keyword.get(opts, :limit, 200)

    from(a in AuditEntry, where: a.subject in ^subjects, order_by: [desc: a.performed_at], limit: ^limit)
    |> then(fn q -> if prefix, do: where(q, [a], like(a.action, ^"#{prefix}%")), else: q end)
    |> Repo.all()
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {_k, v}, q when v in [nil, ""] -> q
      {:operator_id, v}, q -> where(q, [a], a.operator_id == ^v)
      {:action, v}, q      -> where(q, [a], like(a.action, ^"#{v}%"))
      {:subject, v}, q     -> where(q, [a], a.subject == ^v)
      {:date_from, %Date{} = v}, q ->
        where(q, [a], a.performed_at >= ^NaiveDateTime.new!(v, ~T[00:00:00]))
      {:date_to, %Date{} = v}, q ->
        where(q, [a], a.performed_at <= ^NaiveDateTime.new!(v, ~T[23:59:59]))
      {_other, _v}, q -> q
    end)
  end
end
