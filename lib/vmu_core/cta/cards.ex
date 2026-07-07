defmodule VmuCore.CTA.Cards do
  @moduledoc """
  Card entity context (CTA-P1.4) — the API for the plastic lifecycle.

  `transition/3` is the only status write path: it validates via
  `CardStateMachine`, stamps the matching lifecycle timestamp, and — per
  ADR-CTA1 — keeps the account's denormalized current-card fields
  (`pan_token`/`last_four`/`expiry_date`/`emboss_name`) in sync whenever a
  PRIMARY card becomes (or stops being) the account's live card, so FAS's
  hot path stays correct without reading `cta_cards`.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CTA.Card, CTA.CardStateMachine, CMS.Account}

  @live_statuses ~w[INACTIVE ACTIVE BLOCKED ORDERED EMBOSSED DISPATCHED]

  # ---------------------------------------------------------------------------
  # Issue
  # ---------------------------------------------------------------------------

  @doc """
  Issue a new card. Attrs: `:account_id`, `:pan_token`, `:card_type`, plus
  optional `:last_four`, `:expiry`, `:emboss_name`, `:generation`,
  `:replaces_card_id`, `:status` (default "INACTIVE").
  """
  @spec issue(map()) :: {:ok, Card.t()} | {:error, term()}
  def issue(attrs) do
    attrs =
      attrs
      |> Map.put_new(:status, "INACTIVE")
      |> Map.put_new(:generation, 1)
      |> Map.put_new(:issued_at, now())

    %Card{}
    |> Card.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Card by id."
  @spec get(Ecto.UUID.t()) :: Card.t() | nil
  def get(card_id), do: Repo.get(Card, card_id)

  @doc "All cards for an account, newest generation first."
  @spec by_account(Ecto.UUID.t()) :: [Card.t()]
  def by_account(account_id) do
    Repo.all(
      from c in Card,
        where: c.account_id == ^account_id,
        order_by: [desc: c.generation, desc: c.inserted_at]
    )
  end

  @doc "The live card holding a pan_token (nil if none)."
  @spec by_pan_token(String.t()) :: Card.t() | nil
  def by_pan_token(pan_token) do
    Repo.one(
      from c in Card,
        where: c.pan_token == ^pan_token and c.status in ^@live_statuses,
        limit: 1
    )
  end

  @doc "The account's current live PRIMARY card (highest generation)."
  @spec current_card(Ecto.UUID.t()) :: Card.t() | nil
  def current_card(account_id) do
    Repo.one(
      from c in Card,
        where: c.account_id == ^account_id
           and c.card_type == "PRIMARY"
           and c.status in ^@live_statuses,
        order_by: [desc: c.generation],
        limit: 1
    )
  end

  # ---------------------------------------------------------------------------
  # Transition
  # ---------------------------------------------------------------------------

  @doc """
  Move a card to `new_status`, validated by `CardStateMachine`.

  Opts: `:block_reason`, `:activation_method`, `:dispatch_ref` — recorded
  where relevant. Syncs the account's current-card denormals for PRIMARY
  cards (ADR-CTA1).

  Returns `{:ok, card}` or `{:error, reason}`.
  """
  @spec transition(Ecto.UUID.t() | Card.t(), String.t(), keyword()) ::
          {:ok, Card.t()} | {:error, term()}
  def transition(card_id, new_status, opts \\ [])

  def transition(%Card{} = card, new_status, opts),
    do: transition(card.card_id, new_status, opts)

  def transition(card_id, new_status, opts) do
    Repo.transaction(fn ->
      card = Repo.one(from c in Card, where: c.card_id == ^card_id, lock: "FOR UPDATE")

      if is_nil(card), do: Repo.rollback(:card_not_found)

      case CardStateMachine.transition(card.status, new_status) do
        {:ok, ^new_status} ->
          updated =
            card
            |> Card.changeset(status_change_attrs(new_status, opts))
            |> Repo.update!()

          sync_account_denormals(updated, new_status)
          updated

        {:error, reason} ->
          Logger.warning("[CTA.Cards] Rejected #{card.status}→#{new_status} " <>
                         "for #{card_id}: #{inspect(reason)}")
          Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Set card-level channel-control overrides (CTA-P3.2, FR-022). Each of
  `:ecom_enabled` / `:atm_enabled` / `:contactless_enabled` / `:intl_enabled`
  is tri-state: `true` (force allow), `false` (force block), `nil` (inherit
  the account/LOGO cascade — the pre-P3 behavior). Unlisted keys are left
  untouched. `CardValidator.validate_channel_flags/4` reads these ahead of
  the parameter cascade.
  """
  @spec set_channel_controls(Ecto.UUID.t(), map()) :: {:ok, Card.t()} | {:error, term()}
  def set_channel_controls(card_id, controls) do
    case get(card_id) do
      nil ->
        {:error, :card_not_found}

      card ->
        card
        |> Card.changeset(Map.take(controls, ~w[ecom_enabled atm_enabled contactless_enabled intl_enabled]a))
        |> Repo.update()
    end
  end

  @doc """
  Force the account's current-card denormals to match `card` (ADR-CTA1).
  Used by replacement/renewal where a newly issued card supersedes the old
  one without going through `transition/3`.
  """
  @spec sync_account_from_card(Card.t()) :: :ok
  def sync_account_from_card(%Card{} = card) do
    Repo.update_all(
      from(a in Account, where: a.account_id == ^card.account_id),
      set: [pan_token: card.pan_token, last_four: card.last_four,
            expiry_date: card.expiry, emboss_name: card.emboss_name,
            updated_at: NaiveDateTime.utc_now()]
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp status_change_attrs(new_status, opts) do
    base = %{status: new_status}

    base
    |> put_if(:block_reason, opts[:block_reason])
    |> put_if(:activation_method, opts[:activation_method])
    |> put_if(:dispatch_ref, opts[:dispatch_ref])
    |> stamp(new_status)
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp stamp(attrs, "ACTIVE"),  do: Map.put(attrs, :activated_at, now())
  defp stamp(attrs, "BLOCKED"), do: Map.put(attrs, :blocked_at, now())
  defp stamp(attrs, "EXPIRED"), do: Map.put(attrs, :expired_at, now())
  defp stamp(attrs, _), do: attrs

  # ADR-CTA1: mirror the live PRIMARY card onto the account row so FAS's
  # hot path (which reads cms_accounts) stays correct.
  defp sync_account_denormals(%Card{card_type: "PRIMARY"} = card, new_status)
       when new_status in ["ACTIVE", "INACTIVE"] do
    Repo.update_all(
      from(a in Account, where: a.account_id == ^card.account_id),
      set: [pan_token: card.pan_token, last_four: card.last_four,
            expiry_date: card.expiry, emboss_name: card.emboss_name,
            updated_at: NaiveDateTime.utc_now()]
    )
  end

  defp sync_account_denormals(_card, _status), do: :ok

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # ---------------------------------------------------------------------------
  # Expiry helpers (MMYY)
  # ---------------------------------------------------------------------------

  @doc "Last calendar day of an MMYY expiry (a card is valid through month end)."
  @spec expiry_end_date(String.t()) :: Date.t() | nil
  def expiry_end_date(<<mm::binary-size(2), yy::binary-size(2)>>) do
    with {month, ""} when month in 1..12 <- Integer.parse(mm),
         {yy_int, ""} <- Integer.parse(yy) do
      Date.end_of_month(Date.new!(2000 + yy_int, month, 1))
    else
      _ -> nil
    end
  end

  def expiry_end_date(_), do: nil

  @doc "True when the card's MMYY expiry is before `as_of` (default today)."
  @spec expired?(String.t() | nil, Date.t()) :: boolean()
  def expired?(expiry, as_of \\ Date.utc_today())
  def expired?(nil, _as_of), do: false

  def expired?(expiry, as_of) do
    case expiry_end_date(expiry) do
      nil -> false
      end_date -> Date.compare(as_of, end_date) == :gt
    end
  end

  @doc "Advance an MMYY expiry by `years` (keeps the month)."
  @spec bump_expiry(String.t(), pos_integer()) :: String.t()
  def bump_expiry(<<mm::binary-size(2), yy::binary-size(2)>>, years) do
    {yy_int, ""} = Integer.parse(yy)
    mm <> (rem(yy_int + years, 100) |> Integer.to_string() |> String.pad_leading(2, "0"))
  end
end
