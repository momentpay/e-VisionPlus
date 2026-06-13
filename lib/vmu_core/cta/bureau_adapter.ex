defmodule VmuCore.CTA.BureauAdapter do
  @moduledoc """
  Behaviour for card bureau (personalisation house) integrations.

  Implementations: DefaultBureauAdapter (file-drop SFTP), GDPlusBureauAdapter, ThalesBureauAdapter.
  All bureau communication is async — submit a file, poll for acknowledgement.
  """

  @type order_id :: binary()
  @type file_path :: binary()
  @type bureau_ref :: binary()

  @callback submit_embossing_file(file_path()) ::
    {:ok, bureau_ref()} | {:error, term()}

  @callback check_order_status(bureau_ref()) ::
    {:ok, :pending | :printed | :dispatched | :delivered} | {:error, term()}

  @callback acknowledge_delivery(bureau_ref(), delivered_at :: DateTime.t()) ::
    :ok | {:error, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour VmuCore.CTA.BureauAdapter
    end
  end
end

defmodule VmuCore.CTA.DefaultBureauAdapter do
  @moduledoc """
  File-drop bureau adapter — writes embossing file to a configured SFTP outbox.
  Used in development and as the default when no bureau-specific adapter is configured.
  """

  use VmuCore.CTA.BureauAdapter
  require Logger

  @impl true
  def submit_embossing_file(file_path) do
    bureau_ref = "BUR-#{:os.system_time(:millisecond)}"
    Logger.info("[Bureau] Submitting embossing file: #{file_path} ref=#{bureau_ref}")
    # Production: SFTP.put(file_path, destination: config(:sftp_outbox))
    {:ok, bureau_ref}
  end

  @impl true
  def check_order_status(bureau_ref) do
    Logger.debug("[Bureau] Checking status for #{bureau_ref}")
    # Production: SFTP.get_ack(bureau_ref) or REST poll
    {:ok, :pending}
  end

  @impl true
  def acknowledge_delivery(bureau_ref, delivered_at) do
    Logger.info("[Bureau] Delivery acknowledged: #{bureau_ref} at #{delivered_at}")
    :ok
  end
end
