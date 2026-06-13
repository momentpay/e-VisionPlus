defmodule VmuCore.LMS.Oban.AutoDisbursementJob do
  @moduledoc """
  Automatic disbursement Oban job — processes auto-disbursement for accounts
  whose open_to_redeem >= disbursement_packet threshold for the given scheme.

  Cron: configurable per scheme (default: monthly).
  """

  use Oban.Worker, queue: :lms, max_attempts: 3

  require Logger
  alias VmuCore.LMS.{Account, RedemptionProcessor}
  alias VmuCore.Repo
  import Ecto.Query
  alias Decimal, as: D

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scheme_id" => scheme_id}}) do
    Logger.info("[LMS/AutoDisburse] Running for scheme #{scheme_id}")

    disbursement_packet =
      Application.get_env(:vmu_core, [:lms, :schemes, scheme_id, :disbursement_packet], "500")
      |> D.new()

    disbursement_method =
      Application.get_env(:vmu_core, [:lms, :schemes, scheme_id, :disbursement_method], "CREDIT")

    eligible_accounts =
      from(a in Account,
        where: a.scheme_id == ^scheme_id
          and a.status == "ACTIVE"
          and a.open_to_redeem >= ^disbursement_packet
      )
      |> Repo.all()

    Logger.info("[LMS/AutoDisburse] #{length(eligible_accounts)} eligible accounts")

    Enum.each(eligible_accounts, fn account ->
      amount =
        if D.eq?(disbursement_packet, D.new(0)),
          do: account.open_to_redeem,
          else: disbursement_packet

      case RedemptionProcessor.redeem(account.id, amount,
             type: "AUTO_DISBURSEMENT",
             method: disbursement_method) do
        {:ok, _} ->
          Logger.debug("[LMS/AutoDisburse] Disbursed #{amount} pts for account #{account.id}")

        {:error, reason} ->
          Logger.warning("[LMS/AutoDisburse] Failed for account #{account.id}: #{inspect(reason)}")
      end
    end)

    :ok
  end
end
