defmodule VmuCore.TRAMS.TransactionSearch do
  @moduledoc """
  Transaction inquiry — the read side of TRAM (TRAM-P6 6A, spec 04 §2.1).

  Locates transactions by any combination of:

  | Filter | Semantics |
  |---|---|
  | `:account_id` | exact |
  | `:pan` | full PAN — tokenized here, never stored/logged (PCI: `pan_token` is a SHA-256, so "last 4" search is impossible by design) |
  | `:rrn` / `:stan` / `:auth_code` | via `trams_transaction_identifiers` (any source message) |
  | `:merchant` | ILIKE on merchant_name OR exact merchant_id |
  | `:state` | lifecycle state |
  | `:amount_from` / `:amount_to` | on authorized amount |
  | `:date_from` / `:date_to` | on `inserted_at` |

  Returns `%{results: [...], total: n, page: p}`; results ordered newest first.
  """

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.TRAMS.{Transaction, TransactionIdentifier}

  @default_per_page 25

  @spec search(map(), keyword()) :: %{results: [Transaction.t()], total: non_neg_integer(), page: pos_integer()}
  def search(filters, opts \\ []) do
    page     = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, @default_per_page)

    query =
      from(t in Transaction, order_by: [desc: t.inserted_at])
      |> apply_filters(filters)

    total   = Repo.aggregate(exclude(query, :order_by), :count, :transaction_id)
    results = Repo.all(from q in query, limit: ^per_page, offset: ^((page - 1) * per_page))

    %{results: results, total: total, page: page}
  end

  # ---------------------------------------------------------------------------
  # Filters
  # ---------------------------------------------------------------------------

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {_k, v}, q when v in [nil, ""] -> q
      {:account_id, v}, q  -> where(q, [t], t.account_id == ^v)
      {:pan, v}, q         -> where(q, [t], t.pan_token == ^pan_token(v))
      {:state, v}, q       -> where(q, [t], t.state == ^v)
      {:merchant, v}, q    ->
        where(q, [t], ilike(t.merchant_name, ^"%#{v}%") or t.merchant_id == ^v)
      {:amount_from, v}, q -> where(q, [t], t.amount >= ^v)
      {:amount_to, v}, q   -> where(q, [t], t.amount <= ^v)
      {:date_from, %Date{} = v}, q ->
        where(q, [t], t.inserted_at >= ^DateTime.new!(v, ~T[00:00:00], "Etc/UTC"))
      {:date_to, %Date{} = v}, q ->
        where(q, [t], t.inserted_at <= ^DateTime.new!(v, ~T[23:59:59], "Etc/UTC"))
      {:rrn, v}, q         -> by_identifier(q, :rrn, v)
      {:stan, v}, q        -> by_identifier(q, :stan, v)
      {:auth_code, v}, q   -> by_identifier(q, :auth_code, v)
      {_other, _v}, q      -> q
    end)
  end

  defp by_identifier(query, field, value) do
    ids =
      from i in TransactionIdentifier,
        where: field(i, ^field) == ^value,
        select: i.transaction_id

    where(query, [t], t.transaction_id in subquery(ids))
  end

  defp pan_token(pan),
    do: :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)
end
