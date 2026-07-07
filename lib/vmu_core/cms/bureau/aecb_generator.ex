defmodule VmuCore.CMS.Bureau.AecbGenerator do
  @moduledoc """
  AECB (Al Etihad Credit Bureau, UAE) provider-file generator (CMS-G5.2).

  AECB's Data Standards Manual is portal-gated (no public technical spec —
  confirmed 2026-07-05), so this generator renders a **delimited
  header/data/trailer skeleton whose entire column set is configuration**
  (`FormatSpec.spec("AECB")` — see its moduledoc). When the official manual
  is available, the real columns drop into `:bureau_format_overrides`
  without touching this module.
  """

  require Logger

  alias VmuCore.CMS.Bureau.{FormatSpec, ReportingData}

  @doc """
  Generate the AECB provider file for a product.

  Returns `{:ok, %{format:, content:, records:, generated_at:}}`.
  """
  @spec generate(String.t(), String.t(), String.t(), keyword()) :: {:ok, map()}
  def generate(sys_id, bank_id, logo_id, opts \\ []) do
    spec  = FormatSpec.spec("AECB")
    as_of = Keyword.get(opts, :as_of, Date.utc_today())
    rows  = ReportingData.rows(sys_id, bank_id, logo_id)
    ctx   = %{as_of: as_of, record_count: length(rows)}

    if spec.provider_code == "PROVIDER_UNSET" do
      Logger.warning("[Aecb] provider_code not configured — set it via " <>
                     ":bureau_format_overrides before production submission")
    end

    header  = render_line(spec.header_fields, nil, spec, ctx)
    details = Enum.map(rows, &render_line(spec.account_fields, &1, spec, ctx))
    trailer = render_line(spec.trailer_fields, nil, spec, ctx)

    content = Enum.join([header | details] ++ [trailer], "\n")

    {:ok, %{format: "AECB", content: content, records: length(rows),
            generated_at: DateTime.utc_now()}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp render_line(fields, row, spec, ctx) do
    fields
    |> Enum.map(fn source -> resolve_value(source, row, spec, ctx) end)
    |> Enum.join(spec.delimiter)
  end

  # record_count is line-level context, not row data
  defp resolve_value({:computed, :record_count}, _row, _spec, ctx),
    do: Integer.to_string(ctx.record_count)

  defp resolve_value(source, row, spec, ctx) do
    source
    |> ReportingData.resolve(row || %{account: %{}, customer: %{}, bucket: nil}, ctx)
    |> ReportingData.to_text(spec.date_format)
    |> escape_delimiter(spec.delimiter)
  end

  defp escape_delimiter(text, delimiter),
    do: String.replace(text, delimiter, " ")
end
