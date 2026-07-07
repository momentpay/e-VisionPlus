defmodule VmuCore.CTA.Oban.CardExpirySweepJob do
  @moduledoc """
  Card expiry + auto-renewal sweep (CTA-P2.4, FR-017) — daily cron 04:00,
  before the account lifecycle sweep (05:00).

  1. **Auto-renewal** — ACTIVE PRIMARY cards whose MMYY expiry falls within
     `:cta_renewal_lead_days` (default 30) get a seamless renewal (same PAN,
     `:cta_renewal_years` bumped expiry, new generation, shipped ACTIVE),
     UNLESS the account is CLOSED / WRITTEN_OFF / dormant — those are left to
     expire. Reissues the renewed card, not the plastic in hand.
  2. **Expiry** — any live card (INACTIVE/ACTIVE/BLOCKED) whose expiry month
     has fully passed → EXPIRED (auth suppression: an EXPIRED card is no
     longer the account's live card).

  Renewal runs first so a just-renewed generation isn't immediately expired.
  Both passes are idempotent (renewal issues gen+1 only when the current live
  card is still the pre-renewal one; a second run finds the fresh expiry and
  skips).
  """

  use Oban.Worker, queue: :cta, max_attempts: 3, unique: [period: 3600]

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CTA.Card, CTA.Cards, CTA.CardLifecycle, CMS.Account}

  @batch_limit 1000
  @non_renewable_account ~w[CLOSED WRITTEN_OFF]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    today   = Date.utc_today()
    renewed = auto_renew(today)
    expired = expire_past(today)

    Logger.info("[CTA.CardExpirySweep] renewed=#{renewed} expired=#{expired}")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Auto-renewal
  # ---------------------------------------------------------------------------

  defp auto_renew(today) do
    lead_days = Application.get_env(:vmu_core, :cta_renewal_lead_days, 30)
    years     = Application.get_env(:vmu_core, :cta_renewal_years, 3)
    horizon   = Date.add(today, lead_days)

    candidates =
      Repo.all(
        from c in Card,
          join: a in Account, on: a.account_id == c.account_id,
          where: c.status == "ACTIVE" and c.card_type == "PRIMARY"
             and a.account_status not in ^@non_renewable_account
             and is_nil(a.dormant_since),
          limit: @batch_limit
      )

    candidates
    |> Enum.filter(fn card ->
      case Cards.expiry_end_date(card.expiry) do
        nil -> false
        end_date -> Date.compare(end_date, horizon) != :gt
      end
    end)
    |> Enum.count(fn card ->
      case CardLifecycle.renew(card.card_id, years: years, activate: true) do
        {:ok, _} -> true
        {:error, reason} ->
          Logger.warning("[CTA.CardExpirySweep] renew failed #{card.card_id}: #{inspect(reason)}")
          false
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Expiry
  # ---------------------------------------------------------------------------

  defp expire_past(today) do
    live =
      Repo.all(
        from c in Card,
          where: c.status in ["INACTIVE", "ACTIVE", "BLOCKED"],
          limit: @batch_limit
      )

    live
    |> Enum.filter(&Cards.expired?(&1.expiry, today))
    |> Enum.count(fn card ->
      case Cards.transition(card.card_id, "EXPIRED") do
        {:ok, _} -> true
        {:error, reason} ->
          Logger.warning("[CTA.CardExpirySweep] expire failed #{card.card_id}: #{inspect(reason)}")
          false
      end
    end)
  end
end
