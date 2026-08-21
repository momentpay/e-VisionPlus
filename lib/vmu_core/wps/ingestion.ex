defmodule VmuCore.WPS.Ingestion do
  @moduledoc """
  Ingests an employer's salary file (W2).

  ```
  ingest(employer_id, filename, raw_bytes, uploaded_by: "ops1")
    -> {:ok, %WpsFile{}, %{parsed: n, errors: m}}
  ```

  Parsing and persistence only. **Nothing is disbursed here** — that is W3,
  behind a pre-flight report an operator approves. Keeping the two apart is
  what makes it safe to ingest a file in order to look at it.

  ## Duplicate files

  Guarded on the SHA-256 of the raw bytes, per employer. A file re-sent after a
  failed transmission is byte-identical; a corrected resubmission is not. So the
  hash separates the two cases without the employer having to get a sequence
  number right, and the failure it prevents — paying an entire batch twice — is
  the worst one available.

  `wps.duplicate_file_policy` decides whether a repeat is refused (default) or
  ingested with a flag.

  ## Partial files are normal

  A file that parses 383 of 400 lines is ingested, with the 17 failures recorded
  against it. Refusing the whole file would discard 383 correct payment
  instructions over someone else's typo, and the operator would have no list of
  what to fix.
  """

  import Ecto.Query, warn: false

  require Logger

  alias VmuCore.Repo
  alias VmuCore.Shared.ModuleConfigEngine
  alias VmuCore.WPS.{Employer, FileParser, Roster, SalaryCredit, WpsFile}

  @doc """
  Parses and stores a salary file.

  Options: `:uploaded_by`.
  """
  @spec ingest(Ecto.UUID.t(), String.t(), binary(), keyword()) ::
          {:ok, WpsFile.t(), map()} | {:error, term()}
  def ingest(employer_id, filename, raw_bytes, opts \\ []) do
    with {:ok, employer} <- fetch_employer(employer_id),
         {:ok, config} <- employer_config(employer),
         hash = WpsFile.hash(raw_bytes),
         :ok <- check_duplicate(employer, hash),
         {:ok, lines, errors} <- FileParser.parse(raw_bytes, config) do
      store(employer, filename, raw_bytes, hash, config, lines, errors, opts)
    end
  end

  @doc """
  The layout configuration for an employer.

  Returns `{:error, :employer_not_configured}` when the employer has no entry —
  a deliberate refusal rather than a default. Guessing a layout is how a file
  gets parsed into the wrong columns, and the amounts are the columns that
  matter.
  """
  @spec employer_config(Employer.t()) :: {:ok, map()} | {:error, :employer_not_configured}
  def employer_config(%Employer{} = employer) do
    {:ok, all} =
      ModuleConfigEngine.get("wps", "employer_config", employer.sys_id, employer.bank_id)

    case Map.get(all || %{}, employer.employer_code) do
      nil -> {:error, :employer_not_configured}
      config -> {:ok, merge_bank_defaults(config, employer)}
    end
  end

  # Bank-level switches the parser honours but that live outside the per-employer
  # layout map, folded in so the parser takes one config and not three.
  defp merge_bank_defaults(config, employer) do
    {:ok, consistency} =
      ModuleConfigEngine.get(
        "wps",
        "require_net_equals_gross_minus_deductions",
        employer.sys_id,
        employer.bank_id
      )

    Map.put_new(config, "require_net_equals_gross_minus_deductions", consistency)
  end

  defp fetch_employer(employer_id) do
    case Roster.get_employer(employer_id) do
      nil -> {:error, :employer_not_found}
      employer -> {:ok, employer}
    end
  end

  defp check_duplicate(employer, hash) do
    exists? =
      Repo.exists?(
        from f in WpsFile,
          where: f.employer_id == ^employer.employer_id and f.content_hash == ^hash
      )

    if exists? do
      {:ok, policy} =
        ModuleConfigEngine.get(
          "wps",
          "duplicate_file_policy",
          employer.sys_id,
          employer.bank_id
        )

      case policy do
        "warn" ->
          Logger.warning(
            "[WPS] duplicate file ingested for employer=#{employer.employer_code} " <>
              "hash=#{String.slice(hash, 0, 12)} — allowed by duplicate_file_policy"
          )

          :ok

        _ ->
          {:error, :duplicate_file}
      end
    else
      :ok
    end
  end

  defp store(employer, filename, raw_bytes, hash, config, lines, errors, opts) do
    now = DateTime.utc_now()

    total_net =
      Enum.reduce(lines, Decimal.new(0), fn line, acc -> Decimal.add(acc, line.net_amount) end)

    file_attrs = %{
      employer_id: employer.employer_id,
      filename: filename,
      content_hash: hash,
      byte_size: byte_size(raw_bytes),
      file_format: Map.get(config, "file_format", "CSV"),
      # A snapshot, not a reference: layout config changes, and an operator
      # investigating this file later needs to know how it *was* parsed.
      layout_snapshot: config,
      status: "PARSED",
      line_count: length(lines) + count_error_lines(errors),
      parsed_count: length(lines),
      error_count: length(errors),
      total_net_amount: total_net,
      currency: lines |> List.first() |> then(&(&1 && &1.currency)),
      # String keys explicitly. These round-trip through a jsonb column, which
      # stringifies keys — so storing atom keys would make `parse_errors/1`
      # return a different shape depending on whether the caller held the
      # in-memory struct or reloaded it.
      parse_errors: %{"errors" => Enum.map(errors, &stringify_keys/1)},
      uploaded_by: Keyword.get(opts, :uploaded_by),
      ingested_at: now
    }

    Repo.transaction(fn ->
      case %WpsFile{} |> WpsFile.changeset(file_attrs) |> Repo.insert() do
        {:error, changeset} ->
          Repo.rollback(changeset)

        {:ok, file} ->
          case insert_credits(file, employer, lines) do
            {:ok, inserted} ->
              {file, %{parsed: inserted, errors: length(errors)}}

            {:error, reason} ->
              Repo.rollback(reason)
          end
      end
    end)
    |> case do
      {:ok, {file, summary}} -> {:ok, file, summary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  # A line that failed on two fields is still one line.
  defp count_error_lines(errors) do
    errors |> Enum.map(& &1.line_number) |> Enum.uniq() |> length()
  end

  defp insert_credits(file, employer, lines) do
    Enum.reduce_while(lines, {:ok, 0}, fn line, {:ok, n} ->
      attrs =
        line
        |> Map.take([
          :line_number,
          :employee_id,
          :employee_name,
          :payment_reference,
          :gross_amount,
          :deduction_amount,
          :net_amount,
          :currency,
          :pay_period_start,
          :pay_period_end,
          :payment_date
        ])
        |> Map.merge(%{wps_file_id: file.wps_file_id, employer_id: employer.employer_id})

      case %SalaryCredit{} |> SalaryCredit.changeset(attrs) |> Repo.insert() do
        {:ok, _} ->
          {:cont, {:ok, n + 1}}

        {:error, changeset} ->
          # A duplicate payment_reference is the one failure worth naming
          # precisely: it means this payment already exists for this employer,
          # which is the guarantee that stops a re-sent file paying twice.
          reason =
            if Keyword.has_key?(changeset.errors, :employer_id) or
                 Keyword.has_key?(changeset.errors, :payment_reference) do
              {:duplicate_payment_reference, line.payment_reference, line.line_number}
            else
              {:invalid_line, line.line_number, changeset.errors}
            end

          {:halt, {:error, reason}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc "Files for an employer, newest first."
  @spec list_files(Ecto.UUID.t(), keyword()) :: [WpsFile.t()]
  def list_files(employer_id, opts \\ []) do
    WpsFile
    |> where([f], f.employer_id == ^employer_id)
    |> then(fn q ->
      case Keyword.get(opts, :status) do
        nil -> q
        status -> where(q, [f], f.status == ^status)
      end
    end)
    |> order_by([f], desc: f.ingested_at)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  @doc "Fetches a file."
  @spec get_file(Ecto.UUID.t()) :: WpsFile.t() | nil
  def get_file(wps_file_id), do: Repo.get(WpsFile, wps_file_id)

  @doc "Salary credits belonging to a file, in file order."
  @spec list_credits(Ecto.UUID.t(), keyword()) :: [SalaryCredit.t()]
  def list_credits(wps_file_id, opts \\ []) do
    SalaryCredit
    |> where([c], c.wps_file_id == ^wps_file_id)
    |> then(fn q ->
      case Keyword.get(opts, :status) do
        nil -> q
        status -> where(q, [c], c.status == ^status)
      end
    end)
    |> order_by([c], asc: c.line_number)
    |> Repo.all()
  end

  @doc "The per-line parse failures recorded against a file."
  @spec parse_errors(WpsFile.t()) :: [map()]
  def parse_errors(%WpsFile{parse_errors: %{"errors" => errors}}) when is_list(errors), do: errors
  def parse_errors(%WpsFile{}), do: []
end
