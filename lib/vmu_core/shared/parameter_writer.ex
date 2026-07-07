defmodule VmuCore.Shared.ParameterWriter do
  @moduledoc """
  Authoritative write path for all VisionPlus parameter schemas.

  ## Motivation (3L)

  `ParameterEngine` caches all parameters in ETS for sub-millisecond lookups on
  the authorisation hot path. This cache must stay in sync with the database.
  Rather than relying on callers to remember to call `ParameterEngine.refresh_all/0`
  after a manual `Repo.update`, this module wraps every parameter change so the
  refresh is **automatic and mandatory**.

  ## Usage

      alias VmuCore.Shared.ParameterWriter

      # Update logo APR
      {:ok, logo} = ParameterWriter.update_logo(existing_logo, %{purchase_apr: Decimal.new("22.00")})

      # Create or replace a block-level override
      {:ok, block} = ParameterWriter.create_or_update_block(attrs)

  All functions return `{:ok, struct}` or `{:error, changeset}`. On success,
  `ParameterEngine.refresh_all/0` is called **inside the same process**, so
  the ETS cache is always up to date before the caller receives the `{:ok, ...}`.

  ## Operator audit

  Every write function accepts an optional `operator_id` keyword. When provided,
  it is logged at INFO level. Future versions will write to a parameter_audit_log
  table for regulatory audit requirements.
  """

  require Logger

  alias VmuCore.{Repo}
  alias VmuCore.Shared.{ParameterEngine, SysParameter, BankParameter, LogoParameter, BlockParameter}

  # ---------------------------------------------------------------------------
  # System parameters
  # ---------------------------------------------------------------------------

  @doc "Update SYS-level parameter record and refresh ETS cache."
  @spec update_sys(SysParameter.t(), map(), keyword()) ::
          {:ok, SysParameter.t()} | {:error, Ecto.Changeset.t()}
  def update_sys(%SysParameter{} = param, attrs, opts \\ []) do
    param
    |> SysParameter.changeset(attrs)
    |> Repo.update()
    |> refresh_on_success("SYS", param.sys_id, opts)
  end

  # ---------------------------------------------------------------------------
  # Bank parameters
  # ---------------------------------------------------------------------------

  @doc "Update BANK-level parameter record and refresh ETS cache."
  @spec update_bank(BankParameter.t(), map(), keyword()) ::
          {:ok, BankParameter.t()} | {:error, Ecto.Changeset.t()}
  def update_bank(%BankParameter{} = param, attrs, opts \\ []) do
    param
    |> BankParameter.changeset(attrs)
    |> Repo.update()
    |> refresh_on_success("BANK", param.bank_id, opts)
  end

  # ---------------------------------------------------------------------------
  # Logo parameters
  # ---------------------------------------------------------------------------

  @doc "Update LOGO-level parameter record and refresh ETS cache."
  @spec update_logo(LogoParameter.t(), map(), keyword()) ::
          {:ok, LogoParameter.t()} | {:error, Ecto.Changeset.t()}
  def update_logo(%LogoParameter{} = param, attrs, opts \\ []) do
    param
    |> LogoParameter.changeset(attrs)
    |> Repo.update()
    |> refresh_on_success("LOGO", param.logo_id, opts)
  end

  @doc "Insert a new LOGO parameter record and refresh ETS cache."
  @spec create_logo(map(), keyword()) ::
          {:ok, LogoParameter.t()} | {:error, Ecto.Changeset.t()}
  def create_logo(attrs, opts \\ []) do
    %LogoParameter{}
    |> LogoParameter.changeset(attrs)
    |> Repo.insert()
    |> refresh_on_success("LOGO", Map.get(attrs, :logo_id) || Map.get(attrs, "logo_id"), opts)
  end

  # ---------------------------------------------------------------------------
  # Block parameters
  # ---------------------------------------------------------------------------

  @doc "Update BLOCK-level parameter record and refresh ETS cache."
  @spec update_block(BlockParameter.t(), map(), keyword()) ::
          {:ok, BlockParameter.t()} | {:error, Ecto.Changeset.t()}
  def update_block(%BlockParameter{} = param, attrs, opts \\ []) do
    param
    |> BlockParameter.changeset(attrs)
    |> Repo.update()
    |> refresh_on_success("BLOCK", param.block_id, opts)
  end

  @doc "Insert a new BLOCK parameter record and refresh ETS cache."
  @spec create_block(map(), keyword()) ::
          {:ok, BlockParameter.t()} | {:error, Ecto.Changeset.t()}
  def create_block(attrs, opts \\ []) do
    %BlockParameter{}
    |> BlockParameter.changeset(attrs)
    |> Repo.insert()
    |> refresh_on_success("BLOCK", Map.get(attrs, :block_id) || Map.get(attrs, "block_id"), opts)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp refresh_on_success({:ok, record} = result, level, id, opts) do
    operator_id = Keyword.get(opts, :operator_id, "system")
    Logger.info("[ParameterWriter] #{level} id=#{id} updated by operator=#{operator_id}. Refreshing ETS cache.")

    # Synchronous refresh: ETS cache is current before caller receives {:ok, record}
    ParameterEngine.refresh_all()

    result
  end

  defp refresh_on_success({:error, _} = error, _level, _id, _opts), do: error
end
