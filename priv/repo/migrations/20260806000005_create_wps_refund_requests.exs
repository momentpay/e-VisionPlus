defmodule VmuCore.Repo.Migrations.CreateWpsRefundRequests do
  @moduledoc """
  Employer refund of a salary credit, under maker-checker (Phase W4).

  ## Why refunds need two people

  Taking money back out of a worker's account is the one WPS operation that
  moves money *against* the beneficiary. An employer overpaid, or paid someone
  who had already left — both are real, and both are also exactly what a
  fraudulent request would claim. The bank cannot verify the employer's story,
  so the control is procedural: one person requests, a different person decides,
  and both are recorded.

  This mirrors `CMS.FeeWaiver` and `CMS.FinancialAdjustment`, which take the
  same posture for the same reason.

  ## What cannot be refunded

  Money the worker has already spent. The refund consumes the prepaid balance,
  so if it is gone the request fails with `:insufficient_funds` — clawing back
  spent wages would need the worker's account to go negative, which is not a
  thing a wage account may do. That refusal is a real answer, not an error to
  work around.
  """
  use Ecto.Migration

  def change do
    create table(:wps_refund_requests, primary_key: false) do
      add :refund_request_id, :binary_id,
          primary_key: true,
          default: fragment("gen_random_uuid()")

      add :salary_credit_id,
          references(:wps_salary_credits,
            column: :salary_credit_id,
            type: :binary_id,
            on_delete: :restrict
          ),
          null: false

      add :employer_id,
          references(:wps_employers, column: :employer_id, type: :binary_id, on_delete: :restrict),
          null: false

      # Defaults to the whole credit. Partial exists because the realistic case
      # is an overpayment — the employer meant to pay 4,500 and sent 5,000, and
      # only the difference should come back.
      add :amount, :decimal, precision: 18, scale: 4, null: false

      add :reason, :string, size: 500, null: false

      # PENDING  — awaiting a decision
      # APPROVED — decided and the money moved
      # REJECTED — decided against
      # FAILED   — approved, but the money could not be recovered
      add :status, :string, size: 20, null: false, default: "PENDING"

      add :requested_by, :string, size: 100, null: false
      add :requested_at, :utc_datetime_usec, null: false

      add :decided_by, :string, size: 100
      add :decided_at, :utc_datetime_usec
      add :decision_note, :string, size: 500

      add :failure_reason, :string, size: 300

      timestamps(type: :utc_datetime_usec)
    end

    # One request in flight per credit. Without this, two operators could each
    # raise a request for the same payment and a checker approving both would
    # recover the money twice.
    create unique_index(:wps_refund_requests, [:salary_credit_id],
             where: "status = 'PENDING'",
             name: :wps_refund_requests_one_pending_idx
           )

    create index(:wps_refund_requests, [:employer_id, :status])

    create constraint(:wps_refund_requests, :wps_refund_requests_status_check,
             check: "status IN ('PENDING','APPROVED','REJECTED','FAILED')"
           )

    create constraint(:wps_refund_requests, :wps_refund_requests_amount_positive_check,
             check: "amount > 0"
           )
  end
end
