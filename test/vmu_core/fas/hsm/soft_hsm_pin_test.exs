defmodule VmuCore.FAS.HSM.SoftHsmPinTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Covers the redesigned PIN
  handling (Way4 parity plan Phase 0 item 7, 2026-07-24): `verify_pin/3`
  decodes a real ISO 9564 Format-0 PIN block (built here the same way a
  real DE52 value would be, XOR'd against the real PAN), never persists
  or returns the recovered digits, and compares against `CardPin.
  reference_pin_lmk` — set via `change_pin/3`'s dev-only "encrypted
  digits, no PAN" reference (see `SoftHSM`'s moduledoc for why
  change_pin can't use the real PAN-bound format).
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{Account, CardPin}
  alias VmuCore.FAS.HSM.SoftHSM
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Application.put_env(:vmu_core, :pin_max_tries, 3)
    :ok
  end

  defp parameter_hierarchy_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  defp account_fixture do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Pin", last_name: "Test#{n}",
        id_type: "PASSPORT", id_number: "PIN-TEST-#{n}"
      })
      |> Repo.insert!()

    %Account{}
    |> Account.changeset(%{
      customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
      block_id: block_id, pan_token: "pin-test-pan-#{n}", last_four: "4242",
      expiry_date: "1230", credit_limit: D.new("5000.00")
    })
    |> Repo.insert!()
  end

  # The real inverse of SoftHSM's private decode_pin_block/2 — builds a
  # genuine ISO 9564 Format-0 PIN block, exactly as a real DE52 value
  # would arrive, so verify_pin/3's real ISO decode path is exercised.
  defp encode_pin_block(pin_digits, pan) do
    len = String.length(pin_digits)
    pin_nibbles = pin_digits |> String.graphemes() |> Enum.map(&String.to_integer/1)
    padded_nibbles = (pin_nibbles ++ List.duplicate(0xF, 14 - length(pin_nibbles)))
    pin_field_nibbles = [0, len] ++ padded_nibbles
    pin_field = nibbles_to_binary(pin_field_nibbles)

    pan_clean = String.replace(pan, ~r/\D/, "")
    pan_no_chk = String.slice(pan_clean, 0..-2//1)
    pan_12 = pan_no_chk |> String.slice(-12..-1) |> String.pad_leading(12, "0")
    pan_block = Base.decode16!("0000" <> pan_12, case: :mixed)

    :crypto.exor(pin_field, pan_block) |> Base.encode16(case: :lower)
  end

  defp nibbles_to_binary(nibbles) do
    nibbles
    |> Enum.chunk_every(2)
    |> Enum.map(fn [hi, lo] -> <<hi::4, lo::4>> end)
    |> IO.iodata_to_binary()
  end

  describe "change_pin/3 then verify_pin/3 round trip" do
    test "the newly-set PIN verifies successfully via a real ISO block" do
      account = account_fixture()

      %CardPin{}
      |> CardPin.changeset(%{pan_token: account.pan_token, reference_pin_lmk: SoftHSM.encrypt_reference_dev("0000")})
      |> Repo.insert!()

      assert :ok = SoftHSM.change_pin(account.pan_token, "0000", "4321")

      block = encode_pin_block("4321", "4242420000004242")
      assert :ok = SoftHSM.verify_pin(block, "4242420000004242", account.pan_token)

      reloaded = Repo.get_by!(CardPin, pan_token: account.pan_token)
      assert reloaded.try_counter == 0
      # Never a plaintext digit anywhere in the stored value.
      refute reloaded.reference_pin_lmk =~ "4321"
    end

    test "a wrong PIN block increments try_counter and fails" do
      account = account_fixture()

      %CardPin{}
      |> CardPin.changeset(%{pan_token: account.pan_token, reference_pin_lmk: SoftHSM.encrypt_reference_dev("0000")})
      |> Repo.insert!()

      :ok = SoftHSM.change_pin(account.pan_token, "0000", "1234")

      wrong_block = encode_pin_block("9999", "4242420000004242")
      assert {:error, :wrong_pin} = SoftHSM.verify_pin(wrong_block, "4242420000004242", account.pan_token)

      reloaded = Repo.get_by!(CardPin, pan_token: account.pan_token)
      assert reloaded.try_counter == 1
    end

    test "exceeding max tries locks the PIN" do
      account = account_fixture()

      %CardPin{}
      |> CardPin.changeset(%{pan_token: account.pan_token, reference_pin_lmk: SoftHSM.encrypt_reference_dev("0000")})
      |> Repo.insert!()

      :ok = SoftHSM.change_pin(account.pan_token, "0000", "1234")
      wrong_block = encode_pin_block("9999", "4242420000004242")

      {:error, :wrong_pin} = SoftHSM.verify_pin(wrong_block, "4242420000004242", account.pan_token)
      {:error, :wrong_pin} = SoftHSM.verify_pin(wrong_block, "4242420000004242", account.pan_token)
      assert {:error, :pin_blocked} = SoftHSM.verify_pin(wrong_block, "4242420000004242", account.pan_token)

      reloaded = Repo.get_by!(CardPin, pan_token: account.pan_token)
      assert reloaded.pin_locked_at
    end

    test "changing the PIN requires the correct old PIN" do
      account = account_fixture()

      %CardPin{}
      |> CardPin.changeset(%{pan_token: account.pan_token, reference_pin_lmk: SoftHSM.encrypt_reference_dev("0000")})
      |> Repo.insert!()

      :ok = SoftHSM.change_pin(account.pan_token, "0000", "1111")
      assert {:error, :wrong_pin} = SoftHSM.change_pin(account.pan_token, "9999", "2222")
    end

    test "verify_pin/3 for a pan_token with no CardPin row is pin_not_set" do
      account = account_fixture()
      block = encode_pin_block("1234", "4242420000004242")

      assert {:error, :pin_not_set} = SoftHSM.verify_pin(block, "4242420000004242", account.pan_token)
    end
  end

  # Phase 10: verify_pin/3 previously assumed pin_block_hex arrived already
  # in the clear (PIN field XOR PAN field) form. Real network traffic never
  # looks like that - it's encrypted under whatever ZPK the network leg's
  # HSM translated it to (see HsmSimulator.Crypto for the acquirer-side
  # counterpart). These tests build a block the same way, encrypting the
  # clear ISO block under a locally-defined test ZPK with the same 2-key
  # 3DES (K1|K2|K1) + ECB-via-zero-IV-CBC technique the implementation
  # uses, to prove the new decrypt step in decode_pin_block/2 actually
  # works - not just that the old clear-block tests above still pass.
  describe "verify_pin/3 with a configured ZPK (Phase 10 - real encrypted PIN block)" do
    @zpk Base.decode16!(String.duplicate("AA", 8) <> String.duplicate("BB", 8))

    setup do
      Application.put_env(:vmu_core, :soft_hsm, zpk: @zpk)
      on_exit(fn -> Application.delete_env(:vmu_core, :soft_hsm) end)
      :ok
    end

    defp des_ede3_ecb_encrypt(key16, data) do
      key24 = binary_part(key16, 0, 8) <> binary_part(key16, 8, 8) <> binary_part(key16, 0, 8)

      for(<<block::binary-8 <- data>>, do: block)
      |> Enum.map(&:crypto.crypto_one_time(:des_ede3_cbc, key24, <<0::64>>, &1, true))
      |> :binary.list_to_bin()
    end

    defp encrypt_pin_block_under_zpk(pin_digits, pan) do
      clear = encode_pin_block(pin_digits, pan) |> Base.decode16!(case: :mixed)
      des_ede3_ecb_encrypt(@zpk, clear) |> Base.encode16(case: :lower)
    end

    test "a genuinely ZPK-encrypted PIN block verifies correctly" do
      account = account_fixture()

      %CardPin{}
      |> CardPin.changeset(%{pan_token: account.pan_token, reference_pin_lmk: SoftHSM.encrypt_reference_dev("0000")})
      |> Repo.insert!()

      :ok = SoftHSM.change_pin(account.pan_token, "0000", "4321")

      encrypted_block = encrypt_pin_block_under_zpk("4321", "4242420000004242")
      assert :ok = SoftHSM.verify_pin(encrypted_block, "4242420000004242", account.pan_token)
    end

    test "a wrong PIN, correctly encrypted under the ZPK, is a real decline" do
      account = account_fixture()

      %CardPin{}
      |> CardPin.changeset(%{pan_token: account.pan_token, reference_pin_lmk: SoftHSM.encrypt_reference_dev("0000")})
      |> Repo.insert!()

      :ok = SoftHSM.change_pin(account.pan_token, "0000", "1234")

      wrong_encrypted_block = encrypt_pin_block_under_zpk("9999", "4242420000004242")
      assert {:error, :wrong_pin} = SoftHSM.verify_pin(wrong_encrypted_block, "4242420000004242", account.pan_token)
    end

    test "the same encrypted block is rejected without the ZPK configured (proves it's really encrypted, not accidentally still clear)" do
      account = account_fixture()

      %CardPin{}
      |> CardPin.changeset(%{pan_token: account.pan_token, reference_pin_lmk: SoftHSM.encrypt_reference_dev("0000")})
      |> Repo.insert!()

      :ok = SoftHSM.change_pin(account.pan_token, "0000", "4321")

      encrypted_block = encrypt_pin_block_under_zpk("4321", "4242420000004242")

      Application.delete_env(:vmu_core, :soft_hsm)
      assert {:error, :wrong_pin} = SoftHSM.verify_pin(encrypted_block, "4242420000004242", account.pan_token)
    end
  end
end
