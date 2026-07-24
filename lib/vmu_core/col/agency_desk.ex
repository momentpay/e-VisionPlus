defmodule VmuCore.COL.AgencyDesk do
  @moduledoc """
  Agency placement lifecycle + file exchange (COL-P4, FR-COL-018/019).

  ## `col.agency_config` shape

  Keyed by agency code, per bank (scope `:bank`):

      %{
        "AGENCY1" => %{
          "file_format"      => "CSV" | "JSON" | "XML",
          "commission_type"  => "flat_percent" | "fixed_fee" | "tiered_percent",
          "commission_value" =>
            2.0                                              # flat_percent / fixed_fee
            | [%{"upto" => 1000, "percent" => 1.0},           # tiered_percent: first tier
               %{"upto" => nil,  "percent" => 2.0}]           # whose "upto" >= amount wins;
                                                               # "upto" => nil means uncapped

          # Field mapper (FR-COL-018/019 follow-up, 2026-07-24) — agency file
          # layouts genuinely vary by region/agency; a fixed CSV/JSON schema per
          # agency was the wrong long-term shape. All four keys below are
          # optional — absent means identity (this repo's own field
          # names/ISO-8601 dates), so an agency that already sends our shape
          # needs none of this.
          "import_mapping"     => %{"AcctNo" => "account_id", "Type" => "activity_type",
                                     "PmtAmt" => "amount", "Date" => "activity_date"},
          # Agency's own header name => our canonical field name (CSV header row
          # or JSON object key). Any header not listed passes through unchanged
          # (so an agency can rename just the columns that actually differ).
          "activity_type_map"  => %{"PYMT" => "PAYMENT", "CALL" => "CONTACT", "PTP" => "PROMISE"},
          # Agency's own activity_type vocabulary => ours
          # (VmuCore.COL.AgencyActivity.activity_types/0). Applied after
          # import_mapping resolves which column IS the activity type.
          "date_format"        => "%m/%d/%Y",
          # strptime-style %Y/%m/%d date format for parsing "activity_date" (and
          # generation, symmetrically). Absent => ISO-8601 (yyyy-mm-dd).
          "export_mapping"     => %{"account_id" => "AcctNo", "last_four" => "Last4",
                                     "outstanding" => "Balance", "placed_at" => "PlacedDate"}
          # Our canonical field name => the agency's desired header/tag name,
          # for `generate_assignment_file/3` (CSV header row / JSON object key /
          # XML tag name). Column/field ORDER stays our canonical order
          # regardless of mapping — only the label changes.
        }
      }

  ## Real vs. stubbed (honest split, same posture as DPS-P3)

  - **Real**: placement/recall lifecycle, assignment-file *generation* in all three
    formats, activity-file *parsing* for CSV/JSON, applying PAYMENT (COL-P8: via
    `CMS.PaymentIntake.receive_payment/1`, the same single entry point every other
    payment channel uses — it already routes `WRITTEN_OFF` accounts to
    `ChargeOffRecovery` internally, and runs the full balance-bucket waterfall for
    everyone else) / PROMISE (via `VmuCore.COL.PromiseVerification.log_promise/3`)
    / CONTACT (via `ContactHistory.record_call/3`) activities, and commission
    calculation.
  - **Stubbed**: assignment-file *delivery* (`deliver_assignment_file/3` — no
    SFTP/vendor client exists in this project) and activity-file parsing for XML
    (no vendor sample to validate a real parser against — CSV/JSON cover the
    common cases).

  Requires the bank to have `"agency"` in its `payment_channels_enabled` parameter
  (same validation gate every other channel goes through — not bypassed just
  because the source is an agency) or `PAYMENT` activities are rejected with
  `{:channel_not_enabled, "agency"}`.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{COL.CollectionCase, COL.AgencyPlacement, COL.AgencyActivity}
  alias VmuCore.COL.{ContactHistory, DisputeExclusion, PromiseVerification}
  alias VmuCore.Shared.ModuleConfigEngine
  alias Decimal, as: D

  # M2 (2026-07-17): config-injected — CMS isn't extracted yet. The
  # %Account{sys_id:, bank_id:} pattern in fetch_agency_config/2 below is
  # rewritten as a bare %{field: val} map pattern — see vmu_hcs's fix.
  @repo Application.compile_env(:vmu_col, :repo, VmuCore.Repo)
  @account_schema Application.compile_env(:vmu_col, :cms_account_schema, VmuCore.CMS.Account)
  @payment_intake Application.compile_env(:vmu_col, :cms_payment_intake, VmuCore.CMS.PaymentIntake)

  # ---------------------------------------------------------------------------
  # Placement lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Place a case with an agency. Validates the agency code exists in the
  account's bank-scoped `agency_config`. Updates the case to status `AGENCY`.

  COL-P7: refuses to place an account that has an open DPS dispute
  (`VmuCore.COL.DisputeExclusion`) — returns `{:error, :open_dispute_exists}`.
  """
  @spec place(Ecto.UUID.t(), String.t()) :: {:ok, AgencyPlacement.t()} | {:error, term()}
  def place(case_id, agency_code) do
    case @repo.get(CollectionCase, case_id) do
      nil ->
        {:error, :case_not_found}

      %CollectionCase{} = case_row ->
        account = @repo.get!(@account_schema, case_row.account_id)

        with false <- open_dispute_error(case_row.account_id),
             {:ok, _agency_cfg} <- fetch_agency_config(account, agency_code) do
          attrs = %{
            case_id:       case_id,
            account_id:    case_row.account_id,
            agency_code:   agency_code,
            placed_amount: case_row.outstanding_amount,
            placed_at:     DateTime.utc_now() |> DateTime.truncate(:second)
          }

          @repo.transaction(fn ->
            placement = @repo.insert!(AgencyPlacement.changeset(%AgencyPlacement{}, attrs))

            case_row
            |> CollectionCase.changeset(%{status: "AGENCY", assigned_to: agency_code})
            |> @repo.update!()

            placement
          end)
        end
    end
  end

  @doc """
  Recall a placement (agency churn: recall from one agency, then `place/2` with
  another). Reopens the case to `OPEN` status.
  """
  @spec recall(Ecto.UUID.t(), String.t()) :: {:ok, AgencyPlacement.t()} | {:error, term()}
  def recall(placement_id, reason) do
    case @repo.get(AgencyPlacement, placement_id) do
      nil ->
        {:error, :placement_not_found}

      %AgencyPlacement{status: "PLACED"} = placement ->
        @repo.transaction(fn ->
          updated =
            placement
            |> AgencyPlacement.changeset(%{
              status: "RECALLED", recall_reason: reason,
              recalled_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })
            |> @repo.update!()

          case @repo.get(CollectionCase, placement.case_id) do
            nil -> :ok
            case_row -> case_row |> CollectionCase.changeset(%{status: "OPEN"}) |> @repo.update!()
          end

          updated
        end)

      %AgencyPlacement{status: status} ->
        {:error, {:not_placed, status}}
    end
  end

  # ---------------------------------------------------------------------------
  # Assignment file (out)
  # ---------------------------------------------------------------------------

  @doc "Generate the assignment file for all PLACED cases with `agency_code`, in its configured format."
  @spec generate_assignment_file(String.t(), String.t(), String.t()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def generate_assignment_file(agency_code, sys_id, bank_id) do
    with {:ok, agency_cfg} <- fetch_agency_config_by_ids(sys_id, bank_id, agency_code) do
      rows =
        @repo.all(
          from p in AgencyPlacement,
            join: a in @account_schema, on: a.account_id == p.account_id,
            where: p.agency_code == ^agency_code and p.status == "PLACED",
            select: %{
              account_id: p.account_id, last_four: a.last_four,
              outstanding: p.placed_amount, placed_at: p.placed_at
            }
        )

      format = Map.get(agency_cfg, "file_format", "CSV")
      export_mapping = Map.get(agency_cfg, "export_mapping", %{})
      date_format = Map.get(agency_cfg, "date_format")
      {:ok, encode_assignment_rows(rows, format, export_mapping, date_format), format}
    end
  end

  @doc "Log-only delivery stub — no SFTP/vendor client exists in this project."
  @spec deliver_assignment_file(String.t(), String.t(), String.t()) :: :ok
  def deliver_assignment_file(content, format, agency_code) do
    Logger.info("[COL/Agency] Would deliver #{format} assignment file " <>
                "(#{byte_size(content)} bytes) to agency=#{agency_code} — no vendor transport configured")
    :ok
  end

  # Canonical field order — export_mapping only ever renames labels, never
  # reorders columns/tags.
  @assignment_fields ~w[account_id last_four outstanding placed_at]a

  defp export_header(field, export_mapping), do: Map.get(export_mapping, Atom.to_string(field), Atom.to_string(field))

  defp export_value(:placed_at, r, date_format), do: format_date(r.placed_at, date_format)
  defp export_value(field, r, _date_format), do: Map.get(r, field)

  defp encode_assignment_rows(rows, "JSON", export_mapping, date_format) do
    rows
    |> Enum.map(fn r ->
      Enum.into(@assignment_fields, %{}, fn f -> {export_header(f, export_mapping), export_value(f, r, date_format)} end)
    end)
    |> Jason.encode!()
  end

  defp encode_assignment_rows(rows, "XML", export_mapping, date_format) do
    body =
      rows
      |> Enum.map(fn r ->
        @assignment_fields
        |> Enum.map(fn f ->
          tag = export_header(f, export_mapping)
          "<#{tag}>#{export_value(f, r, date_format)}</#{tag}>"
        end)
        |> Enum.join()
        |> then(&"<placement>#{&1}</placement>")
      end)
      |> Enum.join()

    "<placements>#{body}</placements>"
  end

  defp encode_assignment_rows(rows, _csv_or_other, export_mapping, date_format) do
    header = @assignment_fields |> Enum.map(&export_header(&1, export_mapping)) |> Enum.join(",")

    lines =
      Enum.map(rows, fn r ->
        @assignment_fields |> Enum.map(&export_value(&1, r, date_format)) |> Enum.join(",")
      end)

    Enum.join([header | lines], "\n")
  end

  # Symmetric with parse_date/2 below — nil/absent format keeps the
  # existing ISO-8601 (or plain to_string for a %DateTime{}) behavior.
  defp format_date(nil, _format), do: ""
  defp format_date(%Date{} = d, nil), do: Date.to_iso8601(d)
  defp format_date(%DateTime{} = d, nil), do: DateTime.to_iso8601(d)

  defp format_date(%Date{} = d, format) do
    format
    |> String.replace("%Y", String.pad_leading(to_string(d.year), 4, "0"))
    |> String.replace("%m", String.pad_leading(to_string(d.month), 2, "0"))
    |> String.replace("%d", String.pad_leading(to_string(d.day), 2, "0"))
  end

  defp format_date(%DateTime{} = d, format), do: format_date(DateTime.to_date(d), format)

  # ---------------------------------------------------------------------------
  # Activity file (in)
  # ---------------------------------------------------------------------------

  @doc """
  Import an activity/payment file for `agency_code`. Parses per the agency's
  configured `file_format` (CSV/JSON real; XML `{:error, :xml_not_implemented}`),
  persists each line as an `AgencyActivity`, and applies it. A malformed row is
  rejected individually — it never fails the whole batch.

  Returns `{:ok, %{applied: n, rejected: n}}` or `{:error, reason}` if the file
  itself can't be parsed at all.
  """
  @spec import_activity_file(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{applied: non_neg_integer(), rejected: non_neg_integer()}} | {:error, term()}
  def import_activity_file(agency_code, sys_id, bank_id, file_content) do
    with {:ok, agency_cfg} <- fetch_agency_config_by_ids(sys_id, bank_id, agency_code),
         {:ok, rows} <- parse_file(file_content, Map.get(agency_cfg, "file_format", "CSV")) do
      results = Enum.map(rows, &import_row(&1, agency_code, agency_cfg))
      applied = Enum.count(results, &(&1 == :applied))
      rejected = Enum.count(results, &(&1 == :rejected))
      {:ok, %{applied: applied, rejected: rejected}}
    end
  end

  defp parse_file(content, "JSON") do
    case Jason.decode(content) do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:ok, _not_a_list} -> {:error, :expected_json_array}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp parse_file(_content, "XML"), do: {:error, :xml_not_implemented}

  defp parse_file(content, _csv_or_other) do
    [header_line | data_lines] =
      content |> String.split(["\r\n", "\n"], trim: true)

    headers = String.split(header_line, ",")

    rows =
      Enum.map(data_lines, fn line ->
        values = String.split(line, ",")
        headers |> Enum.zip(values) |> Map.new()
      end)

    {:ok, rows}
  end

  defp import_row(row, agency_code, agency_cfg) do
    row = remap_import_row(row, agency_cfg)
    account_id = row["account_id"]
    activity_type = row["activity_type"]

    with {:ok, placement} <- active_placement(account_id, agency_code),
         :ok <- validate_row(row) do
      attrs = %{
        placement_id:  placement.id,
        activity_type: activity_type,
        amount:        parse_decimal(row["amount"]),
        activity_date: parse_date(row["activity_date"], Map.get(agency_cfg, "date_format")),
        raw_line:      row
      }

      case @repo.insert(AgencyActivity.changeset(%AgencyActivity{}, attrs)) do
        {:ok, activity} -> apply_activity(activity, placement, agency_cfg)
        {:error, _cs} -> :rejected
      end
    else
      _ -> :rejected
    end
  end

  # Field mapper (col.agency_config's import_mapping/activity_type_map) — a
  # no-op (returns row unchanged) when the agency isn't configured with a
  # mapping, so an agency that already sends our own field names/vocabulary
  # needs no config at all.
  defp remap_import_row(row, agency_cfg) do
    import_mapping = Map.get(agency_cfg, "import_mapping", %{})

    mapped =
      if import_mapping == %{} do
        row
      else
        Enum.into(row, %{}, fn {header, value} -> {Map.get(import_mapping, header, header), value} end)
      end

    activity_type_map = Map.get(agency_cfg, "activity_type_map", %{})

    case {Map.get(mapped, "activity_type"), activity_type_map} do
      {nil, _} -> mapped
      {_val, map} when map == %{} -> mapped
      {val, map} -> Map.put(mapped, "activity_type", Map.get(map, val, val))
    end
  end

  defp validate_row(row) do
    activity_type = row["activity_type"]

    cond do
      is_nil(row["account_id"]) or row["account_id"] == "" ->
        {:error, :missing_account_id}

      activity_type not in AgencyActivity.activity_types() ->
        {:error, :invalid_activity_type}

      activity_type == "PAYMENT" and parse_decimal(row["amount"]) == nil ->
        {:error, :missing_amount}

      true ->
        :ok
    end
  end

  defp active_placement(account_id, agency_code) do
    case @repo.one(
           from p in AgencyPlacement,
             where: p.account_id == ^account_id and p.agency_code == ^agency_code and p.status == "PLACED",
             limit: 1
         ) do
      nil -> {:error, :no_active_placement}
      placement -> {:ok, placement}
    end
  end

  defp apply_activity(%AgencyActivity{activity_type: "PAYMENT"} = activity, placement, agency_cfg) do
    ref = "AGENCY-#{placement.agency_code}-#{activity.id}"

    # PaymentIntake.receive_payment/1 is the single entry point for both cases:
    # it already routes WRITTEN_OFF accounts to ChargeOffRecovery internally
    # (CMS-G4.3) and runs the full balance-bucket waterfall + GL + OTB restore
    # for everyone else. COL-P8: this used to special-case WRITTEN_OFF here and
    # leave non-written-off payments "recorded_only" (not posted) — now both
    # paths post for real through the one real payment pipeline. Requires the
    # bank to have "agency" in its `payment_channels_enabled` parameter, same as
    # any other channel — not bypassed just because the source is an agency.
    case @payment_intake.receive_payment(%{
           account_id: placement.account_id, amount: activity.amount,
           channel: "agency", reference: ref
         }) do
      {:ok, _result} ->
        commission = compute_commission(agency_cfg, activity.amount)

        activity
        |> AgencyActivity.changeset(%{status: "APPLIED", commission_amount: commission})
        |> @repo.update!()

        :applied

      {:error, reason} ->
        activity
        |> AgencyActivity.changeset(%{status: "REJECTED", reject_reason: inspect(reason)})
        |> @repo.update!()

        :rejected
    end
  end

  defp apply_activity(%AgencyActivity{activity_type: "PROMISE"} = activity, placement, _cfg) do
    case PromiseVerification.log_promise(placement.case_id, activity.amount, activity.activity_date) do
      {:error, _} ->
        :rejected

      {:ok, _case_row} ->
        activity |> AgencyActivity.changeset(%{status: "APPLIED"}) |> @repo.update!()
        :applied
    end
  end

  defp apply_activity(%AgencyActivity{activity_type: "CONTACT"} = activity, placement, _cfg) do
    outcome = activity.raw_line["outcome"] || "logged"

    ContactHistory.record_call(placement.account_id, outcome,
      notes: activity.raw_line["notes"], attempted_by: "AGENCY:#{placement.agency_code}")

    activity |> AgencyActivity.changeset(%{status: "APPLIED"}) |> @repo.update!()
    :applied
  end

  defp apply_activity(%AgencyActivity{} = activity, _placement, _cfg) do
    # SKIP_TRACE | DISPUTE | RECALL_REQUEST — recorded only, not auto-actioned.
    # A RECALL_REQUEST is a business decision for an operator, not an automatic
    # trigger (see docs/col tracker for why recall isn't auto-executed here).
    activity |> AgencyActivity.changeset(%{status: "APPLIED"}) |> @repo.update!()
    :applied
  end

  # ---------------------------------------------------------------------------
  # Commission
  # ---------------------------------------------------------------------------

  @doc "Total commission owed to `agency_code` for APPLIED PAYMENT activities."
  @spec commission_due(String.t()) :: Decimal.t()
  def commission_due(agency_code) do
    @repo.one(
      from act in AgencyActivity,
        join: p in AgencyPlacement, on: p.id == act.placement_id,
        where: p.agency_code == ^agency_code and act.activity_type == "PAYMENT" and act.status == "APPLIED",
        select: coalesce(sum(act.commission_amount), 0)
    ) || D.new(0)
  end

  defp compute_commission(%{"commission_type" => "flat_percent", "commission_value" => pct}, amount) do
    D.mult(amount, D.div(D.new(to_string(pct)), D.new(100)))
  end

  defp compute_commission(%{"commission_type" => "fixed_fee", "commission_value" => fee}, _amount) do
    D.new(to_string(fee))
  end

  defp compute_commission(%{"commission_type" => "tiered_percent", "commission_value" => tiers}, amount)
       when is_list(tiers) do
    tier =
      Enum.find(tiers, List.last(tiers), fn t ->
        upto = t["upto"]
        is_nil(upto) or D.compare(amount, D.new(to_string(upto))) != :gt
      end)

    D.mult(amount, D.div(D.new(to_string(tier["percent"])), D.new(100)))
  end

  defp compute_commission(_cfg, _amount), do: D.new(0)

  # ---------------------------------------------------------------------------
  # Config helpers
  # ---------------------------------------------------------------------------

  defp open_dispute_error(account_id) do
    if DisputeExclusion.open_dispute?(account_id) do
      {:error, :open_dispute_exists}
    else
      false
    end
  end

  defp fetch_agency_config(%{sys_id: sys_id, bank_id: bank_id}, agency_code) do
    fetch_agency_config_by_ids(sys_id, bank_id, agency_code)
  end

  defp fetch_agency_config_by_ids(sys_id, bank_id, agency_code) do
    {:ok, config} = ModuleConfigEngine.get("col", "agency_config", sys_id, bank_id)

    case Map.get(config, agency_code) do
      nil -> {:error, :agency_not_configured}
      agency_cfg -> {:ok, agency_cfg}
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil
  defp parse_decimal(%Decimal{} = d), do: d

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {d, _rest} -> d
      :error -> nil
    end
  end

  defp parse_decimal(value) when is_number(value), do: D.new(to_string(value))

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil
  defp parse_date(%Date{} = d), do: d

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, d} -> d
      {:error, _} -> nil
    end
  end

  # date_format-aware variant — used for activity_date on import. nil/absent
  # format falls back to the plain ISO-8601 parse above.
  defp parse_date(value, nil), do: parse_date(value)
  defp parse_date(value, ""), do: parse_date(value)
  defp parse_date(nil, _format), do: nil
  defp parse_date("", _format), do: nil

  defp parse_date(value, format) when is_binary(value) and is_binary(format) do
    case parse_with_format(value, format) do
      {:ok, date} -> date
      :error -> parse_date(value)
    end
  end

  defp parse_with_format(value, format) do
    pattern =
      format
      |> String.replace("%Y", "(?<year>\\d{4})")
      |> String.replace("%m", "(?<month>\\d{1,2})")
      |> String.replace("%d", "(?<day>\\d{1,2})")

    with {:ok, regex} <- Regex.compile("^" <> pattern <> "$"),
         %{"year" => y, "month" => m, "day" => d} <- Regex.named_captures(regex, value),
         {:ok, date} <- Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
      {:ok, date}
    else
      _ -> :error
    end
  end
end
