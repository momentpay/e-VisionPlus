defmodule VmuCore.ASM.Oban.AuditRetentionSweepJob do
  @moduledoc """
  Operator audit trail retention sweep — wires `asm.audit_retention_days`
  (Module Configuration Framework) into real behavior; previously this config
  key had no consumer at all (no purge/archival job existed for
  `cms_operator_audit`).

  Weekly cron (Sunday 03:00, after the TRAMS archive sweep at 02:00): deletes
  `cms_operator_audit` rows older than the configured retention window
  (default 2555 days = 7 years).

  `cms_operator_audit` has no `sys_id` column — it is a single global audit
  trail, not partitioned per tenant. If multiple SYS records configure
  different retention periods, the sweep uses the LONGEST configured value
  system-wide as the cutoff, so a row is never purged before every configured
  tenant's retention requirement is satisfied.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.Shared.{SysParameter, ModuleConfigEngine}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    retention_days = effective_retention_days()
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-retention_days * 86_400, :second)

    {deleted, _} =
      Repo.delete_all(from a in "cms_operator_audit", where: a.performed_at < ^cutoff)

    Logger.info("[ASM.AuditRetentionSweep] retention_days=#{retention_days} deleted=#{deleted}")
    :ok
  end

  defp effective_retention_days do
    case Repo.all(SysParameter) do
      [] ->
        2555

      sys_params ->
        sys_params
        |> Enum.map(fn %SysParameter{sys_id: sys_id} ->
          {:ok, days} = ModuleConfigEngine.get("asm", "audit_retention_days", sys_id)
          days
        end)
        |> Enum.max()
    end
  end
end
