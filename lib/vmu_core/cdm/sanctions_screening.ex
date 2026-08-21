defmodule VmuCore.CDM.SanctionsScreening do
  @moduledoc """
  Applicant-identity sanctions screening for credit underwriting, via
  `MwRisk.SanctionsChecker.check_payload/2` — a real path dependency already
  present in `mix.exs` (`{:mw_risk, path: "../mw-core/apps/mw_risk", ...}`).
  Called directly per the `VmuCore.FAS.RiskAdapter` precedent (same-umbrella
  Elixir call, no HTTP boundary).

  `check_payload/2` takes an explicit `sanction_configs` list
  (`%{multipart_data_field: field, distance: d}`) rather than relying on its
  transaction-shaped fallback field list — this is what makes it usable here
  even though `docs/cdm/CDM_MwRisk_Sanctions_Integration_Contract.md` (written
  2026-07-11, before this arity existed) assumed a purpose-built
  `screen_applicant/1` would need to be added on the mw_risk side. It never
  was; the generic `check_payload/2` already covers the need.

  Deliberately fail-**CLOSED**, the opposite of `RiskAdapter`'s fail-open
  posture: an application approved because the sanctions check couldn't
  complete is a credit line issued to a potentially-sanctioned applicant with
  no screening ever having run — worse than delaying one transaction. See the
  contract doc §3.2. Callers must route `:error` to REFERRED, never treat it
  as clear.
  """

  require Logger

  # CDM's context (credit-application underwriting) has no card-present
  # latency SLA the way FAS's authorization hot path does — a few seconds is
  # fine here, so this deliberately does NOT reuse RiskAdapter's 500ms budget.
  # Measured live, 2026-07-23, against the real 76k-entry mw_core_dev
  # sanctions list (`check_payload/2`'s indexed Levenshtein multipart scan):
  # ~1.3-1.6s per screen. 500ms — copied from FAS's budget without checking
  # this — timed out on every single real call, silently routing every
  # application to REFERRED regardless of actual sanctions status. 5000ms
  # gives ~3x headroom over the measured real-data latency.
  @timeout_ms 5_000
  @default_distance 2

  @type hit :: %{matched_name: String.t(), list_type: String.t()}

  @doc """
  Screen an applicant's identity against the sanctions list cache.
  `identity` is `%{full_name: String.t() | nil, company_name: String.t() | nil}`.

  Returns `:clear`, `{:hit, hit()}`, or `:error` (screening could not
  complete within budget, or mw_risk is unavailable/raised).
  """
  @spec screen(%{optional(:full_name) => String.t() | nil, optional(:company_name) => String.t() | nil}) ::
          :clear | {:hit, hit()} | :error
  def screen(identity) do
    if blank?(identity[:full_name]) and blank?(identity[:company_name]) do
      :clear
    else
      task = Task.async(fn -> run_check(identity) end)

      case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        nil ->
          Logger.warning("[CDM] SanctionsScreening timed out after #{@timeout_ms}ms")
          :error
      end
    end
  rescue
    e ->
      Logger.warning("[CDM] SanctionsScreening unavailable (#{inspect(e)})")
      :error
  end

  defp run_check(identity) do
    payload = %{
      "full_name" => identity[:full_name],
      "company_name" => identity[:company_name]
    }

    configs =
      [
        not blank?(identity[:full_name]) &&
          %{multipart_data_field: "full_name", distance: @default_distance},
        not blank?(identity[:company_name]) &&
          %{multipart_data_field: "company_name", distance: @default_distance}
      ]
      |> Enum.filter(& &1)

    case MwRisk.SanctionsChecker.check_payload(payload, configs) do
      {:hit, matched_name, list_type} -> {:hit, %{matched_name: matched_name, list_type: list_type}}
      :clear -> :clear
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
