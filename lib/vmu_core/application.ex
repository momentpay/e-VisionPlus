defmodule VmuCore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # 1. Database connection pool — must start first
      VmuCore.Repo,
      # 2. ETS-backed Parameter Engine — loads SYS/BANK/LOGO/BLOCK from DB into memory.
      #    All downstream modules (FAS switch, CMS, risk engine) read from ETS directly.
      VmuCore.Shared.ParameterEngine,
      # 3. Horde distributed registry — per-account GenServer lookup across cluster nodes
      {Horde.Registry,
       [name: VmuCore.Shared.Registry, keys: :unique, members: :auto]},
      # 4. Horde dynamic supervisor — starts/restarts per-account AccountStateCoordinator processes
      {Horde.DynamicSupervisor,
       [name: VmuCore.Shared.AccountSupervisor, strategy: :one_for_one, members: :auto]},
      # 5. Oban — background job queue for EOD, CTA, DPS, TRAMS, COL workflows
      {Oban, Application.fetch_env!(:vmu_core, Oban)}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: VmuCore.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Initialise STIP ETS cache and load thresholds from DB after supervisor is up
    VmuCore.FAS.STIP.init_cache()
    VmuCore.FAS.STIP.load_thresholds(VmuCore.Repo)

    result
  end
end
