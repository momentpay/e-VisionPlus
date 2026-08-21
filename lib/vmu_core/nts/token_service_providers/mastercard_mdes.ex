defmodule VmuCore.NTS.TokenServiceProviders.MastercardMdes do
  @moduledoc """
  Real Mastercard MDES Token Connect provider (NTS Phase B, 2026-07-31) —
  implements the "Push Provisioning" flow: the cardholder taps "Add to
  Google Pay" inside vmu_core's own app (or an admin does it on their
  behalf), and the issuer (us) pushes the account to Google Pay directly,
  rather than the cardholder adding it from inside the Google Pay app
  itself. Grounded in the real spec, `docs/nts/mdes-token-connect.yaml`.

  ## Honest scope of what this file can and can't do

  - **`provision_token/3`** is real: resolves Google Pay's Token
    Requestor ID via `getEligibleTokenRequestors` (or a configured
    override), encrypts the funding account via `NTS.
    MastercardPayloadEncryption`, and calls `pushMultipleAccounts`. It
    requests `requestIssuerInitiatedDigitizationData: true` so MDES
    returns the digitization result in-band — the only way this flow
    gets anything back at all, since Token Connect (this API) has **no
    documented inbound webhook**. Returns status `"PUSHED"`, `dpan: nil`
    — the real DPAN isn't confirmed synchronously by this API (see `NTS.
    Token`'s moduledoc on the PUSHED status). Extracting a DPAN out of
    the returned `issuerInitiatedDigitizationData` blob is NOT attempted
    here — its exact JSON shape isn't in the spec excerpt available,
    and guessing a field name inside real cardholder tokenization data
    is exactly the kind of assumption this codebase's discipline says
    not to make. The raw decoded blob is kept on the audit trail instead.
  - **`suspend_token/1`/`resume_token/1`/`delete_token/1` are honestly
    NOT implemented** — Token Connect (the spec available) only covers
    provisioning, not lifecycle management. A real implementation needs
    MDES's separate Digitization/Token Management API, which isn't in
    scope of the spec this was built against.

  Requires the cardholder's real PAN/expiry to be supplied by the caller
  in `device_info` (`"pan"`, `"expiry_month"`, `"expiry_year"`) — vmu_core
  never stores a raw PAN itself (`cta_cards.pan_token` is a one-way
  hash), so this data has to come from wherever the calling app/admin
  action legitimately holds it fresh (the cardholder re-entering it, or
  a vaulted reveal for a card issued with `CredentialVault`), used only
  transiently to build the encrypted request body — never logged, never
  persisted.
  """

  @behaviour VmuCore.NTS.TokenServiceProvider

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.CMS.{Account, DebitAccount, PrepaidAccount}
  alias VmuCore.Shared.LogoParameter
  alias VmuCore.NTS.MastercardMdesClient

  @impl true
  def provision_token(card, device_info, "GOOGLE_PAY") do
    with {:ok, pan} <- fetch(device_info, "pan"),
         {:ok, expiry_month} <- fetch(device_info, "expiry_month"),
         {:ok, expiry_year} <- fetch(device_info, "expiry_year"),
         {:ok, bin_prefix} <- resolve_bin_prefix(card),
         {:ok, requestor_id} <- resolve_google_pay_requestor_id(bin_prefix),
         funding_account = %{
           "cardAccountData" => %{
             "accountNumber" => pan, "expiryMonth" => expiry_month, "expiryYear" => expiry_year
           }
         },
         push_id = "CA-" <> Ecto.UUID.generate(),
         {:ok, %{"pushAccountReceipts" => [receipt | _]}} <-
           MastercardMdesClient.push_multiple_accounts(request_id(), requestor_id, funding_account, push_id) do
      {:ok, %{token_reference_id: receipt["pushAccountReceipt"], dpan: nil, status: "PUSHED"}}
    else
      {:ok, %{"pushAccountReceipts" => []}} -> {:error, :no_receipt_returned}
      {:error, reason} -> {:error, reason}
    end
  end

  def provision_token(_card, _device_info, other_wallet) do
    {:error, {:unsupported_wallet, other_wallet}}
  end

  @impl true
  def suspend_token(_token), do: {:error, :mdes_lifecycle_api_not_in_scope}

  @impl true
  def resume_token(_token), do: {:error, :mdes_lifecycle_api_not_in_scope}

  @impl true
  def delete_token(_token), do: {:error, :mdes_lifecycle_api_not_in_scope}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp fetch(map, key) do
    case map[key] || map[String.to_existing_atom(key)] do
      nil -> {:error, {:missing_field, key}}
      value -> {:ok, value}
    end
  rescue
    ArgumentError -> {:error, {:missing_field, key}}
  end

  defp resolve_bin_prefix(card) do
    scope =
      cond do
        card.account_id -> Repo.one(from a in Account, where: a.account_id == ^card.account_id, select: {a.sys_id, a.bank_id, a.logo_id})
        card.debit_account_id -> Repo.one(from a in DebitAccount, where: a.debit_account_id == ^card.debit_account_id, select: {a.sys_id, a.bank_id, a.logo_id})
        card.prepaid_account_id -> Repo.one(from a in PrepaidAccount, where: a.prepaid_account_id == ^card.prepaid_account_id, select: {a.sys_id, a.bank_id, a.logo_id})
        true -> nil
      end

    case scope do
      {sys_id, bank_id, logo_id} ->
        case Repo.get_by(LogoParameter, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id) do
          nil -> {:error, :logo_not_found}
          %{bin_prefix: prefix} -> {:ok, prefix}
        end

      nil ->
        {:error, :account_not_found}
    end
  end

  # No fixed Google Pay Token Requestor ID is configured anywhere in this
  # program yet — real Mastercard onboarding materials would supply one.
  # Falls back to discovering it live via getEligibleTokenRequestors and
  # matching on name, which is a real call against real data but a
  # best-effort match, not a confirmed identifier — prefer configuring
  # `config :vmu_core, :mdes, google_pay_token_requestor_id: "..."` once
  # a real one is known.
  defp resolve_google_pay_requestor_id(bin_prefix) do
    case Application.get_env(:vmu_core, :mdes, [])[:google_pay_token_requestor_id] do
      id when is_binary(id) ->
        {:ok, id}

      _ ->
        with {:ok, %{"tokenRequestors" => requestors}} <-
               MastercardMdesClient.get_eligible_token_requestors([bin_prefix], request_id()) do
          case Enum.find(requestors, &google_pay?/1) do
            nil -> {:error, :google_pay_not_eligible_for_this_bin}
            %{"tokenRequestorId" => id} -> {:ok, id}
          end
        end
    end
  end

  defp google_pay?(%{"tokenRequestorType" => "WALLET"} = requestor) do
    name = String.downcase(requestor["name"] || "") <> String.downcase(requestor["consumerFacingEntityName"] || "")
    String.contains?(name, "google")
  end

  defp google_pay?(_), do: false

  defp request_id, do: Ecto.UUID.generate()
end
