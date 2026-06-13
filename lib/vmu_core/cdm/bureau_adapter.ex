defmodule VmuCore.CDM.BureauAdapter do
  @moduledoc """
  Behaviour for credit bureau API integrations.

  Implementations: EquifaxAdapter, ExperianAdapter, EmiratesCreditBureauAdapter.
  All bureau calls are async — submit a request, poll or receive webhook for result.
  Adapters are selected by sys_id/bank_id configuration in ParameterEngine.
  """

  @type customer_id :: binary()
  @type bureau_ref  :: binary()
  @type score       :: integer()

  @callback pull_credit_report(customer_id(), id_number :: String.t()) ::
    {:ok, %{bureau_ref: bureau_ref(), score: score(), report: map()}} | {:error, term()}

  @callback report_account(account_data :: map()) :: :ok | {:error, term()}

  @callback submit_metro2_file(file_path :: String.t()) ::
    {:ok, bureau_ref()} | {:error, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour VmuCore.CDM.BureauAdapter
    end
  end
end

defmodule VmuCore.CDM.MockBureauAdapter do
  @moduledoc "Development/test bureau adapter — returns synthetic scores."
  use VmuCore.CDM.BureauAdapter
  require Logger

  @impl true
  def pull_credit_report(customer_id, id_number) do
    # Deterministic synthetic score based on ID hash (reproducible in tests)
    hash  = :crypto.hash(:sha256, id_number) |> :binary.decode_unsigned()
    score = 400 + rem(hash, 450)  # 400–850 range

    Logger.info("[Bureau/Mock] Credit report: customer=#{customer_id} score=#{score}")

    {:ok, %{
      bureau_ref: "MOCK-#{:os.system_time(:second)}",
      score:      score,
      report: %{
        accounts_open:    rem(hash, 5),
        derogatory_marks: if(score < 550, do: 1, else: 0),
        utilization_pct:  rem(hash, 90)
      }
    }}
  end

  @impl true
  def report_account(account_data) do
    Logger.info("[Bureau/Mock] Reporting account: #{inspect(Map.take(account_data, [:account_id, :status]))}")
    :ok
  end

  @impl true
  def submit_metro2_file(file_path) do
    Logger.info("[Bureau/Mock] Metro 2 file submitted: #{file_path}")
    {:ok, "MOCK-METRO2-#{:os.system_time(:second)}"}
  end
end
