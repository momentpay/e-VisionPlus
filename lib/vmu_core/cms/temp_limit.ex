defmodule VmuCore.CMS.TempLimit do
  @moduledoc """
  Temporary credit limit for a CMS account.

  A temp limit overrides an account's `credit_limit` for a defined window.
  The EOD `ReinstateLimitJob` scans for expired ACTIVE records daily and:
    1. Restores the `original_limit` on the account.
    2. Sets `status = 'REINSTATED'` and stamps `reinstated_at`.
    3. Recalculates OTB via `AccountStateCoordinator.refresh/1`.

  ## Business Rules
  - Only one ACTIVE temp limit per account at any time. Granting a new one
    supersedes the current ACTIVE record (sets it to SUPERSEDED).
  - `temp_limit` may be higher OR lower than `original_limit`.
  - 4-eyes required: `operator_id ≠ supervisor_id`.
  - Raw credit limits are in AED (or account functional currency).

  ## Usage
      TempLimit.grant(%{
        account_id:    "...",
        temp_limit:    Decimal.new("30000"),
        expiry_date:   ~D[2026-07-31],
        reason:        "Holiday promo",
        operator_id:   "OPS001",
        supervisor_id: "SUP002"
      })
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  require Logger
  alias VmuCore.{Repo, CMS.Account, CMS.AccountStateCoordinator}

  @primary_key {:temp_limit_id, :binary_id, autogenerate: true}

  @valid_statuses ~w[ACTIVE EXPIRED REINSTATED SUPERSEDED]

  schema "cms_temp_limits" do
    field :account_id,     :binary_id
    field :temp_limit,     :decimal
    field :original_limit, :decimal
    field :expiry_date,    :date
    field :reason,         :string
    field :status,         :string, default: "ACTIVE"
    field :operator_id,    :string
    field :supervisor_id,  :string
    field :reinstated_at,  :naive_datetime

    timestamps()
  end

  @type t :: %__MODULE__{}

  @required [:account_id, :temp_limit, :original_limit, :expiry_date, :operator_id, :supervisor_id]
  @optional [:reason, :status, :reinstated_at]

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:temp_limit,     greater_than: Decimal.new(0))
    |> validate_number(:original_limit, greater_than: Decimal.new(0))
    |> validate_4_eyes()
  end

  defp validate_4_eyes(cs) do
    op  = get_field(cs, :operator_id)
    sup = get_field(cs, :supervisor_id)

    if op && sup && op == sup,
      do:   add_error(cs, :supervisor_id, "supervisor_id must differ from operator_id (4-eyes required)"),
      else: cs
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Grant a temporary credit limit on an account.

  Supersedes any existing ACTIVE temp limit, applies the new limit to the
  account record, and refreshes AccountStateCoordinator.

  Returns `{:ok, %TempLimit{}}` or `{:error, changeset | String.t()}`.
  """
  @spec grant(map()) :: {:ok, __MODULE__.t()} | {:error, Ecto.Changeset.t() | String.t()}
  def grant(attrs) do
    account_id = attrs[:account_id] || attrs["account_id"]

    with {:ok, account} <- load_account(account_id),
         :ok <- future_expiry?(attrs[:expiry_date] || attrs["expiry_date"]) do

      Repo.transaction(fn ->
        # Supersede any existing ACTIVE temp limit
        Repo.update_all(
          from(t in __MODULE__,
            where: t.account_id == ^account_id and t.status == "ACTIVE"),
          set: [status: "SUPERSEDED", updated_at: NaiveDateTime.utc_now()]
        )

        # Insert new temp limit record
        record =
          %__MODULE__{}
          |> changeset(Map.merge(attrs, %{
            original_limit: account.credit_limit,
            status: "ACTIVE"
          }))
          |> Repo.insert!()

        # Apply the new limit to the account
        Repo.update_all(
          from(a in Account, where: a.account_id == ^account_id),
          set: [
            credit_limit: record.temp_limit,
            updated_at:   NaiveDateTime.utc_now()
          ]
        )

        AccountStateCoordinator.refresh(account_id)

        Logger.info("[TempLimit] Granted #{record.temp_limit} (orig=#{record.original_limit}) on #{account_id} until #{record.expiry_date}")
        record
      end)
    end
  end

  @doc """
  Reinstate the original limit for all accounts whose temp limit expired as of `as_of_date`.
  Called by the EOD ReinstateLimitJob.

  Returns `{:ok, count}` — the number of accounts reinstated.
  """
  @spec reinstate_expired(Date.t()) :: {:ok, non_neg_integer()}
  def reinstate_expired(as_of_date \\ Date.utc_today()) do
    expired =
      Repo.all(
        from t in __MODULE__,
          where: t.status == "ACTIVE" and t.expiry_date < ^as_of_date,
          select: t
      )

    count =
      Enum.reduce(expired, 0, fn temp_limit, acc ->
        case reinstate_one(temp_limit) do
          :ok ->
            Logger.info("[TempLimit] Reinstated original limit #{temp_limit.original_limit} on #{temp_limit.account_id}")
            acc + 1
          {:error, reason} ->
            Logger.error("[TempLimit] Reinstate failed #{temp_limit.account_id}: #{inspect(reason)}")
            acc
        end
      end)

    {:ok, count}
  end

  @doc """
  Return the currently active temp limit for an account, or nil.
  """
  @spec active_for(binary()) :: __MODULE__.t() | nil
  def active_for(account_id) do
    Repo.one(
      from t in __MODULE__,
        where: t.account_id == ^account_id and t.status == "ACTIVE",
        limit: 1
    )
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp reinstate_one(%__MODULE__{} = tl) do
    Repo.transaction(fn ->
      Repo.update_all(
        from(a in Account, where: a.account_id == ^tl.account_id),
        set: [credit_limit: tl.original_limit, updated_at: NaiveDateTime.utc_now()]
      )

      Repo.update_all(
        from(t in __MODULE__, where: t.temp_limit_id == ^tl.temp_limit_id),
        set: [
          status:        "REINSTATED",
          reinstated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
          updated_at:    NaiveDateTime.utc_now()
        ]
      )

      AccountStateCoordinator.refresh(tl.account_id)
    end)
    |> case do
      {:ok, _}         -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_account(account_id) do
    case Repo.get(Account, account_id) do
      nil     -> {:error, "Account not found: #{account_id}"}
      account -> {:ok, account}
    end
  end

  defp future_expiry?(nil), do: {:error, "expiry_date is required"}
  defp future_expiry?(%Date{} = d) do
    if Date.compare(d, Date.utc_today()) == :gt,
      do:   :ok,
      else: {:error, "expiry_date must be in the future"}
  end
  defp future_expiry?(d) when is_binary(d), do: future_expiry?(Date.from_iso8601!(d))
end
