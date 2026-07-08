defmodule VmuCore.CTA.CardLifecycle do
  @moduledoc """
  Card lifecycle operations (CTA-P2) — the business layer over
  `VmuCore.CTA.Cards` transitions.

  | Op | FR | Effect |
  |----|----|--------|
  | `activate/2`  | 014 | INACTIVE→ACTIVE + account denormal sync |
  | `block/3`     | 015 | →BLOCKED; LOST/STOLEN/FRAUD also sets the account `block_code` (L/S/F) so `HotCardCache` declines auth |
  | `unblock/2`   | 015 | BLOCKED→ACTIVE; clears the account block_code |
  | `replace/3`   | 016 | old→REPLACED, new generation issued; LOST/STOLEN/FRAUD force a **new PAN** (caller supplies from tokenizer), DAMAGED keeps the PAN; waivable replacement fee (skipped for FRAUD) |
  | `renew/2`     | 017 | old→REPLACED, new generation **same PAN**, bumped expiry; no fee |

  All ops audit via `ASM.AuditLog` and refresh `HotCardCache` when the account
  block state changed.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CTA.Card, CTA.Cards, CMS.Account, CMS.FeeEngine,
                 FAS.HotCardCache, ASM.AuditLog}
  alias VmuCore.Shared.ModuleConfigEngine

  @reason_to_block_code %{"LOST" => "L", "STOLEN" => "S", "FRAUD" => "F"}
  @new_pan_reasons ~w[LOST STOLEN FRAUD]
  @replaceable ~w[INACTIVE ACTIVE BLOCKED EXPIRED]

  # ---------------------------------------------------------------------------
  # Activate (FR-014)
  # ---------------------------------------------------------------------------

  @spec activate(Ecto.UUID.t(), keyword()) :: {:ok, Card.t()} | {:error, term()}
  def activate(card_id, opts \\ []) do
    method = Keyword.get(opts, :method, "admin")

    with {:ok, card} <- Cards.transition(card_id, "ACTIVE", activation_method: method) do
      AuditLog.record(opts[:operator], "card_activate", card_id, %{method: method})
      {:ok, card}
    end
  end

  # ---------------------------------------------------------------------------
  # Block / unblock (FR-015)
  # ---------------------------------------------------------------------------

  @spec block(Ecto.UUID.t(), String.t(), keyword()) :: {:ok, Card.t()} | {:error, term()}
  def block(card_id, reason, opts \\ []) when reason in ~w[LOST STOLEN FRAUD DAMAGED ADMIN] do
    with {:ok, card} <- Cards.transition(card_id, "BLOCKED", block_reason: reason) do
      maybe_set_account_block(card, reason)
      AuditLog.record(opts[:operator], "card_block", card_id, %{reason: reason})
      {:ok, card}
    end
  end

  @spec unblock(Ecto.UUID.t(), keyword()) :: {:ok, Card.t()} | {:error, term()}
  def unblock(card_id, opts \\ []) do
    with {:ok, card} <- Cards.transition(card_id, "ACTIVE") do
      clear_account_block(card)
      AuditLog.record(opts[:operator], "card_unblock", card_id, %{})
      {:ok, card}
    end
  end

  # ---------------------------------------------------------------------------
  # Replace (FR-016)
  # ---------------------------------------------------------------------------

  @doc """
  Replace a card. `reason` ∈ LOST/STOLEN/FRAUD/DAMAGED.

  Opts:
    - `:new_pan_token` (+ `:new_last_four`) — REQUIRED for LOST/STOLEN/FRAUD
      (compromised PAN must change; supplied by the issuance tokenizer)
    - `:new_expiry` — defaults to the old card's expiry
    - `:waive_fee` — skip the replacement fee
    - `:operator`

  Returns `{:ok, %{old: card, new: card, fee: :assessed | :skipped | :waived}}`.
  """
  @spec replace(Ecto.UUID.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def replace(card_id, reason, opts \\ []) when reason in ~w[LOST STOLEN FRAUD DAMAGED] do
    with {:ok, old} <- fetch_replaceable(card_id),
         {:ok, pan, last4} <- resolve_replacement_pan(old, reason, opts) do
      new_expiry   = Keyword.get(opts, :new_expiry, old.expiry)
      pan_changed? = pan != old.pan_token

      result =
        Repo.transaction(fn ->
          {:ok, _} = Cards.transition(old.card_id, "REPLACED")

          {:ok, new} =
            Cards.issue(%{
              account_id:       old.account_id,
              pan_token:        pan,
              last_four:        last4,
              expiry:           new_expiry,
              emboss_name:      old.emboss_name,
              card_type:        old.card_type,
              status:           "INACTIVE",
              generation:       old.generation + 1,
              replaces_card_id: old.card_id
            })

          # Point the account at the new plastic; a genuine PAN change (per the
          # configured card_replacement_pan_policy, not a static reason list)
          # also clears the account block (the dead plastic is gone).
          sync_account_to_new(new, pan_changed?)
          new
        end)

      case result do
        {:ok, new} ->
          if pan_changed?, do: HotCardCache.refresh()
          fee = assess_fee(old, reason, opts)
          AuditLog.record(opts[:operator], "card_replace", card_id,
            %{reason: reason, new_card_id: new.card_id, new_generation: new.generation, fee: fee})

          Logger.info("[CTA] Replaced card #{card_id} (#{reason}) → " <>
                      "gen #{new.generation} #{new.card_id} fee=#{fee}")

          {:ok, %{old: %{old | status: "REPLACED"}, new: new, fee: fee}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Renew (FR-017)
  # ---------------------------------------------------------------------------

  @doc """
  Renew a card — same PAN, bumped expiry, new generation. No fee.

  Opts: `:years` (default 3), `:activate` (default false — renewal ships
  INACTIVE for re-activation unless the caller wants a seamless swap),
  `:operator`.
  """
  @spec renew(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def renew(card_id, opts \\ []) do
    years    = Keyword.get(opts, :years, 3)
    activate = Keyword.get(opts, :activate, false)

    with {:ok, old} <- fetch_replaceable(card_id) do
      new_expiry = Cards.bump_expiry(old.expiry, years)
      status     = if activate, do: "ACTIVE", else: "INACTIVE"

      result =
        Repo.transaction(fn ->
          {:ok, _} = Cards.transition(old.card_id, "REPLACED")

          {:ok, new} =
            Cards.issue(%{
              account_id:       old.account_id,
              pan_token:        old.pan_token,
              last_four:        old.last_four,
              expiry:           new_expiry,
              emboss_name:      old.emboss_name,
              card_type:        old.card_type,
              status:           status,
              generation:       old.generation + 1,
              replaces_card_id: old.card_id,
              activated_at:     if(activate, do: DateTime.utc_now() |> DateTime.truncate(:second))
            })

          Cards.sync_account_from_card(new)
          new
        end)

      case result do
        {:ok, new} ->
          AuditLog.record(opts[:operator], "card_renew", card_id,
            %{new_card_id: new.card_id, new_generation: new.generation, new_expiry: new_expiry})

          Logger.info("[CTA] Renewed card #{card_id} → gen #{new.generation} " <>
                      "expiry #{new_expiry} status=#{status}")

          {:ok, %{old: %{old | status: "REPLACED"}, new: new}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Channel controls (FR-022)
  # ---------------------------------------------------------------------------

  @doc """
  Set card-level channel-control overrides. See `Cards.set_channel_controls/2`
  for the tri-state semantics. Audited as `"card_channel_controls"`.
  """
  @spec set_channel_controls(Ecto.UUID.t(), map(), keyword()) :: {:ok, Card.t()} | {:error, term()}
  def set_channel_controls(card_id, controls, opts \\ []) do
    with {:ok, card} <- Cards.set_channel_controls(card_id, controls) do
      AuditLog.record(opts[:operator], "card_channel_controls", card_id, controls)
      {:ok, card}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp fetch_replaceable(card_id) do
    case Cards.get(card_id) do
      nil -> {:error, :card_not_found}
      %Card{status: s} = card when s in @replaceable -> {:ok, card}
      %Card{status: s} -> {:error, {:not_replaceable, s}}
    end
  end

  defp resolve_replacement_pan(old, reason, opts) do
    case replacement_pan_action(old, reason) do
      "new" ->
        case Keyword.get(opts, :new_pan_token) do
          pan when is_binary(pan) and byte_size(pan) == 64 ->
            {:ok, pan, Keyword.get(opts, :new_last_four)}

          _ ->
            {:error, :new_pan_token_required}
        end

      "same" ->
        {:ok, old.pan_token, old.last_four}
    end
  end

  # Reason-code → "new" | "same" policy, configurable per logo (Module
  # Configuration Framework — `cta.card_replacement_pan_policy`). Falls back to
  # the historical lost/stolen/fraud=new, damaged=same rule if the account
  # can't be resolved or the reason isn't present in the configured map.
  defp replacement_pan_action(old, reason) do
    case Repo.get(Account, old.account_id) do
      %Account{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id} ->
        {:ok, policy} =
          ModuleConfigEngine.get("cta", "card_replacement_pan_policy", sys_id, bank_id, logo_id)

        Map.get(policy, reason, default_pan_action(reason))

      nil ->
        default_pan_action(reason)
    end
  end

  defp default_pan_action(reason) when reason in @new_pan_reasons, do: "new"
  defp default_pan_action(_reason), do: "same"

  defp assess_fee(_old, "FRAUD", _opts), do: :skipped

  defp assess_fee(old, _reason, opts) do
    if Keyword.get(opts, :waive_fee, false) do
      :waived
    else
      account = Repo.get(Account, old.account_id)

      case account && FeeEngine.assess_card_replacement_fee(old.account_id, account, old.card_id) do
        :ok -> :assessed
        _   -> :skipped
      end
    end
  end

  defp maybe_set_account_block(%Card{card_type: "PRIMARY"} = card, reason) do
    case Map.get(@reason_to_block_code, reason) do
      nil ->
        :ok

      code ->
        Repo.update_all(
          from(a in Account, where: a.account_id == ^card.account_id),
          set: [block_code: code, block_reason: "Card #{reason}",
                blocked_at: NaiveDateTime.utc_now(), updated_at: NaiveDateTime.utc_now()]
        )

        HotCardCache.refresh()
    end
  end

  defp maybe_set_account_block(_card, _reason), do: :ok

  defp clear_account_block(%Card{card_type: "PRIMARY"} = card) do
    Repo.update_all(
      from(a in Account,
        where: a.account_id == ^card.account_id and a.block_code in ["L", "S", "F"]),
      set: [block_code: nil, block_reason: nil, blocked_at: nil,
            updated_at: NaiveDateTime.utc_now()]
    )

    HotCardCache.refresh()
  end

  defp clear_account_block(_card), do: :ok

  # New plastic supersedes: point the account at it and, if the PAN actually
  # changed, clear a lost/stolen/fraud block (the compromised plastic is gone).
  defp sync_account_to_new(new, pan_changed?) do
    Cards.sync_account_from_card(new)

    if pan_changed? do
      Repo.update_all(
        from(a in Account, where: a.account_id == ^new.account_id),
        set: [block_code: nil, block_reason: nil, blocked_at: nil,
              updated_at: NaiveDateTime.utc_now()]
      )
    end
  end
end
