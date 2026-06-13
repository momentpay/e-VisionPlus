defmodule VmuCore.HCS.Oban.PaymentSweepJob do
  @moduledoc """
  Nightly Oban job — sweeps outstanding balances from employee card accounts
  to the corporate parent billing account for CENTRAL liability companies.

  Cron: 0 22 * * * (22:00 — before CMS EOD at 23:00).
  """

  use Oban.Worker, queue: :hcs, max_attempts: 3

  require Logger
  import Ecto.Query

  alias VmuCore.HCS.{Company, EmployeeCard, PaymentSweep, PaymentSweepLine}
  alias VmuCore.CMS.{Account, InternalGlPoster}
  alias VmuCore.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    today = Date.utc_today()

    central_companies =
      from(c in Company,
        where: c.liability_model == "CENTRAL" and c.status == "ACTIVE"
      )
      |> Repo.all()

    Logger.info("[HCS/Sweep] Processing #{length(central_companies)} central-liability companies")
    Enum.each(central_companies, &sweep_company(&1, today))
    :ok
  end

  defp sweep_company(company, sweep_date) do
    employee_data =
      from(ec in EmployeeCard,
        join: a in Account, on: a.id == ec.employee_account_id,
        where: ec.company_id == ^company.id
          and ec.status == "ACTIVE"
          and a.current_balance > 0,
        select: %{
          card_id:    ec.id,
          account_id: ec.employee_account_id,
          balance:    a.current_balance
        }
      )
      |> Repo.all()

    if Enum.empty?(employee_data) do
      Logger.debug("[HCS/Sweep] Company #{company.company_code} — no balances to sweep")
    else
      total = Enum.reduce(employee_data, Decimal.new(0), fn row, acc ->
        Decimal.add(acc, row.balance)
      end)

      Repo.transaction(fn ->
        sweep =
          %PaymentSweep{}
          |> PaymentSweep.changeset(%{
            company_id:          company.id,
            sweep_date:          sweep_date,
            total_swept:         total,
            employee_card_count: length(employee_data),
            status:              "PENDING",
            inserted_at:         DateTime.utc_now()
          })
          |> Repo.insert!()

        Enum.each(employee_data, fn row ->
          Repo.update_all(
            from(a in Account, where: a.id == ^row.account_id),
            set: [current_balance: Decimal.new(0), updated_at: NaiveDateTime.utc_now()]
          )

          %PaymentSweepLine{}
          |> PaymentSweepLine.changeset(%{
            sweep_id:        sweep.id,
            employee_card_id: row.card_id,
            swept_amount:    row.balance,
            status:          "COMPLETED",
            inserted_at:     DateTime.utc_now()
          })
          |> Repo.insert!()
        end)

        # Credit the parent billing account
        Repo.update_all(
          from(a in Account, where: a.id == ^company.parent_account_id),
          inc: [current_balance: total]
        )

        # GL: DR Employee Receivable Pool / CR Parent Account
        case InternalGlPoster.post(%{
          account_id:       to_string(company.parent_account_id),
          idempotency_key:  "hcs_sweep_#{sweep.id}",
          transaction_code: "HCS_SWEEP",
          dr_amount:        total,
          cr_amount:        total,
          gl_account_dr:    "hcs_employee_pool",
          gl_account_cr:    "hcs_parent_payment",
          posting_date:     sweep_date,
          value_date:       sweep_date,
          narrative:        "HCS central sweep company #{company.company_code} #{sweep_date}"
        }) do
          {:ok, gl_entry} ->
            Repo.update_all(
              from(s in PaymentSweep, where: s.id == ^sweep.id),
              set: [status: "COMPLETED", gl_entry_id: gl_entry.id]
            )

          {:error, reason} ->
            Logger.error("[HCS/Sweep] GL post failed for company #{company.company_code}: #{inspect(reason)}")
            Repo.update_all(
              from(s in PaymentSweep, where: s.id == ^sweep.id),
              set: [status: "FAILED"]
            )
        end

        Logger.info("[HCS/Sweep] Company #{company.company_code} — swept #{total} from #{length(employee_data)} cards")
      end)
    end
  end
end
