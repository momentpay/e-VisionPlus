defmodule VmuCore.CMS.WalletQrPaymentCommand do
  @moduledoc """
  Digital Wallet Phase W3 (2026-07-28) — resolves a scanned QR (parsed
  via `CMS.WalletQrIdentity.parse/1`) into a real transfer through
  `CMS.WalletTransferCommand.transfer/1`. No new balance-movement logic
  here — QR is purely an encoding for "who to pay, and how much," not a
  new payment rail; the money movement is identical to any other
  wallet-to-wallet transfer.
  """

  alias VmuCore.CMS.{WalletQrIdentity, WalletTransferCommand}

  @doc """
  attrs = %{qr_string:, from_wallet_account_id:, initiated_by:,
            amount: (required only if the QR itself is open-amount)}

  Returns whatever `WalletTransferCommand.transfer/1` returns on
  success, or `{:error, reason}` where `reason` is one of
  `:invalid_format | :unsupported_version | :checksum_mismatch` (a bad
  QR), `:invalid_qr_account_id` (well-formed QR, but the encoded
  account id isn't even a valid UUID — corrupted or hand-crafted),
  `:amount_required` (open-amount QR scanned without a payer-entered
  amount), `:amount_mismatch` (payer entered an amount that doesn't
  match a fixed-amount QR), or anything `transfer/1` itself can return.
  """
  def pay(attrs) do
    with {:ok, qr} <- WalletQrIdentity.parse(attrs.qr_string),
         :ok <- validate_account_id(qr.wallet_account_id),
         {:ok, amount} <- resolve_amount(qr, attrs[:amount]) do
      WalletTransferCommand.transfer(%{
        from_wallet_account_id: attrs.from_wallet_account_id,
        to_wallet_account_id: qr.wallet_account_id,
        amount: amount,
        initiated_by: attrs.initiated_by,
        reason: blank_to_nil(qr.label)
      })
    end
  end

  defp validate_account_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> :ok
      :error -> {:error, :invalid_qr_account_id}
    end
  end

  defp resolve_amount(%{amount: nil}, nil), do: {:error, :amount_required}
  defp resolve_amount(%{amount: nil}, payer_amount), do: {:ok, payer_amount}
  defp resolve_amount(%{amount: qr_amount}, nil), do: {:ok, qr_amount}

  defp resolve_amount(%{amount: qr_amount}, payer_amount) do
    if Decimal.equal?(qr_amount, payer_amount) do
      {:ok, payer_amount}
    else
      {:error, :amount_mismatch}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(label), do: label
end
