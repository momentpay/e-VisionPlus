defmodule VmuCore.NTS.TokenLifecycle do
  @moduledoc """
  Business layer over `NTS.Tokens` — Network Tokenization Service Phase A
  (2026-07-29), mirrors `CTA.CardLifecycle`'s shape. Called both directly
  (`provision/4`, the "add to Google Pay" entry point) and from `CTA.
  CardLifecycle`'s own `block/3`/`unblock/2`/`replace/3` hooks, keeping a
  card's provisioned wallet tokens in sync with its own lifecycle.

  Every op calls `NTS.TokenServiceProvider.impl()` for the TSP side-effect
  first, then updates `nts_tokens` via `NTS.Tokens.transition/2`, then
  audits via `ASM.AuditLog`.

  **A TSP failure must never break the underlying card operation** — the
  `suspend_for_card/2`/`resume_for_card/2`/`delete_for_card/2` hooks always
  return `:ok` to their `CardLifecycle` caller even when the TSP call
  itself failed; the failure is logged and audited on the token, not
  propagated up to block/unblock/replace (same "fail-safe, don't crash the
  caller" posture `FAS.Authorization`'s own moduledoc states for its
  domain). `provision/4` is the one op that DOES surface a TSP failure
  directly to its caller — there's no card-side operation to protect there.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.NTS.{Token, Tokens, TokenServiceProvider}
  alias VmuCore.ASM.AuditLog
  alias VmuCore.FAS.DpanCache
  alias VmuCore.CMS.{Account, DebitAccount, PrepaidAccount}
  alias VmuCore.Shared.ModuleConfigEngine

  @doc """
  Provision a new device token for `card` into `wallet` (`"GOOGLE_PAY"` for
  now). Creates the token row first (status PENDING) so every attempt is
  audit-traceable regardless of outcome, then calls the TSP.

  Gated on the Module Configuration Framework's `cta.wallet_tokenization_mode`
  (per-logo, `[disabled, scheme_token, own_token]`, default `"disabled"`) —
  this is that key's first real consumer. Only `"scheme_token"` proceeds to
  the TSP; `"disabled"` (the default) and `"own_token"` (reserved, unused —
  no own-token implementation exists) both decline before creating any
  token row, so a logo that hasn't opted in never gets a stray PENDING/
  DELETED row from an attempt that was never going to succeed.
  """
  @spec provision(struct(), map(), String.t(), keyword()) :: {:ok, Token.t()} | {:error, term()}
  def provision(card, device_info, wallet, opts \\ []) do
    scheme = Keyword.get(opts, :scheme, "MASTERCARD")

    with {:ok, "scheme_token"} <- tokenization_mode(card) do
      do_provision(card, device_info, wallet, scheme, opts)
    else
      {:ok, mode} -> {:error, {:tokenization_disabled, mode}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_provision(card, device_info, wallet, scheme, opts) do
    {:ok, token} =
      Tokens.create(%{
        "card_id" => card.card_id, "scheme" => scheme, "wallet" => wallet,
        "device_id" => device_info["device_id"] || device_info[:device_id],
        "device_name" => device_info["device_name"] || device_info[:device_name],
        "last_four" => card.last_four
      })

    case TokenServiceProvider.impl().provision_token(card, device_info, wallet) do
      {:ok, %{token_reference_id: ref, dpan: dpan, status: status}} ->
        # The provider declares the resulting status, not this module — a
        # synchronous TSP (e.g. wallet-initiated provisioning) can confirm
        # ACTIVE immediately with a real dpan; MDES's real Push Provisioning
        # flow (NTS Phase B) only ever returns PUSHED here (a receipt, no
        # dpan yet — see MastercardMdes.provision_token/3).
        {:ok, _} = Tokens.transition(token, status)

        {:ok, updated} =
          token.token_id
          |> Tokens.get()
          |> Token.changeset(%{"dpan" => dpan, "token_reference_id" => ref})
          |> Repo.update()

        AuditLog.record(opts[:operator], "nts_token_provision", token.token_id,
          %{card_id: card.card_id, wallet: wallet, scheme: scheme, status: status})

        # NTS Phase D — a status of ACTIVE means this token just became
        # (or remains) DPAN-resolvable; refresh now rather than waiting up
        # to 5 minutes for FAS.DpanCache's own schedule. A no-op cost for
        # PUSHED (no dpan yet, nothing changes in the cache).
        if status == "ACTIVE", do: DpanCache.refresh()

        {:ok, updated}

      {:error, reason} ->
        {:ok, _} = Tokens.transition(token, "DELETED")

        AuditLog.record(opts[:operator], "nts_token_provision_failed", token.token_id,
          %{card_id: card.card_id, wallet: wallet, reason: inspect(reason)})

        {:error, {:tsp_error, reason}}
    end
  end

  @doc "Suspend every live token for `card_id` — called from `CardLifecycle.block/3`."
  @spec suspend_for_card(binary(), keyword()) :: :ok
  def suspend_for_card(card_id, opts \\ []) do
    card_id
    |> Tokens.list_for_card()
    |> Enum.filter(&(&1.status == "ACTIVE"))
    |> Enum.each(&transition_with_tsp(&1, "SUSPENDED", :suspend_token, opts))

    :ok
  end

  @doc "Resume every suspended token for `card_id` — called from `CardLifecycle.unblock/2`."
  @spec resume_for_card(binary(), keyword()) :: :ok
  def resume_for_card(card_id, opts \\ []) do
    card_id
    |> Tokens.list_for_card()
    |> Enum.filter(&(&1.status == "SUSPENDED"))
    |> Enum.each(&transition_with_tsp(&1, "ACTIVE", :resume_token, opts))

    :ok
  end

  @doc """
  Delete every live token for `card_id` — called from `CardLifecycle.
  replace/3` only when the PAN actually changed (a genuine PAN change
  invalidates the DPAN↔PAN mapping MDES holds; the cardholder must
  re-provision under the new plastic).
  """
  @spec delete_for_card(binary(), keyword()) :: :ok
  def delete_for_card(card_id, opts \\ []) do
    card_id
    |> Tokens.list_for_card()
    |> Enum.each(&transition_with_tsp(&1, "DELETED", :delete_token, opts))

    :ok
  end

  @doc """
  Delete a single token by id — the admin console's manual "remove device"
  action (Way4 parity plan §5 / Phase E). Unlike `delete_for_card/2` (every
  live token on a card, called only from `CardLifecycle.replace/3`), this
  targets one device/token, leaving the card's other provisioned wallets
  untouched.
  """
  @spec delete_token(binary(), keyword()) :: :ok | {:error, :token_not_found}
  def delete_token(token_id, opts \\ []) do
    case Tokens.get(token_id) do
      nil ->
        {:error, :token_not_found}

      token ->
        transition_with_tsp(token, "DELETED", :delete_token, opts)
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp transition_with_tsp(token, new_status, tsp_fun, opts) do
    action = "nts_token_" <> String.downcase(new_status)

    case apply(TokenServiceProvider.impl(), tsp_fun, [token]) do
      {:ok, _} ->
        {:ok, _} = Tokens.transition(token, new_status)
        AuditLog.record(opts[:operator], action, token.token_id, %{card_id: token.card_id})
        # Any real status change (SUSPENDED/ACTIVE/DELETED) can add or
        # remove a DpanCache entry — refresh now, don't wait for the
        # 5-minute schedule (matches CardLifecycle's own HotCardCache.
        # refresh() calls after a block-state change).
        DpanCache.refresh()

      {:error, reason} ->
        Logger.warning("[NTS] #{action} TSP call failed for token #{token.token_id}: #{inspect(reason)}")
        AuditLog.record(opts[:operator], action <> "_failed", token.token_id,
          %{card_id: token.card_id, reason: inspect(reason)})
    end
  end

  # Resolves `cta.wallet_tokenization_mode` for the logo `card` belongs to.
  # A card carries exactly one of account_id/debit_account_id/
  # prepaid_account_id (never more than one — same three-way polymorphism
  # DpanCache's own resolve_and_check_block/3 branches on); each account
  # type carries its own sys_id/bank_id/logo_id, so this resolves which
  # one before asking ModuleConfigEngine.
  defp tokenization_mode(%{account_id: id}) when not is_nil(id),
    do: scope_lookup(Account, :account_id, id)

  defp tokenization_mode(%{debit_account_id: id}) when not is_nil(id),
    do: scope_lookup(DebitAccount, :debit_account_id, id)

  defp tokenization_mode(%{prepaid_account_id: id}) when not is_nil(id),
    do: scope_lookup(PrepaidAccount, :prepaid_account_id, id)

  defp tokenization_mode(_card), do: {:error, :account_not_found}

  defp scope_lookup(schema, key_field, id) do
    query = from(a in schema, where: field(a, ^key_field) == ^id,
                 select: {a.sys_id, a.bank_id, a.logo_id})

    case Repo.one(query) do
      {sys_id, bank_id, logo_id} ->
        ModuleConfigEngine.get("cta", "wallet_tokenization_mode", sys_id, bank_id, logo_id)

      nil ->
        {:error, :account_not_found}
    end
  end
end
