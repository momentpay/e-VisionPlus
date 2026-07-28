defmodule VmuCore.CMS.WalletQrIdentityTest do
  @moduledoc """
  Pure unit tests, no DB — Digital Wallet Phase W3 (2026-07-28), the QR
  wire-format encode/decode itself.
  """

  use ExUnit.Case, async: true

  alias VmuCore.CMS.WalletQrIdentity
  alias Decimal, as: D

  test "generate/parse round-trips a fixed-amount QR" do
    account_id = Ecto.UUID.generate()
    qr = WalletQrIdentity.generate(account_id, "AED", D.new("25.50"), "Coffee")

    assert {:ok, decoded} = WalletQrIdentity.parse(qr)
    assert decoded.wallet_account_id == account_id
    assert decoded.currency == "AED"
    assert D.equal?(decoded.amount, D.new("25.50"))
    assert decoded.label == "Coffee"
  end

  test "generate/parse round-trips an open-amount QR (amount nil)" do
    account_id = Ecto.UUID.generate()
    qr = WalletQrIdentity.generate(account_id, "AED")

    assert {:ok, decoded} = WalletQrIdentity.parse(qr)
    assert is_nil(decoded.amount)
    assert decoded.label == ""
  end

  test "a tampered field is caught by the checksum" do
    account_id = Ecto.UUID.generate()
    qr = WalletQrIdentity.generate(account_id, "AED", D.new("25.50"), "Coffee")

    tampered = String.replace(qr, "25.50", "999.00")
    assert {:error, :checksum_mismatch} = WalletQrIdentity.parse(tampered)
  end

  test "an unsupported version is rejected" do
    account_id = Ecto.UUID.generate()
    qr = WalletQrIdentity.generate(account_id, "AED")
    v2_qr = String.replace(qr, "WAL|v1|", "WAL|v2|")

    assert {:error, :unsupported_version} = WalletQrIdentity.parse(v2_qr)
  end

  test "garbage input is rejected as invalid format" do
    assert {:error, :invalid_format} = WalletQrIdentity.parse("not a qr code")
    assert {:error, :invalid_format} = WalletQrIdentity.parse("")
    assert {:error, :invalid_format} = WalletQrIdentity.parse(nil)
  end

  test "a pipe character in the label is stripped, not left to corrupt the wire format" do
    account_id = Ecto.UUID.generate()
    qr = WalletQrIdentity.generate(account_id, "AED", nil, "Rent | Utilities")

    assert {:ok, decoded} = WalletQrIdentity.parse(qr)
    assert decoded.label == "Rent  Utilities"
  end
end
