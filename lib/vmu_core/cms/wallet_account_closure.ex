defmodule VmuCore.CMS.WalletAccountClosure do
  @moduledoc """
  Closes a `WalletAccount` (Digital Wallet Phase W1, 2026-07-28).

  Requires a zero balance first — same "closure pending until zero
  balance" principle `CMS.Account`'s own CMS-G3 lifecycle documents,
  simplified here to a direct check rather than a full pending-closure
  state machine (no product in this codebase has built that machine
  yet — `CMS.DebitAccount`/`CMS.PrepaidAccount` both carry a `closed_at`
  field with no closure command behind it at all).
  """

  alias VmuCore.{Repo, CMS.WalletAccount}

  @spec close(Ecto.UUID.t()) :: {:ok, WalletAccount.t()} | {:error, term()}
  def close(wallet_account_id) do
    case Repo.get(WalletAccount, wallet_account_id) do
      nil ->
        {:error, :not_found}

      %WalletAccount{status: "CLOSED"} ->
        {:error, :already_closed}

      %WalletAccount{available_balance: balance} = account ->
        if Decimal.equal?(balance, Decimal.new(0)) do
          account
          |> WalletAccount.changeset(%{status: "CLOSED", closed_at: Date.utc_today()})
          |> Repo.update()
        else
          {:error, :balance_not_zero}
        end
    end
  end
end
