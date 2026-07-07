defmodule VmuCore.CMS.BureauAdapter do
  @moduledoc """
  Production adapter for submitting Metro 2 credit bureau files.

  ## Modes

  Configure via `config.exs`:

      config :vmu_core, :bureau_adapter,
        mode: :stub             # :stub | :sftp | :http
        sftp_host: "bureau.example.com",
        sftp_port: 22,
        sftp_user: "visionplus",
        sftp_key_path: "/etc/vmu_core/bureau_rsa",
        sftp_remote_dir: "/incoming/metro2",
        http_url: "https://bureau-api.example.com/v1/metro2/submit",
        http_api_key: "..."

  ## Idempotency

  Every submission is logged in `cms_bureau_submissions`. Before transmitting,
  the adapter checks for a prior successful submission with the same
  `file_path` basename + `submitted_date`. Duplicate submissions return
  `{:ok, prior_ref}` without re-transmitting.

  ## Usage

      BureauAdapter.submit_metro2_file("/tmp/metro2_V001_BANK_LOG_2026-06-15.dat")
      # => {:ok, "BUREAU-REF-20260615-001"}
  """

  require Logger
  import Ecto.Query
  alias VmuCore.Repo

  @cfg Application.compile_env(:vmu_core, :bureau_adapter, mode: :stub)

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Submit a Metro 2 file to the credit bureau.

  Returns `{:ok, bureau_ref}` on success, `{:error, reason}` on failure.
  On `:stub` mode always returns `{:ok, "STUB-REF-<timestamp>"}`.
  """
  @spec submit_metro2_file(String.t()) :: {:ok, String.t()} | {:error, term()}
  def submit_metro2_file(file_path) do
    basename     = Path.basename(file_path)
    today        = Date.utc_today()

    # Idempotency guard — don't re-submit if already sent today
    case find_prior_submission(basename, today) do
      {:ok, ref} ->
        Logger.info("[BureauAdapter] Idempotent skip — already submitted today: ref=#{ref}")
        {:ok, ref}

      :not_found ->
        do_submit(file_path, basename, today)
    end
  end

  # ---------------------------------------------------------------------------
  # Private — dispatch by mode
  # ---------------------------------------------------------------------------

  defp do_submit(file_path, basename, today) do
    mode = @cfg[:mode] || :stub

    Logger.info("[BureauAdapter] Submitting #{basename} via mode=#{mode}")

    result =
      case mode do
        :stub  -> submit_stub(file_path)
        :sftp  -> submit_sftp(file_path)
        :http  -> submit_http(file_path)
        other  -> {:error, "Unknown bureau_adapter mode: #{other}"}
      end

    case result do
      {:ok, ref} ->
        log_submission(basename, today, ref, :success)
        {:ok, ref}

      {:error, reason} ->
        log_submission(basename, today, inspect(reason), :failure)
        {:error, reason}
    end
  end

  # ── Stub mode ──────────────────────────────────────────────────────────────

  defp submit_stub(file_path) do
    # Simulate transmission delay and return a deterministic reference
    size = File.stat!(file_path).size
    ref  = "STUB-#{Date.utc_today() |> Date.to_iso8601()}-#{:erlang.phash2(file_path, 99999)}"
    Logger.info("[BureauAdapter:stub] Simulated submit — #{size} bytes → ref=#{ref}")
    {:ok, ref}
  end

  # ── SFTP mode ──────────────────────────────────────────────────────────────

  defp submit_sftp(file_path) do
    host       = to_charlist(@cfg[:sftp_host] || "localhost")
    port       = @cfg[:sftp_port]       || 22
    user       = to_charlist(@cfg[:sftp_user] || "vmu")
    key_path   = @cfg[:sftp_key_path]
    remote_dir = @cfg[:sftp_remote_dir] || "/incoming"
    basename   = Path.basename(file_path)
    remote     = Path.join(remote_dir, basename)

    ssh_opts = [
      user: user,
      silently_accept_hosts: true,
      user_interaction: false
    ]

    ssh_opts =
      if key_path do
        Keyword.put(ssh_opts, :user_dir, to_charlist(Path.dirname(key_path)))
      else
        ssh_opts
      end

    with {:ok, conn}    <- :ssh.connect(host, port, ssh_opts),
         {:ok, channel} <- :ssh_sftp.start_channel(conn),
         :ok            <- :ssh_sftp.write_file(channel, to_charlist(remote), File.read!(file_path)),
         :ok            <- :ssh_sftp.stop_channel(channel),
         :ok            <- :ssh.close(conn) do
      ref = "SFTP-#{Date.utc_today() |> Date.to_iso8601()}-#{basename}"
      Logger.info("[BureauAdapter:sftp] Uploaded #{basename} → #{host}:#{remote}")
      {:ok, ref}
    else
      {:error, reason} ->
        Logger.error("[BureauAdapter:sftp] SFTP upload failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── HTTP mode ──────────────────────────────────────────────────────────────

  defp submit_http(file_path) do
    url     = @cfg[:http_url]     || raise "bureau_adapter :http_url not configured"
    api_key = @cfg[:http_api_key] || raise "bureau_adapter :http_api_key not configured"

    body    = File.read!(file_path)
    headers = [
      {"Content-Type", "text/plain"},
      {"X-Api-Key",    api_key},
      {"X-Filename",   Path.basename(file_path)}
    ]

    :httpc.start()

    req = {
      String.to_charlist(url),
      Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end),
      'text/plain',
      body
    }

    case :httpc.request(:post, req, [{:ssl, [{:verify, :verify_none}]}], []) do
      {:ok, {{_http, status, _reason}, _resp_headers, resp_body}} when status in 200..299 ->
        ref = "HTTP-#{Date.utc_today() |> Date.to_iso8601()}-#{status}"
        Logger.info("[BureauAdapter:http] Submitted → HTTP #{status} — ref=#{ref}")
        body_str = to_string(resp_body)
        # Try to extract a bureau ref from JSON response {"ref": "..."}
        bureau_ref =
          case Jason.decode(body_str) do
            {:ok, %{"ref" => r}} -> r
            _                    -> ref
          end
        {:ok, bureau_ref}

      {:ok, {{_http, status, _reason}, _resp_headers, body}} ->
        Logger.error("[BureauAdapter:http] HTTP #{status}: #{inspect(body)}")
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        Logger.error("[BureauAdapter:http] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Submission log — idempotency + audit
  # ---------------------------------------------------------------------------

  defp find_prior_submission(basename, today) do
    result =
      Repo.one(
        from s in "cms_bureau_submissions",
          where: s.filename == ^basename
             and s.submitted_date == ^today
             and s.status == "success",
          order_by: [desc: s.inserted_at],
          limit: 1,
          select: s.bureau_ref
      )

    if result, do: {:ok, result}, else: :not_found
  rescue
    # Table may not exist yet (first run before migration)
    _ -> :not_found
  end

  defp log_submission(basename, today, ref_or_error, status) do
    Repo.insert_all("cms_bureau_submissions", [
      %{
        filename:       basename,
        submitted_date: today,
        bureau_ref:     to_string(ref_or_error),
        status:         to_string(status),
        inserted_at:    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      }
    ])
  rescue
    # Non-fatal — don't fail the submission on a log write error
    e -> Logger.warning("[BureauAdapter] Could not log submission: #{Exception.message(e)}")
  end
end
