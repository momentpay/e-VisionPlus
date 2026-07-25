defmodule VmuCore.CTA.CredentialVault do
  @moduledoc """
  Ephemeral, exactly-once credential store for virtual card issuance
  (Way4 parity plan Phase 1 item 1, 2026-07-25).

  The raw PAN/CVV are needed exactly once — to answer the one-time-reveal
  API call — and must never be "persisted in retrievable form". This
  GenServer holds them only in an ETS table it owns (never written to
  Postgres, never touched by a backup/replica), and `reveal/1` atomically
  reads-and-deletes: the first caller gets the credentials, every
  subsequent call for the same card_id gets `{:error, :not_found}`, same
  as if it had never existed. Entries older than `@ttl_ms` are swept even
  if never revealed, so an abandoned issuance doesn't leave credentials
  sitting around indefinitely.

  All read/write ops are routed through this single process (not raw ETS
  calls from callers) specifically so concurrent reveal attempts for the
  same card_id are serialized — only one can ever win.
  """

  use GenServer

  @table :cta_credential_vault
  @ttl_ms :timer.minutes(15)
  @sweep_interval_ms :timer.minutes(5)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Stores credentials for a card_id, retrievable exactly once via reveal/1."
  @spec put(Ecto.UUID.t(), map()) :: :ok
  def put(card_id, credentials) do
    GenServer.call(__MODULE__, {:put, card_id, credentials})
  end

  @doc "Reads and deletes the credentials for a card_id. Returns {:ok, credentials} | {:error, :not_found}."
  @spec reveal(Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  def reveal(card_id) do
    GenServer.call(__MODULE__, {:reveal, card_id})
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :protected, :named_table])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, card_id, credentials}, _from, state) do
    :ets.insert(@table, {card_id, credentials, System.monotonic_time(:millisecond)})
    {:reply, :ok, state}
  end

  def handle_call({:reveal, card_id}, _from, state) do
    reply =
      case :ets.lookup(@table, card_id) do
        [{^card_id, credentials, inserted_at}] ->
          :ets.delete(@table, card_id)
          if fresh?(inserted_at), do: {:ok, credentials}, else: {:error, :not_found}

        [] ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    stale_ids = for {id, _c, t} <- :ets.tab2list(@table), now - t > @ttl_ms, do: id
    Enum.each(stale_ids, &:ets.delete(@table, &1))
    schedule_sweep()
    {:noreply, state}
  end

  defp fresh?(inserted_at), do: System.monotonic_time(:millisecond) - inserted_at <= @ttl_ms

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
