defmodule VmuCoreWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Emits VmuCore-specific measurements every 10 seconds
      {:telemetry_poller,
       measurements: periodic_measurements(),
       period: 10_000,
       name: :vmu_core_poller}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Metrics surfaced on the LiveDashboard /dashboard page
  def metrics do
    [
      # --- FAS authorization metrics (FAS-P8 8A) ---
    ] ++ VmuCore.FAS.Telemetry.metrics() ++ [
      # --- TRAM lifecycle metrics (TRAM-P6 6F) ---
    ] ++ VmuCore.TRAMS.Telemetry.metrics() ++ [
      # --- Ecto repo ---
      summary("vmu_core.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "Total query time including queue wait"),
      summary("vmu_core.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "Time spent executing the query"),
      summary("vmu_core.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "Time spent decoding result rows"),
      counter("vmu_core.repo.query.count",
        description: "Total queries executed"),

      # --- Phoenix endpoint (admin UI itself) ---
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        description: "Admin request duration"),

      # --- VM health ---
      last_value("vm.memory.total",        unit: {:byte, :megabyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.system_counts.process_count"),

      # --- ParameterEngine ETS cache ---
      last_value("vmu_core.parameter_engine.cache_size",
        description: "Number of entries in the ETS parameter cache")
    ]
  end

  defp periodic_measurements do
    [
      # Emit ParameterEngine cache size as a telemetry event
      {__MODULE__, :emit_parameter_engine_stats, []},
      # Emit FAS hold aging count every polling cycle
      {__MODULE__, :emit_fas_hold_aging, []}
    ]
  end

  def emit_fas_hold_aging do
    try do
      import Ecto.Query
      alias VmuCore.{Repo, FAS.PendingHold}

      cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)

      {count, oldest} =
        from(h in PendingHold,
          where: is_nil(h.cleared_at) and is_nil(h.reversal_at) and h.expires_at < ^cutoff,
          select: {count(h.id), min(h.expires_at)}
        )
        |> Repo.one()

      oldest_mins =
        case oldest do
          nil -> 0
          ts  -> div(DateTime.diff(DateTime.utc_now(), ts, :second), 60)
        end

      VmuCore.FAS.Telemetry.execute_hold_aging(count || 0, oldest_mins)
    rescue
      _ -> :ok
    end
  end

  def emit_parameter_engine_stats do
    size =
      try do
        VmuCore.Shared.ParameterEngine.cache_size()
      rescue
        _ -> 0
      end

    :telemetry.execute(
      [:vmu_core, :parameter_engine],
      %{cache_size: size},
      %{}
    )
  end
end
