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

  alias VmuCore.Repo
  alias VmuCore.NTS.{Token, Tokens, TokenServiceProvider}
  alias VmuCore.ASM.AuditLog

  @doc """
  Provision a new device token for `card` into `wallet` (`"GOOGLE_PAY"` for
  now). Creates the token row first (status PENDING) so every attempt is
  audit-traceable regardless of outcome, then calls the TSP.
  """
  @spec provision(struct(), map(), String.t(), keyword()) :: {:ok, Token.t()} | {:error, term()}
  def provision(card, device_info, wallet, opts \\ []) do
    scheme = Keyword.get(opts, :scheme, "MASTERCARD")

    {:ok, token} =
      Tokens.create(%{
        "card_id" => card.card_id, "scheme" => scheme, "wallet" => wallet,
        "device_id" => device_info["device_id"] || device_info[:device_id],
        "device_name" => device_info["device_name"] || device_info[:device_name],
        "last_four" => card.last_four
      })

    case TokenServiceProvider.impl().provision_token(card, device_info, wallet) do
      {:ok, %{token_reference_id: ref, dpan: dpan}} ->
        {:ok, _} = Tokens.transition(token, "ACTIVE")

        {:ok, activated} =
          token.token_id
          |> Tokens.get()
          |> Token.changeset(%{"dpan" => dpan, "token_reference_id" => ref})
          |> Repo.update()

        AuditLog.record(opts[:operator], "nts_token_provision", token.token_id,
          %{card_id: card.card_id, wallet: wallet, scheme: scheme})

        {:ok, activated}

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

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp transition_with_tsp(token, new_status, tsp_fun, opts) do
    action = "nts_token_" <> String.downcase(new_status)

    case apply(TokenServiceProvider.impl(), tsp_fun, [token]) do
      {:ok, _} ->
        {:ok, _} = Tokens.transition(token, new_status)
        AuditLog.record(opts[:operator], action, token.token_id, %{card_id: token.card_id})

      {:error, reason} ->
        Logger.warning("[NTS] #{action} TSP call failed for token #{token.token_id}: #{inspect(reason)}")
        AuditLog.record(opts[:operator], action <> "_failed", token.token_id,
          %{card_id: token.card_id, reason: inspect(reason)})
    end
  end
end
