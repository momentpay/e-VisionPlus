defmodule VmuCore.FAS.RiskAdapter do
  @moduledoc """
  Bridges FAS authorization context into `MwRisk.Pipeline.run/2`.

  Per FAS-P2 task 2A (docs/fas/FAS_Implementation_Tracker.md — not to be
  confused with mw-core's own ADR-001 on Jube state categories) this is a
  direct, same-umbrella Elixir call, not an HTTP API — `mw_risk` is already
  a path dependency in `mix.exs` and `MwRisk.Pipeline.run/2` is
  already fail-safe internally (any scoring error returns a passthrough
  `:approve`), so `evaluate/1` only needs to guard against `mw_risk` being
  unreachable as an OTP application (not started, or the call itself
  raising/timing out) — that case is mapped to the same passthrough shape
  so the caller never has to special-case "risk engine down" vs.
  "risk engine scored and approved".

  Tenant scoping uses `sys_id` (the top-level SYS institution in vMu's
  parameter cascade) as `MwKernel.Context.tenant_id`, since risk activation
  rules are configured per institution, not per logo/BIN.
  """

  require Logger

  alias MwKernel.{Context, Message}

  @type result :: %{
          decision: :approve | :review | :decline,
          score: float(),
          fired_rules: [String.t()],
          model_version: String.t()
        }

  # mw_risk's per-tenant ETS caches (RuleCache, SuppressionsCache,
  # ReferenceDataCache, AdaptationCache, ML.ModelServer) lazily load from
  # Postgres on first access per tenant/model — confirmed ~1.5-1.8s on a cold
  # cache vs. 1-5ms once warm. 500ms absorbs that one-time cold-start cost
  # (only the very first transaction per tenant after boot pays it) while
  # staying well inside typical card-auth response SLAs (seconds, not ms).
  @timeout_ms 500

  @doc """
  Pre-warms mw_risk's per-tenant ETS caches (RuleCache, SuppressionsCache,
  ReferenceDataCache, AbstractionRuleCache, AdaptationCache) for every tenant
  in `:mw_risk_tenant_ids` so the *first* live authorization doesn't pay the
  ~2s cold-load cost and fall through to passthrough — call once from
  `VmuCore.Application.start/2` after mw_risk's own supervision tree is up.

  Crucially this also has to give `InfraFeatureStore.RedisTier`'s `:fuse`
  circuit breaker a chance to blow once, up front, if Redis isn't reachable.
  `FeatureHydrator` only attempts a Redis round-trip per *entity* key (card,
  merchant, card_bin, ...) found in the payload, so a warm-up call with no
  card/merchant fields touches zero entity keys and never exercises Redis at
  all — the fuse stays closed, and every later `evaluate/1` call re-pays the
  failed-connection cost from scratch inside its 500ms budget, gets
  brutal-killed mid-loop before the fuse threshold is reached, and never
  recovers. Using a placeholder card/merchant here lets that one-time
  failure (and fuse-blow) happen on an unbounded, untimed call instead.

  Runs synchronously and swallows errors: a failed warm-up just means the
  first live request pays the cold cost instead (still safe, just slower).
  """
  @spec warm_cache() :: :ok
  def warm_cache do
    overrides = Application.get_env(:vmu_core, :mw_risk_tenant_ids, %{})

    for {sys_id, tenant_id} <- overrides do
      try do
        run_pipeline(%{
          rrn: "warmup",
          stan: "warmup",
          amount: 0.0,
          currency: "USD",
          sys_id: sys_id,
          pan: "0000000000000000",
          merchant_id: "WARMUP",
          terminal_id: "WARMUP",
          mcc: "0000",
          mti: nil
        })

        Logger.info("[FAS] RiskAdapter cache warmed for sys_id=#{sys_id} tenant_id=#{tenant_id}")
      rescue
        e -> Logger.warning("[FAS] RiskAdapter cache warm-up failed for sys_id=#{sys_id}: #{inspect(e)}")
      end
    end

    :ok
  end

  @doc """
  Evaluate the FAS authorization context for fraud/AML risk.

  Always returns `{:ok, result}` — never `{:error, _}` — because mw_risk
  unavailability must fall through to STIP-style passthrough approval, not
  block or hard-decline the transaction (FAS-P2 task 2E).
  """
  @spec evaluate(map()) :: {:ok, result()}
  def evaluate(ctx) do
    task = Task.async(fn -> run_pipeline(ctx) end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        {:ok, result}

      nil ->
        Logger.warning("[FAS] RiskAdapter timed out after #{@timeout_ms}ms — passthrough approve")
        {:ok, passthrough()}
    end
  rescue
    e ->
      Logger.warning("[FAS] RiskAdapter unavailable (#{inspect(e)}) — passthrough approve")
      {:ok, passthrough()}
  end

  defp run_pipeline(ctx) do
    message = Message.new(:"fas.authorization", to_payload(ctx), :vmu_core_fas)

    mw_ctx = %Context{
      trace_id: ctx[:rrn] || ctx[:stan],
      tenant_id: resolve_tenant_id(ctx.sys_id),
      request: message
    }

    t0 = System.monotonic_time()
    {:ok, scoring} = MwRisk.Pipeline.run(mw_ctx)
    VmuCore.FAS.Telemetry.execute_risk_call(System.monotonic_time() - t0, scoring.decision)

    %{
      decision: scoring.decision,
      score: scoring.score,
      fired_rules: scoring.fired_rules,
      model_version: scoring.model_version
    }
  end

  @doc """
  Maps a vMu `sys_id` (4-char alpha code, e.g. "MMPD") to the integer
  `tenant_id` mw_risk's RuleCache/SuppressionsCache/ActivationWatcher expect.

  mw_risk's tenant scoping is numeric-only — `MwRisk.ScoringPipeline`'s
  `tenant_id_int/1` calls `Integer.parse/1` on string tenant_ids, which
  returns 0 for any non-numeric string. Since every alpha `sys_id` would
  otherwise collapse to the same tenant_id 0 (breaking multi-tenant rule
  isolation), explicit mappings should be configured per `sys_id`:

      config :vmu_core, :mw_risk_tenant_ids, %{"MMPD" => 1, "MMRW" => 2}

  Unmapped `sys_id`s fall back to a deterministic CRC32-derived id so they
  still get *a* stable, isolated tenant bucket rather than silently sharing
  tenant 0 — but production sys_ids should be added to the explicit map.
  """
  @spec resolve_tenant_id(String.t()) :: integer()
  def resolve_tenant_id(sys_id) do
    overrides = Application.get_env(:vmu_core, :mw_risk_tenant_ids, %{})
    Map.get(overrides, sys_id) || rem(:erlang.crc32(sys_id), 2_147_483_000)
  end

  defp to_payload(ctx) do
    %{
      "amount" => ctx.amount,
      "currency" => ctx.currency,
      "from_account" => ctx[:pan],
      "to_account" => ctx[:merchant_id],
      "merchant_id" => ctx[:merchant_id],
      "device_id" => ctx[:terminal_id],
      "mcc" => ctx[:mcc],
      "tx_type" => ctx[:mti]
    }
  end

  defp passthrough do
    %{decision: :approve, score: 0.0, fired_rules: [], model_version: "passthrough"}
  end
end
