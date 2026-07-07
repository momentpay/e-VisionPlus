defmodule VmuCore.CMS.BureauFormatRouter do
  @moduledoc """
  Per-market bureau format dispatch (CMS-G1 G1.6, ADR-C5).

  The reviewed answer maps each market to its bureau format via the
  BANK-level `credit_reporting_format` parameter:

      US  → "Metro2"          (implemented — Metro2Generator)
      IN  → "CIBIL_local"     (stub until CIBIL TUDF spec is sourced)
      UAE → "AlEtihad_local"  (stub until AECB spec is sourced)

  Callers use `generate_and_submit/3` instead of calling `Metro2Generator`
  directly — the format decision then lives entirely in parameters, and
  adding a market is a new generator module + one router clause (CMS-G5.2).
  """

  require Logger

  alias VmuCore.CMS.Metro2Generator
  alias VmuCore.CMS.Bureau.{CibilTudfGenerator, AecbGenerator}
  alias VmuCore.Shared.ParameterEngine

  @doc """
  Generate + submit the bureau extract for a product using the BANK's
  configured format.

  Local formats (CMS-G5.2) return `{:ok, %{content:, format:, ...}}` —
  submission transport for those is bank-specific (SFTP/portal) and lives
  with the caller; only Metro2 has an integrated submit path today.
  """
  @spec generate_and_submit(String.t(), String.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def generate_and_submit(sys_id, bank_id, logo_id) do
    format = reporting_format(sys_id, bank_id, logo_id)

    case format do
      "Metro2" ->
        Metro2Generator.generate_and_submit(sys_id, bank_id, logo_id)

      "CIBIL_local" ->
        CibilTudfGenerator.generate(sys_id, bank_id, logo_id)

      "AlEtihad_local" ->
        AecbGenerator.generate(sys_id, bank_id, logo_id)

      other ->
        Logger.error("[BureauFormatRouter] Unknown credit_reporting_format " <>
                     "#{inspect(other)} for #{sys_id}/#{bank_id}")
        {:error, {:unknown_format, other}}
    end
  end

  @doc "Resolved reporting format for a product (BANK-level parameter, default Metro2)."
  @spec reporting_format(String.t(), String.t(), String.t()) :: String.t()
  def reporting_format(sys_id, bank_id, logo_id) do
    case ParameterEngine.get(sys_id, bank_id, logo_id, "", :credit_reporting_format) do
      {:ok, fmt} when is_binary(fmt) and fmt != "" -> fmt
      _ -> "Metro2"
    end
  end
end
