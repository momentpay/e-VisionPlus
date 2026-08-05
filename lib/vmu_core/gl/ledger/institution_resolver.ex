defmodule VmuCore.GL.InstitutionResolver do
  @moduledoc """
  Resolves which institution (`sys_id`/`bank_id`) an account belongs to
  (GL Phase B1).

  ## Why this is needed

  `Posting.RuleEngine` requires an institution — the period gate and GL
  consolidation both key on it. The legacy posting functions do not carry one:
  `InternalGlPoster.post_interest(account_id, amount, posting_date, key)` knows
  the account and nothing else.

  Every product account table does carry `sys_id`/`bank_id`, so the institution
  is recoverable from the account reference. This module is that lookup, and it
  exists so shadow mode can run without changing a single legacy signature.

  ## Ambiguity is real

  All four tables key on a UUID, and `cms_ledger_entries.account_id` is a bare
  `:binary_id` with no foreign key — deliberately, so one column can address
  four products. So an account reference alone does not say which table to
  look in. Pass the product when it is known; without it this searches all
  four, and a UUID colliding across tables would be genuinely ambiguous
  (astronomically unlikely, but `resolve/1` reports it rather than guessing).

  ## Caching

  An account's institution does not change, so results are cached in ETS.
  Shadow mode runs on every posting, and an uncached lookup would add up to
  four queries to a hot path that already does real work.

  The cache stores **which product table the account was found in** alongside
  the institution. Caching the institution alone was a real defect, caught by
  the Phase B shadow diff: `resolve/2` would return a cache hit for *any*
  product once an account had been resolved for one, so a credit account
  looked like a debit account to the first caller that asked. The symptom was
  a FEE posting silently failing to mirror while INTEREST on the same account
  succeeded — because INTEREST ran first and poisoned the entry.
  """

  use GenServer
  require Logger

  import Ecto.Query, warn: false
  alias VmuCore.Repo

  @table :vmu_gl_institution_cache

  # product => {table, primary key column}
  @sources %{
    "CREDIT" => {"cms_accounts", :account_id},
    "CREDIT_CARD" => {"cms_accounts", :account_id},
    "DEBIT" => {"cms_debit_accounts", :debit_account_id},
    "PREPAID" => {"cms_prepaid_accounts", :prepaid_account_id},
    "WALLET" => {"cms_wallet_accounts", :wallet_account_id}
  }

  # ---------------------------------------------------------------------------
  # API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Resolves the institution for an account, given its product.

  Returns `{:ok, {sys_id, bank_id}}`, or `{:error, :not_found}` when the
  account does not exist in that product's table.
  """
  @spec resolve(String.t(), String.t()) :: {:ok, {String.t(), String.t()}} | {:error, :not_found}
  def resolve(account_ref, product) when is_binary(account_ref) and is_binary(product) do
    with {:ok, source} <- Map.fetch(@sources, product),
         {table, _key} = source do
      case cached(account_ref) do
        # A hit only counts when the account was found in THIS product's table.
        {:ok, ^table, institution} -> {:ok, institution}
        {:ok, _other_table, _} -> {:error, :not_found}
        :miss -> lookup_and_cache(account_ref, [source])
      end
    else
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Which product an account belongs to, resolved from the table it lives in.

  Preferable to trying `resolve/2` against each product in turn — that pattern
  is what the cache defect above made unsafe.
  """
  @spec resolve_product(String.t()) :: {:ok, String.t()} | {:error, :not_found | :ambiguous}
  def resolve_product(account_ref) when is_binary(account_ref) do
    case cached(account_ref) do
      {:ok, table, _institution} ->
        {:ok, product_for_table(table)}

      :miss ->
        case resolve(account_ref) do
          {:ok, _} ->
            case cached(account_ref) do
              {:ok, table, _} -> {:ok, product_for_table(table)}
              :miss -> {:error, :not_found}
            end

          error ->
            error
        end
    end
  end

  @doc """
  Resolves without knowing the product, searching every product table.

  Returns `{:error, :ambiguous}` if the same reference exists in more than one
  — reported rather than guessed at, because picking the wrong one would post
  to the wrong institution's books.
  """
  @spec resolve(String.t()) ::
          {:ok, {String.t(), String.t()}} | {:error, :not_found | :ambiguous}
  def resolve(account_ref) when is_binary(account_ref) do
    case cached(account_ref) do
      {:ok, _table, institution} ->
        {:ok, institution}

      :miss ->
        matches =
          @sources
          |> Map.values()
          |> Enum.uniq()
          |> Enum.map(fn {table, _key} = source ->
            case query(account_ref, source) do
              nil -> nil
              institution -> {table, institution}
            end
          end)
          |> Enum.reject(&is_nil/1)

        case Enum.uniq_by(matches, fn {table, _} -> table end) do
          [] -> {:error, :not_found}
          [{table, institution}] -> cache_and_return(account_ref, table, institution)
          _ -> {:error, :ambiguous}
        end
    end
  end

  @doc "Clears the cache. Only needed in tests and after a data reload."
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer — owns the ETS table
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Logger.info("[GL] InstitutionResolver cache created")
    {:ok, %{}}
  end

  # ---------------------------------------------------------------------------

  defp cached(account_ref) do
    if :ets.whereis(@table) == :undefined do
      :miss
    else
      case :ets.lookup(@table, account_ref) do
        [{^account_ref, source_table, institution}] -> {:ok, source_table, institution}
        [] -> :miss
      end
    end
  end

  defp lookup_and_cache(account_ref, sources) do
    sources
    |> Enum.find_value(fn {table, _key} = source ->
      case query(account_ref, source) do
        nil -> nil
        institution -> {table, institution}
      end
    end)
    |> case do
      nil -> {:error, :not_found}
      {table, institution} -> cache_and_return(account_ref, table, institution)
    end
  end

  defp cache_and_return(account_ref, table, institution) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {account_ref, table, institution})
    end

    {:ok, institution}
  end

  # cms_accounts backs both CREDIT and CREDIT_CARD; CREDIT is the product the
  # legacy poster writes for, so it is the right default here.
  defp product_for_table("cms_accounts"), do: "CREDIT"
  defp product_for_table("cms_debit_accounts"), do: "DEBIT"
  defp product_for_table("cms_prepaid_accounts"), do: "PREPAID"
  defp product_for_table("cms_wallet_accounts"), do: "WALLET"

  # Raw table query rather than a schema, so this module does not depend on
  # four product contexts — and so it keeps working if any of them changes
  # shape around columns it does not use.
  defp query(account_ref, {table, key_column}) do
    case Ecto.UUID.cast(account_ref) do
      {:ok, uuid} ->
        Repo.one(
          from(a in table,
            where: field(a, ^key_column) == type(^uuid, Ecto.UUID),
            select: {a.sys_id, a.bank_id},
            limit: 1
          )
        )

      :error ->
        nil
    end
  rescue
    # A product table that does not exist in this environment must not take
    # down a resolution that another table can satisfy.
    e in Postgrex.Error ->
      Logger.debug("[GL] InstitutionResolver skipped #{table}: #{Exception.message(e)}")
      nil
  end
end
