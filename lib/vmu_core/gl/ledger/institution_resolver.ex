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
  #
  # HCS_FLEET and HCS_CORPORATE point at `cms_accounts` deliberately. HCS cards
  # are an **overlay**, not a separate account table: `hcs_fleet_cards` and
  # `hcs_employee_cards` carry no `sys_id`/`bank_id` of their own, they hold the
  # id of a real `CMS.Account` that does. So the institution comes from
  # `cms_accounts` exactly as it does for CREDIT — only the *product label*
  # differs, and that is decided by `hcs_overlay/1` below.
  @sources %{
    "CREDIT" => {"cms_accounts", :account_id},
    "CREDIT_CARD" => {"cms_accounts", :account_id},
    "HCS_FLEET" => {"cms_accounts", :account_id},
    "HCS_CORPORATE" => {"cms_accounts", :account_id},
    "DEBIT" => {"cms_debit_accounts", :debit_account_id},
    "PREPAID" => {"cms_prepaid_accounts", :prepaid_account_id},
    "WPS_PREPAID" => {"cms_prepaid_accounts", :prepaid_account_id},
    "WALLET" => {"cms_wallet_accounts", :wallet_account_id}
  }

  # Overlays: a product whose accounts live in another product's table, claimed
  # by a membership row elsewhere.
  #
  # Keyed by the **base table** the account actually lives in, because that is
  # what `resolve/1` caches and what decides which overlay can possibly apply.
  # Probing every overlay for every account would mean a WPS lookup on every
  # credit posting, and vice versa.
  #
  #   base table => [{claiming table, its account column, resulting product}]
  @overlay_sources %{
    "cms_accounts" => [
      {"hcs_fleet_cards", :account_id, "HCS_FLEET"},
      {"hcs_employee_cards", :employee_account_id, "HCS_CORPORATE"}
    ],
    "cms_prepaid_accounts" => [
      # A WPS worker holds an ordinary prepaid account; joining an employer's
      # roster is what makes it salary float. See `VmuCore.WPS.BeneficiaryLink`.
      {"wps_beneficiary_links", :prepaid_account_id, "WPS_PREPAID"}
    ]
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
        {:ok, refine(table, account_ref)}

      :miss ->
        case resolve(account_ref) do
          {:ok, _} ->
            case cached(account_ref) do
              {:ok, table, _} -> {:ok, refine(table, account_ref)}
              :miss -> {:error, :not_found}
            end

          error ->
            error
        end
    end
  end

  @doc """
  Which overlay product, if any, claims this account.

  `table` is the base product table the account lives in — overlays are scoped
  to it, so a prepaid account is never tested against the HCS card tables.

  Exposed so callers can ask directly rather than inferring from a product
  string.
  """
  @spec overlay(String.t(), String.t()) :: {:ok, String.t()} | :none
  def overlay(table, account_ref) when is_binary(table) and is_binary(account_ref) do
    case Map.get(@overlay_sources, table) do
      nil ->
        :none

      sources ->
        case cached_overlay(table, account_ref) do
          # The cached-negative clause must come first: a cached "no overlay" is
          # stored as `{:ok, nil}`, which would otherwise match `{:ok, product}`
          # and hand back `{:ok, nil}` as though nil were a product.
          {:ok, nil} -> :none
          {:ok, product} -> {:ok, product}
          :miss -> lookup_overlay(table, account_ref, sources)
        end
    end
  end

  @doc """
  Which HCS card table, if any, claims this account.

  Retained for callers that ask the HCS question specifically.
  """
  @spec hcs_overlay(String.t()) :: {:ok, String.t()} | :none
  def hcs_overlay(account_ref) when is_binary(account_ref),
    do: overlay("cms_accounts", account_ref)

  @doc "Which WPS roster, if any, claims this prepaid account."
  @spec wps_overlay(String.t()) :: {:ok, String.t()} | :none
  def wps_overlay(account_ref) when is_binary(account_ref),
    do: overlay("cms_prepaid_accounts", account_ref)

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

  # `cms_accounts` backs four product labels. CREDIT and CREDIT_CARD are the
  # consumer pair; HCS_FLEET and HCS_CORPORATE are decided by whether an HCS
  # card table claims the account. Only `cms_accounts` needs refining — the
  # stored-value tables map one-to-one.
  defp refine(table, account_ref) do
    case overlay(table, account_ref) do
      {:ok, product} -> product
      :none -> product_for_table(table)
    end
  end

  # Cached separately from the institution, and cached on the negative result
  # too: the overwhelming majority of accounts are not HCS, and without a
  # negative cache every one of them would pay two extra queries on the posting
  # path to learn that again.
  defp lookup_overlay(base_table, account_ref, sources) do
    product =
      Enum.find_value(sources, fn {table, key_column, product} ->
        if overlay_claims?(account_ref, table, key_column), do: product
      end)

    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {{:overlay, base_table, account_ref}, product})
    end

    if product, do: {:ok, product}, else: :none
  end

  # Keyed by `{base_table, account_ref}`, not by the reference alone.
  #
  # Keying on the reference was a real defect, caught by
  # `WPS.RosterTest` before it shipped: asking the HCS question about a prepaid
  # account cached a negative under that reference, and the WPS question then
  # got the cached `nil` and answered `:none`. It is the same shape as the
  # institution-cache bug this module's moduledoc describes — a cache whose key
  # is narrower than its question.
  defp cached_overlay(base_table, account_ref) do
    if :ets.whereis(@table) == :undefined do
      :miss
    else
      case :ets.lookup(@table, {:overlay, base_table, account_ref}) do
        [{_key, product}] -> {:ok, product}
        [] -> :miss
      end
    end
  end

  defp overlay_claims?(account_ref, table, key_column) do
    case Ecto.UUID.cast(account_ref) do
      {:ok, uuid} ->
        Repo.exists?(
          from(c in table, where: field(c, ^key_column) == type(^uuid, Ecto.UUID))
        )

      :error ->
        false
    end
  rescue
    e in Postgrex.Error ->
      Logger.debug("[GL] InstitutionResolver skipped overlay #{table}: #{Exception.message(e)}")
      false
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
