defmodule VmuCore.DPS.Dispute do
  @moduledoc """
  Dispute state machine for the Dispute Processing System.

  VisionPlus dispute lifecycle:
    FILED → RETRIEVAL_REQUESTED → CHARGEBACK_FILED →
    REPRESENTED → PRE_ARB → ARBITRATION → CLOSED_WIN | CLOSED_LOSE | CANCELLED

  Deadlines are hard cutoffs — missing them forfeits the case automatically.
    Visa:  chargeback within 120 days of transaction date
    Mastercard: chargeback within 120 days; representment within 30 days of chargeback

  Every state transition enqueues an Oban job to enforce the next deadline.

  ## Win/loss GL resolution (arbitration flow completion, 2026-07-08)

  Provisional credit posted at filing (`post_provisional_credit/1`) is resolved on
  case closure, not left standing indefinitely:
    - `CLOSED_WIN` / issuer wins — the scheme reimburses; the Disputed Receivable is
      cleared against a scheme-recovery account, no customer-balance impact.
    - `CLOSED_LOSE` / merchant wins, or `CANCELLED` — the credit is reversed,
      re-debiting the cardholder for the disputed amount.
  See `post_resolution_gl/1`.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  require Logger

  alias VmuCore.{Repo, CMS.InternalGlPoster, CMS.Account}
  alias VmuCore.Shared.ModuleConfigEngine

  @primary_key {:dispute_id, :binary_id, autogenerate: true}

  @valid_statuses ~w[
    FILED RETRIEVAL_REQUESTED CHARGEBACK_FILED REPRESENTED
    PRE_ARB ARBITRATION CLOSED_WIN CLOSED_LOSE CANCELLED
  ]

  schema "dps_disputes" do
    field :account_id,               :binary_id
    field :ledger_entry_id,          :binary_id
    # TRAM aggregate linkage (TRAM-P5 5C, ADR-T5) — nil for disputes filed
    # before the TRAM feed existed
    field :trams_transaction_id,     :binary_id
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
    # Regulatory deadline for posting provisional credit — computed from the
    # configurable `dps.provisional_credit_window_days` (Module Configuration
    # Framework), not a fixed constant (varies by customer/market).
    field :provisional_credit_deadline, :date
    field :filed_at,                 :naive_datetime
    field :closed_at,                :naive_datetime

    timestamps()
  end

  def changeset(dispute, attrs) do
    dispute
    |> cast(attrs, [:account_id, :ledger_entry_id, :trams_transaction_id,
                    :transaction_date, :dispute_amount,
                    :currency, :reason_code, :network, :status, :network_ref,
                    :provisional_credit_posted, :chargeback_deadline, :representment_deadline,
                    :pre_arb_deadline, :provisional_credit_deadline, :filed_at, :closed_at])
    |> validate_required([:account_id, :transaction_date, :dispute_amount, :reason_code])
    |> validate_inclusion(:status, @valid_statuses)
    |> put_deadlines()
    |> put_provisional_credit_deadline()
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
    result =
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

        updated = %{dispute | status: new_status}
        post_resolution_gl(updated)
        schedule_next_deadline(updated)
        updated
      end)

    # Mirror into the TRAM event log AFTER commit (TRAM-P5 5C) — fail-safe,
    # no-op for disputes without a linked TRAM transaction
    with {:ok, dispute} <- result do
      VmuCore.TRAMS.DisputeBridge.notify_transition(dispute)
    end

    result
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

  defp put_provisional_credit_deadline(cs) do
    account_id = get_field(cs, :account_id)
    filed_at   = get_field(cs, :filed_at)

    case account_id && Repo.get(Account, account_id) do
      %Account{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id} ->
        {:ok, window_days} =
          ModuleConfigEngine.get("dps", "provisional_credit_window_days", sys_id, bank_id, logo_id)

        base_date = if filed_at, do: NaiveDateTime.to_date(filed_at), else: Date.utc_today()
        put_change(cs, :provisional_credit_deadline, Date.add(base_date, window_days))

      _ ->
        cs
    end
  end

  defp post_provisional_credit(%__MODULE__{} = d) do
    key = "PROV-CREDIT-#{d.dispute_id}"
    # GL direction (confirmed correct, finance sign-off pending — G11):
    #   DR 3001 (Disputed Receivable — we expect to recover from acquirer/scheme)
    #   CR 1001 (Customer AR — reduces outstanding balance, giving provisional credit)
    # This temporarily reduces the cardholder's outstanding balance while the dispute
    # is investigated. Reversed on CLOSED_LOSE/CANCELLED, recovered on CLOSED_WIN —
    # see post_resolution_gl/1.
    result =
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

    # Only flag the credit as posted when the GL post actually succeeded — a
    # bug fix found while completing the win/loss cycle: this previously set
    # the flag unconditionally, which would make a CLOSED_LOSE reversal fire
    # against a credit that was never really posted.
    case result do
      {:ok, _} ->
        Repo.update_all(
          from(d2 in __MODULE__, where: d2.dispute_id == ^d.dispute_id),
          set: [provisional_credit_posted: true]
        )

      {:error, reason} ->
        Logger.error("[DPS.Dispute] provisional credit GL post failed for " <>
                     "#{d.dispute_id}: #{inspect(reason)}")
    end
  end

  # ---------------------------------------------------------------------------
  # Win/loss GL resolution (FR-DPS-010b/019 — completes the arbitration flow)
  # ---------------------------------------------------------------------------

  # CLOSED_LOSE / CANCELLED — the provisional credit didn't hold (merchant won
  # the dispute, or the cardholder withdrew it): reverse it, re-debiting the
  # cardholder (DR 1001 / CR 3001 — the exact mirror of post_provisional_credit's
  # DR 3001 / CR 1001). Only fires if a credit was actually posted.
  defp post_resolution_gl(%__MODULE__{status: status, provisional_credit_posted: true} = d)
       when status in ["CLOSED_LOSE", "CANCELLED"] do
    key = "DISPUTE-REV-#{d.dispute_id}"

    result =
      InternalGlPoster.post(%{
        account_id:       d.account_id,
        idempotency_key:  key,
        transaction_code: "DISPUTE_REVERSAL",
        dr_amount:        d.dispute_amount,
        cr_amount:        d.dispute_amount,
        gl_account_dr:    "1001",
        gl_account_cr:    "3001",
        posting_date:     Date.utc_today(),
        value_date:       Date.utc_today(),
        narrative:        "Dispute #{String.downcase(status_label(status))} — provisional credit reversed, dispute #{d.dispute_id}"
      })

    case result do
      {:ok, _} ->
        Repo.update_all(
          from(d2 in __MODULE__, where: d2.dispute_id == ^d.dispute_id),
          set: [provisional_credit_posted: false]
        )

      {:error, reason} ->
        Logger.error("[DPS.Dispute] reversal GL post failed for #{d.dispute_id}: #{inspect(reason)}")
    end
  end

  # CLOSED_WIN — the scheme reimburses the issuer: clear the Disputed
  # Receivable (3001) against a new scheme-recovery clearing account (3002).
  # No customer-balance impact — the cardholder keeps the provisional credit
  # permanently, which is the correct outcome of winning a dispute.
  defp post_resolution_gl(%__MODULE__{status: "CLOSED_WIN"} = d) do
    key = "DISPUTE-RECOVERY-#{d.dispute_id}"

    InternalGlPoster.post(%{
      account_id:       d.account_id,
      idempotency_key:  key,
      transaction_code: "DISPUTE_RECOVERY",
      dr_amount:        d.dispute_amount,
      cr_amount:        d.dispute_amount,
      gl_account_dr:    "3002",
      gl_account_cr:    "3001",
      posting_date:     Date.utc_today(),
      value_date:       Date.utc_today(),
      narrative:        "Dispute won — recovered from scheme, dispute #{d.dispute_id}"
    })
  end

  defp post_resolution_gl(_dispute), do: :ok

  defp status_label("CLOSED_LOSE"), do: "LOST"
  defp status_label(other), do: other

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
    # "Etc/UTC" — the only zone in the default time_zone_database; plain "UTC"
    # raises :utc_only_time_zone_database (found during TRAM-P5 smoke testing;
    # every dispute filing crashed here at deadline scheduling)
    DateTime.new!(date, ~T[08:00:00], "Etc/UTC")
  end
end
