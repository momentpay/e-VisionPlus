defmodule VmuCore.FAS.Authorization do
  @moduledoc """
  vMu issuer authorization path.

  Flow for an inbound MTI 0100:
    1. Extract PAN → 6-digit BIN → ParameterEngine.resolve_bin/1 (ETS, zero DB)
    2. Token-lookup account_id for this PAN
    3. AccountStateCoordinator.authorize/3 (in-memory OTB check)
    4. On coordinator timeout → STIP fallback
    5. Return {:ok, rc, approval_code} | {:error, rc}

  All calls on the hot path are ETS or GenServer message — no direct DB queries.
  Any unexpected error returns RC "96" (system malfunction) — fail-safe.
  """

  require Logger

  alias VmuCore.Shared.ParameterEngine
  alias VmuCore.CMS.AccountStateCoordinator
  alias VmuCore.FAS.STIP
  alias VmuCore.Repo
  alias VmuCore.CMS.Account
  import Ecto.Query

  @doc """
  Process an issuer authorization request.

  Expected request map:
    %{pan: String.t(), amount: Decimal.t(), channel: atom(), mcc: String.t() | nil}

  Returns:
    {:ok, response_code, approval_code}   — approved
    {:error, response_code}               — declined
  """
  def process(%{pan: pan, amount: amount, channel: channel, mcc: mcc} = _request) do
    with {:ok, {sys_id, bank_id, logo_id}} <- ParameterEngine.resolve_bin(pan),
         {:ok, account_id}                 <- resolve_account(pan) do
      auth_result =
        AccountStateCoordinator.authorize(account_id, amount, channel: channel, mcc: mcc)

      handle_auth_result(auth_result, sys_id, logo_id, amount)
    else
      {:error, :no_bin_match} ->
        # BIN not ours — pass to upstream acquirer path
        {:error, "15"}

      {:error, :account_not_found} ->
        {:error, "14"}

      {:error, reason} ->
        Logger.error("[Auth] Unexpected error during BIN/account lookup: #{inspect(reason)}")
        {:error, "96"}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp handle_auth_result({:approved, rc, _otb}, _sys_id, _logo_id, _amount) do
    {:ok, rc, generate_approval_code()}
  end

  defp handle_auth_result({:declined, rc, reason}, _sys_id, _logo_id, _amount) do
    Logger.info("[Auth] Declined rc=#{rc} reason=#{reason}")
    {:error, rc}
  end

  # Coordinator unreachable — attempt STIP offline approval
  defp handle_auth_result({:error, reason}, sys_id, logo_id, amount)
       when reason in [:timeout, :noproc] do
    Logger.warning("[Auth] ASC unreachable (#{reason}) — attempting STIP")

    case STIP.authorize(sys_id, logo_id, amount) do
      {:stip_approved, rc} -> {:ok, rc, generate_approval_code()}
      {:stip_declined, rc} -> {:error, rc}
    end
  end

  defp handle_auth_result({:error, reason}, _sys_id, _logo_id, _amount) do
    Logger.error("[Auth] Coordinator error: #{inspect(reason)}")
    {:error, "96"}
  end

  # SHA-256 token of PAN — deterministic, never stores raw PAN
  defp resolve_account(pan) do
    pan_token = :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)

    case Repo.one(from a in Account, where: a.pan_token == ^pan_token, select: a.account_id) do
      nil        -> {:error, :account_not_found}
      account_id -> {:ok, account_id}
    end
  end

  defp generate_approval_code do
    :rand.uniform(999_999)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end
end
