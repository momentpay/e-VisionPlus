# CTA-P1.5 — Backfill one PRIMARY generation-1 cta_cards row per existing
# account from its denormalized card fields (ADR-CTA1).
#
#   mix run priv/repo/backfill_cta_cards.exs
#
# Idempotent: skips accounts that already have a PRIMARY card.

import Ecto.Query
alias VmuCore.{Repo, CTA.Card, CMS.Account}

# account_status → initial card status
status_map = fn
  "ACTIVE"      -> "ACTIVE"
  "INACTIVE"    -> "INACTIVE"
  "BLOCKED"     -> "BLOCKED"
  "SUSPENDED"   -> "BLOCKED"
  "DELINQUENT"  -> "ACTIVE"
  "POSTING"     -> "ACTIVE"
  "CLOSED"      -> "DESTROYED"
  "WRITTEN_OFF" -> "DESTROYED"
  _             -> "INACTIVE"
end

existing =
  Repo.all(from c in Card, where: c.card_type == "PRIMARY", select: c.account_id)
  |> MapSet.new()

accounts =
  Repo.all(
    from a in Account,
      where: not is_nil(a.pan_token),
      select: %{account_id: a.account_id, pan_token: a.pan_token,
                last_four: a.last_four, expiry_date: a.expiry_date,
                emboss_name: a.emboss_name, account_status: a.account_status}
  )

{created, skipped} =
  Enum.reduce(accounts, {0, 0}, fn acct, {c, s} ->
    if MapSet.member?(existing, acct.account_id) do
      {c, s + 1}
    else
      card_status = status_map.(acct.account_status)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        account_id:   acct.account_id,
        pan_token:    acct.pan_token,
        last_four:    acct.last_four,
        expiry:       acct.expiry_date,
        emboss_name:  acct.emboss_name,
        card_type:    "PRIMARY",
        status:       card_status,
        generation:   1,
        issued_at:    now,
        activated_at: if(card_status == "ACTIVE", do: now)
      }

      case Repo.insert(Card.changeset(%Card{}, attrs)) do
        {:ok, _} -> {c + 1, s}
        {:error, cs} ->
          IO.puts("  skip #{acct.account_id}: #{inspect(cs.errors)}")
          {c, s + 1}
      end
    end
  end)

IO.puts("Backfill complete: created=#{created} skipped=#{skipped} " <>
        "(of #{length(accounts)} accounts with a PAN)")
