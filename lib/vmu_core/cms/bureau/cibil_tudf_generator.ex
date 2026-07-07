defmodule VmuCore.CMS.Bureau.CibilTudfGenerator do
  @moduledoc """
  CIBIL TUDF / UCRF consumer submission generator (CMS-G5.2, IN market).

  Layout comes entirely from `FormatSpec.spec("CIBIL_TUDF")` — publicly
  documented structure with config-overridable field maps (see FormatSpec
  moduledoc for the validation warning and override mechanism).

  File shape:

      TUDF<version><member_id…>          fixed header
      PN…ID…PT…PA…TL…                    per subject (tag-length-value fields)
      ES…                                 end of subject
      …repeat per subject…
      TRLR<subject_count>                 trailer
  """

  require Logger

  alias VmuCore.CMS.Bureau.{FormatSpec, ReportingData}

  @doc """
  Generate the TUDF submission for a product.

  Returns `{:ok, %{format:, content:, subjects:, generated_at:}}` —
  transport/submission is the caller's concern (bank-specific delivery).
  """
  @spec generate(String.t(), String.t(), String.t(), keyword()) :: {:ok, map()}
  def generate(sys_id, bank_id, logo_id, opts \\ []) do
    spec  = FormatSpec.spec("CIBIL_TUDF")
    as_of = Keyword.get(opts, :as_of, Date.utc_today())
    ctx   = %{as_of: as_of}
    rows  = ReportingData.rows(sys_id, bank_id, logo_id)

    if spec.member_id == "MEMBER_ID_UNSET" do
      Logger.warning("[CibilTudf] member_id not configured — set it via " <>
                     ":bureau_format_overrides before production submission")
    end

    subjects = Enum.map(rows, &subject_block(&1, spec, ctx))

    content =
      [header(spec, ctx), subjects, trailer(length(rows))]
      |> List.flatten()
      |> Enum.join("\n")

    {:ok, %{format: "CIBIL_TUDF", content: content, subjects: length(rows),
            generated_at: DateTime.utc_now()}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Fixed header: TUDF + version(2) + member_id(30) + processing date(8)
  defp header(spec, ctx) do
    "TUDF" <>
      ReportingData.fixed(spec.version, 2, :right, "0") <>
      ReportingData.fixed(spec.member_id, 30) <>
      ReportingData.to_text(ctx.as_of, spec.date_format)
  end

  defp trailer(count) do
    "TRLR" <> ReportingData.fixed(Integer.to_string(count), 9, :right, "0")
  end

  defp subject_block(row, spec, ctx) do
    segment_order = ~w[PN ID PT PA TL]

    segments =
      segment_order
      |> Enum.map(fn seg_id ->
        case render_segment(seg_id, Map.get(spec.segments, seg_id, []), row, spec, ctx) do
          "" -> nil
          rendered -> rendered
        end
      end)
      |> Enum.reject(&is_nil/1)

    segments ++ ["ES"]
  end

  # Variable segment: id + tag(2)len(2)value per populated field.
  # Empty segment (no populated fields) renders as "" and is dropped.
  defp render_segment(seg_id, fields, row, spec, ctx) do
    rendered_fields =
      fields
      |> Enum.map(fn %{tag: tag, source: source, max: max} ->
        value =
          source
          |> ReportingData.resolve(row, ctx)
          |> ReportingData.to_text(spec.date_format)
          |> String.slice(0, max)

        if value == "" do
          nil
        else
          tag <> ReportingData.fixed(Integer.to_string(String.length(value)), 2, :right, "0") <> value
        end
      end)
      |> Enum.reject(&is_nil/1)

    case rendered_fields do
      [] -> ""
      list -> seg_id <> Enum.join(list)
    end
  end
end
