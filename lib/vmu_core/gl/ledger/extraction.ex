defmodule VmuCore.GL.Extraction do
  @moduledoc """
  Tracks which journal entries have been handed to an external consumer
  (GL Phase C3).

  ## What this replaces

  `cms_ledger_entries.extracted_at`, stamped in place by
  `CMS.CoreBankingAdapter`. That column was the one thing the new posting model
  had no equivalent for, and the reason that adapter was the last reader left
  on the legacy table.

  `gl_ledger_entries` *does* have an `extracted_at`, but at the wrong grain —
  one row per (institution, GL date, debit account, credit account), whereas
  the adapter extracts per account, per posting date, per entry. Reusing it
  would have meant either sending consolidated totals where line detail is
  expected, or marking a whole correspondence extracted because one of its
  entries was.

  ## Why extraction state lives outside the journal

  `journal_entries` is an immutable record of what was posted. Extraction is
  something that later happened *to* an entry, performed by a party outside the
  ledger — writing it back would mutate an accounting record to track a
  delivery concern. Keying separately also lets more than one consumer track
  its own position, which a single timestamp cannot.

  ## Idempotency

  `mark!/3` upserts on `(journal_entry_id, destination)` and returns how many
  rows were genuinely new. Re-running an extract is therefore safe: the second
  run marks nothing and reports zero, rather than double-sending or raising.
  """

  use Ecto.Schema

  import Ecto.Query, warn: false

  alias VmuCore.Repo
  alias VmuCore.Posting.JournalEntry

  @default_destination "CORE_BANKING"

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "gl_extractions" do
    field :destination, :string, default: @default_destination
    field :extracted_at, :utc_datetime_usec
    field :batch_ref, :string

    belongs_to :journal_entry, JournalEntry

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The destination used when a caller does not name one."
  @spec default_destination() :: String.t()
  def default_destination, do: @default_destination

  @doc """
  Journal entries for `posting_date` that `destination` has not yet received.

  `:account_ref` narrows to one account. Ordered by write time so an extract
  presents entries in the order they were posted, which is what the legacy
  adapter did and what a consumer reconciling a sequence expects.
  """
  @spec unextracted(Date.t(), keyword()) :: [map()]
  def unextracted(%Date{} = posting_date, opts \\ []) do
    destination = Keyword.get(opts, :destination, @default_destination)

    JournalEntry
    |> where([j], j.posting_date == ^posting_date)
    |> then(fn q ->
      case Keyword.get(opts, :account_ref) do
        nil -> q
        ref -> where(q, [j], j.account_ref == ^to_string(ref))
      end
    end)
    |> join(:inner, [j], s in assoc(j, :posting_set))
    # The anti-join that defines "not yet extracted". Left join plus a null
    # check rather than `not in (subquery)`: it stays a single index scan on
    # the unique key as the table grows.
    |> join(:left, [j, _s], x in __MODULE__,
      on: x.journal_entry_id == j.id and x.destination == ^destination
    )
    |> where([_j, _s, x], is_nil(x.id))
    |> order_by([j, _s, _x], asc: j.inserted_at)
    |> select([j, s, _x], %{
      id: j.id,
      account_ref: j.account_ref,
      product: j.product,
      event_type: s.event_type,
      idempotency_key: s.idempotency_key,
      dr_gl_account: j.dr_gl_account,
      cr_gl_account: j.cr_gl_account,
      amount: j.amount,
      currency: j.currency,
      posting_date: j.posting_date,
      transaction_date: j.transaction_date,
      gl_date: j.gl_date,
      narrative: j.narrative
    })
    |> Repo.all()
  end

  @doc """
  Distinct accounts with entries `destination` has not yet received on
  `posting_date`.

  The shape `CoreBankingAdapter.extract_all/1` drives its per-account loop from.
  """
  @spec pending_account_refs(Date.t(), keyword()) :: [String.t()]
  def pending_account_refs(%Date{} = posting_date, opts \\ []) do
    destination = Keyword.get(opts, :destination, @default_destination)

    JournalEntry
    |> where([j], j.posting_date == ^posting_date)
    |> join(:left, [j], x in __MODULE__,
      on: x.journal_entry_id == j.id and x.destination == ^destination
    )
    |> where([_j, x], is_nil(x.id))
    |> distinct(true)
    |> select([j, _x], j.account_ref)
    |> Repo.all()
  end

  @doc """
  Records that `entries` were delivered to `destination`.

  Returns the number of rows genuinely inserted — an entry already marked for
  this destination is left alone, so a replayed extract reports 0 rather than
  raising or double-counting.
  """
  @spec mark!([map()] | [String.t()], keyword()) :: non_neg_integer()
  def mark!(entries, opts \\ [])

  def mark!([], _opts), do: 0

  def mark!(entries, opts) do
    destination = Keyword.get(opts, :destination, @default_destination)
    batch_ref = Keyword.get(opts, :batch_ref)
    now = DateTime.utc_now()

    rows =
      Enum.map(entries, fn entry ->
        %{
          journal_entry_id: entry_id(entry),
          destination: destination,
          extracted_at: now,
          batch_ref: batch_ref,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} =
      Repo.insert_all(__MODULE__, rows,
        on_conflict: :nothing,
        conflict_target: [:journal_entry_id, :destination]
      )

    count
  end

  @doc "True when this entry has already gone to `destination`."
  @spec extracted?(String.t(), keyword()) :: boolean()
  def extracted?(journal_entry_id, opts \\ []) do
    destination = Keyword.get(opts, :destination, @default_destination)

    Repo.exists?(
      from x in __MODULE__,
        where: x.journal_entry_id == ^journal_entry_id and x.destination == ^destination
    )
  end

  defp entry_id(%{id: id}), do: id
  defp entry_id(id) when is_binary(id), do: id
end
