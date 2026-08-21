defmodule VmuCore.CMS.WalletVelocityLimits do
  @moduledoc """
  Enforces `WalletAccount.velocity_limits` — Digital Wallet Phase W5 follow-up
  (2026-07-29), closing `docs/wallet/DIGITAL_WALLET_Module_Requirements.md`'s
  W009. `velocity_limits` (`%{"DAILY" => %{"count", "amount"}, "MONTHLY" =>
  %{"amount"}}`) has existed on the account and been admin-editable since
  Phase W1/W4's "Change Limits" action, but until now nothing ever read it —
  purely inert configuration. This module is the read side.

  Checked against money moving INTO a wallet (`WalletFundingCommand.fund/1`
  is the single call site — it covers both external loads and the receiver
  leg of an internal wallet-to-wallet transfer).

  An account with no configured limits (`velocity_limits == %{}`, the
  default since every wallet was created) is unlimited — absence of config
  means no cap, not a cap of zero, so existing/seeded accounts aren't
  suddenly blocked by this.
  """

  import Ecto.Query

  alias Decimal, as: D
  alias VmuCore.Repo
  alias VmuCore.CMS.{WalletAccount, WalletFunding}

  @type violation :: %{type: String.t(), limit: number(), attempted: D.t() | integer()}

  @spec check(WalletAccount.t(), D.t()) :: :ok | {:error, violation()}
  def check(%WalletAccount{velocity_limits: limits}, _amount) when limits in [nil, %{}], do: :ok

  def check(%WalletAccount{velocity_limits: limits} = account, amount) do
    daily = Map.get(limits, "DAILY", %{})
    monthly = Map.get(limits, "MONTHLY", %{})

    with :ok <- check_count(account, daily["count"]),
         :ok <- check_amount(account, daily["amount"], amount, :day, "DAILY_AMOUNT"),
         :ok <- check_amount(account, monthly["amount"], amount, :month, "MONTHLY_AMOUNT") do
      :ok
    end
  end

  defp check_count(_account, nil), do: :ok

  defp check_count(account, cap) do
    count = funding_count_since(account.wallet_account_id, window_start(:day))

    if count + 1 > cap do
      {:error, %{type: "DAILY_COUNT", limit: cap, attempted: count + 1}}
    else
      :ok
    end
  end

  defp check_amount(_account, nil, _amount, _period, _type), do: :ok

  defp check_amount(account, cap, amount, period, type) do
    total = funding_total_since(account.wallet_account_id, window_start(period))
    new_total = D.add(total, amount)
    cap_d = D.new(to_string(cap))

    if D.compare(new_total, cap_d) == :gt do
      {:error, %{type: type, limit: cap, attempted: new_total}}
    else
      :ok
    end
  end

  defp window_start(:day) do
    Date.utc_today() |> DateTime.new!(~T[00:00:00])
  end

  defp window_start(:month) do
    today = Date.utc_today()
    Date.new!(today.year, today.month, 1) |> DateTime.new!(~T[00:00:00])
  end

  defp funding_count_since(wallet_account_id, since) do
    Repo.one(
      from f in WalletFunding,
        where: f.wallet_account_id == ^wallet_account_id and f.inserted_at >= ^since,
        select: count(f.id)
    ) || 0
  end

  defp funding_total_since(wallet_account_id, since) do
    Repo.one(
      from f in WalletFunding,
        where: f.wallet_account_id == ^wallet_account_id and f.inserted_at >= ^since,
        select: sum(f.amount)
    ) || D.new(0)
  end
end
