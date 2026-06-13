defmodule VmuCore.DPS.Dispute do
  @moduledoc """
  Dispute state machine for the Dispute Processing System.

  VisionPlus dispute lifecycle:
    FILED → RETRIEVAL_REQUESTED → CHARGEBACK_FILED →
    REPRESENTED → PRE_ARB → ARBITRATION → CLOSED_WIN | CLOSED_LOSE

  Deadlines are hard cutoffs — missing them forfeits the case automatically.
    Visa:  chargeback within 120 days of transaction date
    Mastercard: chargeback within 120 days; representment within 30 days of chargeback

  Every state transition enqueues an Oban job to enforce the next deadline.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias VmuCore.{Repo, CMS.InternalGlPoster}

  @primary_key {:dispute_id, :binary_id, autogenerate: true}

  @valid_statuses ~w[
    FILED RETRIEVAL_REQUESTED CHARGEBACK_FILED REPRESENTED
    PRE_ARB ARBITRATION CLOSED_WIN CLOSED_LOSE CANCELLED
  ]

  schema "dps_disputes" do
    field :account_id,               :binary_id
    field :ledger_entry_id,          :binary_id
    field :transaction_date,         :date
    field :dispute_amount,           :decimal
    field :currency,                 :string, default: "MC"
    field :reason_code,              :string
    field :network,                  :string, default: "MC"
    field :status,                   :string, default: "FILED"
    field :network_ref,              :string
    field :provisional_credit_posted,:boolean, default: false
    field :chargeback_deadline,      :date
    field :representment_deadline,   :date
    field :pre_arb_deadline,         :date
    field :filed_at,                 :naive_datetime
    field :closed_at,                :naive_datetime

    timestamps()
  end

  def changeset(dispute, attrs) do
    dispute
    |> cast(attrs, [:account_id, :ledger_entry_id, :transaction_date, :dispute_amount,
                    :currency, :reason_code, :network, :status, :network_ref,
                    :provisional_credit_posted, :chargeback_deadline, :representment_deadline,
                    :pre_arb_deadline, :filed_at, :closed_at])
    |> validate_required([:account_id, :transaction_date, :dispute_amount, :reason_code])
    |> validate_inclusion(:status, @valid_statuses)
    |> put_deadlines()
  end

  @doc """
  File a new dispute. Computes deadlines and posts provisional credit.
  Returns {:ok, dispute} or {:error, changeset}.
  """
  def file(attrs) do
    Repo.transaction(fn ->
      cs = changeset(%__MODULE__{}, Map.put(attrs, :filed_at, NaiveDateTime.utc_now()))

      case Repo.insert(cs) do
        {:ok, dispute} ->
          post_provisional_credit(dispute)
          schedule_chargeback_deadline(dispute)
          dispute

        {:error, cs} ->
          Repo.rollback(cs)
      end
    end)
  end

  @doc "Transition dispute to the next state."
  def transition(dispute_id, new_status) when new_status in @valid_statuses do
    Repo.transaction(fn ->
      dispute = Repo.get!(__MODULE__, dispute_id)

      updates = [status: new_status, updated_at: NaiveDateTime.utc_now()]
      updates = if new_status in ["CLOSED_WIN", "CLOSED_LOSE", "CANCELLED"],
        do: Keyword.put(updates, :closed_at, NaiveDateTime.utc_now()),
        else: updates

      Repo.update_all(
        from(d in __MODULE__, where: d.dispute_id == ^dispute_id),
        set: updates
      )

      schedule_next_deadline(%{dispute | status: new_status})
      %{dispute | status: new_status}
    end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp put_deadlines(cs) do
    txn_date = get_field(cs, :transaction_date)
    network  = get_field(cs, :network) || "MC"

    if txn_date do
      cb_days = if network == "VI", do: 120, else: 120
      cs
      |> put_change(:chargeback_deadline, Date.add(txn_date, cb_days))
      |> put_change(:representment_deadline, Date.add(txn_date, cb_days + 30))
      |> put_change(:pre_arb_deadline, Date.add(txn_date, cb_days + 60))
    else
      cs
    end
  end

  defp post_provisional_credit(%__MODULE__{} = d) do
    key = "PROV-CREDIT-#{d.dispute_id}"
    # GL direction (confirmed correct, finance sign-off pending — G11):
    #   DR 3001 (Disputed Receivable — we expect to recover from acquirer/scheme)
    #   CR 1001 (Customer AR — reduces outstanding balance, giving provisional credit)
    # This temporarily reduces the cardholder's outstanding balance while the dispute
    # is investigated. On CLOSED_LOSE, a reversal entry must be posted (DR 1001 / CR 3001).
    InternalGlPoster.post(%{
      account_id:       d.account_id,
      idempotency_key:  key,
      transaction_code: "DISPUTE_CREDIT",
      dr_amount:        d.dispute_amount,
      cr_amount:        d.dispute_amount,
      gl_account_dr:    "3001",
      gl_account_cr:    "1001",
      posting_date:     Date.utc_today(),
      value_date:       Date.utc_today(),
      narrative:        "Provisional credit — dispute #{d.dispute_id}"
    })

    Repo.update_all(
      from(d2 in __MODULE__, where: d2.dispute_id == ^d.dispute_id),
      set: [provisional_credit_posted: true]
    )
  end

  defp schedule_chargeback_deadline(dispute) do
    %{dispute_id: dispute.dispute_id, action: "file_chargeback"}
    |> VmuCore.DPS.DeadlineJob.new(scheduled_at: deadline_dt(dispute.chargeback_deadline))
    |> Oban.insert()
  end

  defp schedule_next_deadline(%{status: "CHARGEBACK_FILED"} = d) do
    %{dispute_id: d.dispute_id, action: "check_representment"}
    |> VmuCore.DPS.DeadlineJob.new(scheduled_at: deadline_dt(d.representment_deadline))
    |> Oban.insert()
  end

  defp schedule_next_deadline(%{status: "REPRESENTED"} = d) do
    %{dispute_id: d.dispute_id, action: "file_pre_arb"}
    |> VmuCore.DPS.DeadlineJob.new(scheduled_at: deadline_dt(d.pre_arb_deadline))
    |> Oban.insert()
  end

  defp schedule_next_deadline(_), do: :ok

  defp deadline_dt(date) do
    DateTime.new!(date, ~T[08:00:00], "UTC")
  end
end
