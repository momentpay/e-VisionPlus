defmodule VmuCore.NTS.PushProvisioningSessions do
  @moduledoc """
  Business layer for MDES Token Connect's remaining push-based use cases
  — NTS Phase F2/F3 (2026-08-02): Push to Merchant (case-1, `start_push/
  5`), Push to Token Requestor via Proprietary Communication (case-4,
  `start_proprietary_push/4`), Push to Merchant with Authentication
  (case-3, Phase F5), Pull from Wallet (case-5, Phase F4). Case 2/Google
  Pay stays on its own dedicated path (`TokenServiceProviders.
  MastercardMdes.provision_token/3`) since it's a `TokenServiceProvider`
  behaviour implementation, not a customer-initiated session.

  `start_push/5` (cases 1/3/5) round-trips through the Token Requestor's
  own UI via a browser redirect, so the attempt needs to survive across
  that boundary — the session record is for that. `start_proprietary_
  push/4` (case 4) is fire-and-forget like Case 2, no redirect needed,
  but still creates a session for a consistent audit trail.

  ## Lifecycle

  `start_push/5`: creates a `PENDING` session first (so its own id can be
  used to build `/nts/callback/:session_id` as MDES's `callbackURL`),
  then calls `MastercardMdesClient.push_multiple_accounts/5`, stores the
  receipt, and returns a redirect URL built from the response's
  `availablePushMethods`.

  **The redirect URL's exact query-param shape is a best-effort
  generic guess** (`?receipt=<receipt>&callback=<our callback URL>`),
  not a confirmed contract — MDES's own spec defers this to each Token
  Requestor's individual "Issuer Interface Implementation Guide," which
  we don't have. Flagging this explicitly rather than presenting it as
  verified: a real Token Requestor integration may need a different
  shape once we have their actual guide.

  `complete/2` is called by `NtsCallbackController` when the Token
  Requestor redirects the cardholder back — transitions the session and,
  on success, creates/activates the corresponding `NTS.Token` row (reuse
  `NTS.Tokens`, same as Phase B/D — no separate token bookkeeping here).
  """

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.CTA.Card
  alias VmuCore.NTS.{PushProvisioningSession, MastercardMdesClient, ConsentService, Token, Tokens}

  @doc """
  Starts a push session for `card_id`/`customer_id` toward
  `token_requestor_id`. `funding_account` is the plaintext
  `%{"cardAccountData" => %{"accountNumber" =>, "expiryMonth" =>,
  "expiryYear" =>}}` map (same shape/sourcing constraint as
  `TokenServiceProviders.MastercardMdes.provision_token/3` — vmu_core
  never retains a raw PAN, so this must come from a fresh cardholder
  entry or a `CredentialVault` reveal, never persisted here).

  Creates the `NTS.Token` row up front (status PENDING), same
  audit-traceable-regardless-of-outcome posture as `TokenLifecycle.
  provision/4` — the session links to that specific token by id (not a
  "the current pending token for this card" lookup) so two concurrent
  sessions for the same card can never cross-activate each other's token.
  """
  @spec start_push(binary(), binary(), String.t(), map(), keyword()) ::
          {:ok, PushProvisioningSession.t(), String.t()} | {:error, term()}
  def start_push(card_id, customer_id, token_requestor_id, funding_account, opts \\ []) do
    wallet = Keyword.get(opts, :wallet, "TOKEN_REQUESTOR")

    with {:ok, card} <- fetch_card(card_id),
         {:ok, token} <- create_pending_token(card, token_requestor_id, wallet),
         {:ok, session} <- create_session(card_id, customer_id, token.token_id, token_requestor_id, opts) do
      callback_url = callback_url_for(session)
      push_id = "CA-" <> Ecto.UUID.generate()

      case MastercardMdesClient.push_multiple_accounts(
             Ecto.UUID.generate(), token_requestor_id, funding_account, push_id,
             callback_url: callback_url,
             request_issuer_initiated_digitization_data: false
           ) do
        {:ok, %{"pushAccountReceipts" => [receipt | _], "availablePushMethods" => methods}} ->
          {:ok, updated} =
            session
            |> PushProvisioningSession.changeset(%{"push_account_receipt" => receipt["pushAccountReceipt"]})
            |> Repo.update()

          {:ok, updated, build_redirect_url(methods, receipt["pushAccountReceipt"], callback_url)}

        {:ok, %{"pushAccountReceipts" => []}} ->
          fail(session, :no_receipt_returned)

        {:error, reason} ->
          fail(session, reason)
      end
    end
  end

  @doc """
  Case 4 — Push to Token Requestor using Proprietary Communication (NTS
  Phase F3, 2026-08-02). Unlike `start_push/4`'s browser-redirect flow,
  this is fire-and-forget, same shape as Case 2/Google Pay: requests
  `requestIssuerInitiatedDigitizationData: true` so MDES returns the
  digitization result in-band, no `callbackURL`/redirect needed. Still
  creates a session record (consistent audit trail alongside the token,
  same as every other case here) but completes it synchronously in this
  same call rather than waiting for `NtsCallbackController`.

  Returns the raw `issuerInitiatedDigitizationData` blob for the caller
  to hand off to the specific Token Requestor's own proprietary channel
  — no specific partner exists yet, so this is honestly a mechanism only
  (mirrors `TokenServiceProviders.Stub`'s posture before Google Pay's
  real spec existed). The token is transitioned to `PUSHED`, not
  `ACTIVE` — same honest caution as `TokenServiceProviders.MastercardMdes.
  provision_token/3`'s Google Pay flow: we can't confirm the Token
  Requestor's own proprietary hand-off actually completed from here.
  """
  @spec start_proprietary_push(binary(), binary(), String.t(), map()) ::
          {:ok, PushProvisioningSession.t(), map()} | {:error, term()}
  def start_proprietary_push(card_id, customer_id, token_requestor_id, funding_account) do
    with {:ok, card} <- fetch_card(card_id),
         {:ok, token} <- create_pending_token(card, token_requestor_id, "TOKEN_REQUESTOR"),
         {:ok, session} <- create_session(card_id, customer_id, token.token_id, token_requestor_id, []),
         push_id = "CA-" <> Ecto.UUID.generate() do
      case MastercardMdesClient.push_multiple_accounts(
             Ecto.UUID.generate(), token_requestor_id, funding_account, push_id,
             request_issuer_initiated_digitization_data: true
           ) do
        {:ok, %{"pushAccountReceipts" => [receipt | _]} = response} ->
          {:ok, _} = Tokens.transition(token, "PUSHED")

          {:ok, updated} =
            session
            |> PushProvisioningSession.changeset(%{
              "push_account_receipt" => receipt["pushAccountReceipt"], "status" => "COMPLETED"
            })
            |> Repo.update()

          {:ok, updated, Map.get(response, "issuerInitiatedDigitizationData", %{})}

        {:ok, %{"pushAccountReceipts" => []}} ->
          fail(session, :no_receipt_returned)

        {:error, reason} ->
          fail(session, reason)
      end
    end
  end

  @doc """
  Case 5 — Pull Provisioning from Wallet (NTS Phase F4, 2026-08-02). The
  wallet is the entry point here, not us: the cardholder starts in
  Google Pay, gets redirected into Kosa carrying `wallet_session_id`
  (MDES's `tokenRequestorSessionId` — ties our push back to the pull
  session the wallet already opened) and `wallet_callback_url`
  (where to send the cardholder back once we're done). After
  authenticating (CAM, Phase F1) and picking a card, this pushes the
  same way `start_push/5` does but keyed to the wallet's own session
  instead of a browser-redirect round trip we control — no
  `callbackURL` needed since the response comes back synchronously.

  Same honest caution as `start_proprietary_push/4`: the token lands on
  `PUSHED`, not `ACTIVE` — per case-5's own doc, "Wallet completes
  provisioning (BAU)" happens entirely on the wallet's side after we
  hand off the receipt; we have no way to confirm it from here.

  Returns a URL to redirect the cardholder's browser to
  (`wallet_callback_url` with the receipt appended) — same best-effort
  query-shape caveat as `start_push/5`'s redirect URL.
  """
  @spec start_pull(binary(), binary(), String.t(), map(), keyword()) ::
          {:ok, PushProvisioningSession.t(), String.t()} | {:error, term()}
  def start_pull(card_id, customer_id, token_requestor_id, funding_account, opts) do
    wallet_session_id = Keyword.fetch!(opts, :wallet_session_id)
    wallet_callback_url = Keyword.fetch!(opts, :wallet_callback_url)

    with {:ok, card} <- fetch_card(card_id),
         {:ok, token} <- create_pending_token(card, token_requestor_id, "TOKEN_REQUESTOR"),
         {:ok, session} <-
           create_session(card_id, customer_id, token.token_id, token_requestor_id,
             direction: "pull", wallet_session_id: wallet_session_id, wallet_callback_url: wallet_callback_url
           ),
         push_id = "CA-" <> Ecto.UUID.generate() do
      case MastercardMdesClient.push_multiple_accounts(
             Ecto.UUID.generate(), token_requestor_id, funding_account, push_id,
             token_requestor_session_id: wallet_session_id,
             request_issuer_initiated_digitization_data: false
           ) do
        {:ok, %{"pushAccountReceipts" => [receipt | _]} = response} ->
          {:ok, _} = Tokens.transition(token, "PUSHED")

          {:ok, updated} =
            session
            |> PushProvisioningSession.changeset(%{
              "push_account_receipt" => receipt["pushAccountReceipt"], "status" => "COMPLETED"
            })
            |> Repo.update()

          {:ok, updated, build_wallet_redirect_url(wallet_callback_url, receipt["pushAccountReceipt"], response["signature"])}

        {:ok, %{"pushAccountReceipts" => []}} ->
          fail(session, :no_receipt_returned)

        {:error, reason} ->
          fail(session, reason)
      end
    end
  end

  @doc """
  Called by `NtsCallbackController` when the Token Requestor redirects
  the cardholder back. `result_params` is whatever the TR appended to
  our callback URL — parsed best-effort (see moduledoc caveat): looks
  for a `result`/`status` param indicating success, `REQUIRE_ADDITIONAL_
  AUTHENTICATION` (routes to `AUTH_REQUIRED`, Phase F5/Case 3), or
  anything else (treated as failure).
  """
  @spec complete(binary(), map()) :: {:ok, PushProvisioningSession.t()} | {:error, :not_found}
  def complete(session_id, result_params) do
    case get(session_id) do
      nil ->
        {:error, :not_found}

      session ->
        outcome = String.upcase(to_string(result_params["result"] || result_params["status"] || ""))
        new_status = status_for(outcome)

        {:ok, updated} =
          session
          |> PushProvisioningSession.changeset(%{
            "status" => new_status,
            "requires_authentication" => new_status == "AUTH_REQUIRED"
          })
          |> Repo.update()

        if new_status == "COMPLETED", do: activate_token(updated)

        {:ok, updated}
    end
  end

  @spec get(binary()) :: PushProvisioningSession.t() | nil
  def get(session_id), do: Repo.get(PushProvisioningSession, session_id)

  @doc """
  Case 3 — Push to Merchant with Authentication (NTS Phase F5,
  2026-08-02). Called once the cardholder has entered the activation
  code the Token Requestor showed them, for a session already sitting
  in `AUTH_REQUIRED` (set by `complete/2` when the TR's callback result
  was `REQUIRE_ADDITIONAL_AUTHENTICATION`). Honestly fails — see
  `NTS.ConsentService`'s moduledoc for why. The session/state machine
  exists and is exercised by this call; only the actual Mastercard-side
  notification is missing.
  """
  @spec authenticate(binary(), String.t()) ::
          {:error, :not_found} | {:error, :not_awaiting_authentication} | {:error, :consent_service_spec_not_available}
  def authenticate(session_id, activation_code) do
    case get(session_id) do
      nil -> {:error, :not_found}
      %{status: "AUTH_REQUIRED"} = session -> ConsentService.notify_activation_code_required(session, activation_code)
      _session -> {:error, :not_awaiting_authentication}
    end
  end

  @doc """
  Lists Token Requestors eligible to receive `card_id`, filtered to
  `token_requestor_type` (`"MERCHANT"` for Case 1's picker, `nil` for
  no filter). Same `getEligibleTokenRequestors` call `TokenServiceProviders.
  MastercardMdes.resolve_google_pay_requestor_id/1` already uses for
  Google Pay — duplicated here rather than shared since that module's
  BIN-resolution helper is private and scoped to its own TSP-behaviour
  concern, not this session-tracking one.
  """
  @spec list_eligible_token_requestors(binary(), String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def list_eligible_token_requestors(card_id, token_requestor_type \\ nil) do
    with {:ok, card} <- fetch_card(card_id),
         {:ok, bin_prefix} <- resolve_bin_prefix(card),
         {:ok, %{"tokenRequestors" => requestors}} <-
           MastercardMdesClient.get_eligible_token_requestors([bin_prefix], Ecto.UUID.generate()) do
      filtered =
        if token_requestor_type do
          Enum.filter(requestors, &(&1["tokenRequestorType"] == token_requestor_type))
        else
          requestors
        end

      {:ok, filtered}
    end
  end

  @doc """
  Ownership check for the customer-facing controllers — a cardholder must
  never be able to push someone else's card. `Card` has no `customer_id`
  of its own (only `account_id`/`debit_account_id`/`prepaid_account_id`),
  so this resolves through whichever one is set.
  """
  @spec card_belongs_to_customer?(binary(), binary()) :: boolean()
  def card_belongs_to_customer?(card_id, customer_id) do
    case Repo.get(Card, card_id) do
      nil ->
        false

      card ->
        cond do
          card.account_id -> Repo.exists?(from a in VmuCore.CMS.Account, where: a.account_id == ^card.account_id and a.customer_id == ^customer_id)
          card.debit_account_id -> Repo.exists?(from a in VmuCore.CMS.DebitAccount, where: a.debit_account_id == ^card.debit_account_id and a.customer_id == ^customer_id)
          card.prepaid_account_id -> Repo.exists?(from a in VmuCore.CMS.PrepaidAccount, where: a.prepaid_account_id == ^card.prepaid_account_id and a.customer_id == ^customer_id)
          true -> false
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp fetch_card(card_id) do
    case Repo.get(Card, card_id) do
      nil -> {:error, :card_not_found}
      card -> {:ok, card}
    end
  end

  defp resolve_bin_prefix(card) do
    scope =
      cond do
        card.account_id -> Repo.one(from a in VmuCore.CMS.Account, where: a.account_id == ^card.account_id, select: {a.sys_id, a.bank_id, a.logo_id})
        card.debit_account_id -> Repo.one(from a in VmuCore.CMS.DebitAccount, where: a.debit_account_id == ^card.debit_account_id, select: {a.sys_id, a.bank_id, a.logo_id})
        card.prepaid_account_id -> Repo.one(from a in VmuCore.CMS.PrepaidAccount, where: a.prepaid_account_id == ^card.prepaid_account_id, select: {a.sys_id, a.bank_id, a.logo_id})
        true -> nil
      end

    case scope do
      {sys_id, bank_id, logo_id} ->
        case Repo.get_by(VmuCore.Shared.LogoParameter, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id) do
          nil -> {:error, :logo_not_found}
          %{bin_prefix: prefix} -> {:ok, prefix}
        end

      nil ->
        {:error, :account_not_found}
    end
  end

  defp create_pending_token(card, token_requestor_id, wallet) do
    Tokens.create(%{
      "card_id" => card.card_id, "scheme" => "MASTERCARD", "wallet" => wallet,
      "token_requestor_id" => token_requestor_id, "last_four" => card.last_four
    })
  end

  defp create_session(card_id, customer_id, token_id, token_requestor_id, opts) do
    %PushProvisioningSession{}
    |> PushProvisioningSession.changeset(%{
      "card_id" => card_id, "customer_id" => customer_id, "token_id" => token_id,
      "token_requestor_id" => token_requestor_id,
      "direction" => Keyword.get(opts, :direction, "push"),
      "wallet_session_id" => Keyword.get(opts, :wallet_session_id),
      "wallet_callback_url" => Keyword.get(opts, :wallet_callback_url)
    })
    |> Repo.insert()
  end

  defp fail(session, reason) do
    Logger.warning("[NTS.PushProvisioningSessions] push failed for session=#{session.session_id}: #{inspect(reason)}")
    {:ok, _} = session |> PushProvisioningSession.changeset(%{"status" => "FAILED"}) |> Repo.update()

    case Repo.get(Token, session.token_id) do
      nil -> :ok
      token -> Tokens.transition(token, "DELETED")
    end

    {:error, reason}
  end

  defp callback_url_for(session) do
    base = Application.get_env(:vmu_core, :nts, [])[:callback_base_url] || ""
    base <> "/nts/callback/#{session.session_id}"
  end

  # Prefer WEB (Kosa is Flutter web-first, Phase F6) — fall back to the
  # first method the Token Requestor supports if WEB isn't offered.
  defp build_redirect_url(methods, receipt, callback_url) do
    method = Enum.find(methods, &(&1["type"] == "WEB")) || List.first(methods) || %{}
    uri = method["uri"] || ""
    separator = if String.contains?(uri, "?"), do: "&", else: "?"
    "#{uri}#{separator}receipt=#{URI.encode_www_form(receipt)}&callback=#{URI.encode_www_form(callback_url)}"
  end

  defp build_wallet_redirect_url(wallet_callback_url, receipt, signature) do
    separator = if String.contains?(wallet_callback_url, "?"), do: "&", else: "?"
    base = "#{wallet_callback_url}#{separator}receipt=#{URI.encode_www_form(receipt)}"
    if signature, do: base <> "&signature=#{URI.encode_www_form(signature)}", else: base
  end

  defp status_for("REQUIRE_ADDITIONAL_AUTHENTICATION"), do: "AUTH_REQUIRED"
  defp status_for(outcome) when outcome in ["SUCCESS", "APPROVED", "COMPLETED", "ACTIVE"], do: "COMPLETED"
  defp status_for(_outcome), do: "FAILED"

  defp activate_token(session) do
    case Repo.get(Token, session.token_id) do
      nil -> :ok
      token -> Tokens.transition(token, "ACTIVE")
    end
  end
end
