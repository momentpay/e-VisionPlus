defmodule VmuCore.CTA.CredentialVaultTest do
  @moduledoc """
  Real GenServer/ETS, no mocking — `CredentialVault` runs app-wide (see
  `VmuCore.Application`), this test uses the already-running instance.
  Way4 parity plan Phase 1 item 1 (2026-07-25).
  """

  use ExUnit.Case, async: false

  alias VmuCore.CTA.CredentialVault

  test "put/2 then reveal/1 returns the credentials exactly once" do
    card_id = Ecto.UUID.generate()
    creds = %{pan: "4242420000001234", cvv: "123", expiry: "2812"}

    :ok = CredentialVault.put(card_id, creds)

    assert {:ok, ^creds} = CredentialVault.reveal(card_id)
    assert {:error, :not_found} = CredentialVault.reveal(card_id)
  end

  test "reveal/1 for an id that was never stored returns :not_found" do
    assert {:error, :not_found} = CredentialVault.reveal(Ecto.UUID.generate())
  end

  test "two different card_ids don't interfere with each other" do
    id1 = Ecto.UUID.generate()
    id2 = Ecto.UUID.generate()

    :ok = CredentialVault.put(id1, %{pan: "1111", cvv: "111", expiry: "2801"})
    :ok = CredentialVault.put(id2, %{pan: "2222", cvv: "222", expiry: "2802"})

    assert {:ok, %{pan: "2222"}} = CredentialVault.reveal(id2)
    assert {:ok, %{pan: "1111"}} = CredentialVault.reveal(id1)
  end
end
