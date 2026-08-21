defmodule VmuCore.FAS.HSM.ProductionHSMTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking of vmu_core's own code. HTTP to
  Veriscent is faked via `Req.Test` (a real Plug pipeline — see
  `config/test.exs`'s `:veriscent_hsm_http_plug`), returning response
  shapes built from the real payShield 10K Core Host Commands manual
  (page references in `ProductionHSM`'s moduledoc), since live
  connectivity itself is unverified (expired reference certificate).
  Covers real config resolution (`VmuCore.FAS.ConfigCatalog`, real
  `ParameterEngine.resolve_bin/1`/BIN→scheme lookup) and real request/
  response handling for CY/KW/BE — Way4 parity plan Phase 0 item 7
  (2026-07-24).
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{Account, CardPin}
  alias VmuCore.FAS.HSM.ProductionHSM
  alias VmuCore.FAS.HSM.ProductionHSM.HttpClient
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, ModuleConfigWriter,
                        ParameterEngine, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp bank_scoped_fixture(card_scheme \\ "VISA", opts \\ []) do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()

    %LogoParameter{}
    |> LogoParameter.changeset(%{
      sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242",
      description: "test", card_scheme: card_scheme
    })
    |> Repo.insert!()

    %BlockParameter{}
    |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id})
    |> Repo.insert!()

    ParameterEngine.refresh_all()

    unless Keyword.get(opts, :skip_fas_config, false) do
      ModuleConfigWriter.put("fas", "cvk", "TEST-CVK-HEX", %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)
      ModuleConfigWriter.put("fas", "mk_ac", "TEST-MKAC-HEX", %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)
      ModuleConfigWriter.put("fas", "zpk", "TEST-ZPK-HEX", %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)
    end

    %{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}
  end

  defp account_fixture(scope) do
    %{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id} = scope
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Hsm", last_name: "Test#{n}",
        id_type: "PASSPORT", id_number: "HSM-TEST-#{n}"
      })
      |> Repo.insert!()

    %Account{}
    |> Account.changeset(%{
      customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
      block_id: block_id, pan_token: "hsm-test-pan-#{n}", last_four: "4242",
      expiry_date: "1230", credit_limit: D.new("5000.00")
    })
    |> Repo.insert!()
  end

  defp stub_hsm(fun), do: Req.Test.stub(HttpClient, fun)

  describe "verify_cvv/4" do
    test "a matching CVV (errorCode 00) is :ok" do
      bank_scoped_fixture()
      pan = "4242420000000000"

      stub_hsm(fn conn -> Req.Test.json(conn, %{"messageHeader" => "1235", "responseCode" => "CZ", "errorCode" => "00"}) end)

      assert :ok = ProductionHSM.verify_cvv(pan, "2512", "000", "123")
    end

    test "CVV failed verification (errorCode 01)" do
      bank_scoped_fixture()
      pan = "4242420000000000"

      stub_hsm(fn conn -> Req.Test.json(conn, %{"errorCode" => "01"}) end)

      assert {:error, :cvv_mismatch} = ProductionHSM.verify_cvv(pan, "2512", "000", "123")
    end

    test "an unrecognized BIN is a clean error, never calls the HSM" do
      stub_hsm(fn _conn -> raise "should not be called" end)

      assert {:error, :no_bin_match} = ProductionHSM.verify_cvv("9999990000000000", "2512", "000", "123")
    end

    test "a bank with no cvk configured is a clean not-configured error" do
      bank_scoped_fixture("VISA", skip_fas_config: true)
      pan = "4242420000000000"

      stub_hsm(fn _conn -> raise "should not be called" end)

      assert {:error, :not_configured} = ProductionHSM.verify_cvv(pan, "2512", "000", "123")
    end
  end

  describe "verify_arqc/6" do
    test "a verified ARQC (errorCode 00) is :ok" do
      bank_scoped_fixture()
      pan = "4242420000000000"

      stub_hsm(fn conn -> Req.Test.json(conn, %{"errorCode" => "00"}) end)

      assert :ok =
               ProductionHSM.verify_arqc(pan, "tok", <<0, 1>>, <<1, 2, 3, 4>>, <<0::64>>, <<1::64>>)
    end

    test "a non-00 errorCode is an arqc_mismatch" do
      bank_scoped_fixture()
      pan = "4242420000000000"

      stub_hsm(fn conn -> Req.Test.json(conn, %{"errorCode" => "01"}) end)

      assert {:error, :arqc_mismatch} =
               ProductionHSM.verify_arqc(pan, "tok", <<0, 1>>, <<1, 2, 3, 4>>, <<0::64>>, <<1::64>>)
    end

    test "an unmapped card scheme is a clean error, never calls the HSM" do
      bank_scoped_fixture("DINERS")
      pan = "4242420000000000"

      stub_hsm(fn _conn -> raise "should not be called" end)

      assert {:error, _} = ProductionHSM.verify_arqc(pan, "tok", <<0, 1>>, <<1, 2, 3, 4>>, <<0::64>>, <<1::64>>)
    end
  end

  describe "generate_arpc/6" do
    test "a successful generation decodes the returned MAC" do
      bank_scoped_fixture()
      pan = "4242420000000000"
      mac = :crypto.strong_rand_bytes(8)

      stub_hsm(fn conn -> Req.Test.json(conn, %{"errorCode" => "00", "mac" => Base.encode16(mac, case: :lower)}) end)

      assert {:ok, ^mac} =
               ProductionHSM.generate_arpc(pan, <<0, 1>>, <<1, 2, 3, 4>>, <<1::64>>, <<0, 0>>, "tok")
    end

    test "a non-00 errorCode is a clean hsm_error" do
      bank_scoped_fixture()
      pan = "4242420000000000"

      stub_hsm(fn conn -> Req.Test.json(conn, %{"errorCode" => "05"}) end)

      assert {:error, {:hsm_error, "05"}} =
               ProductionHSM.generate_arpc(pan, <<0, 1>>, <<1, 2, 3, 4>>, <<1::64>>, <<0, 0>>, "tok")
    end
  end

  describe "verify_pin/3 (BE comparison method)" do
    test "a matching PIN block (errorCode 00) is :ok" do
      scope = bank_scoped_fixture()
      account = account_fixture(scope)

      %CardPin{}
      |> CardPin.changeset(%{pan_token: account.pan_token, reference_pin_lmk: "LMK-REF-HEX"})
      |> Repo.insert!()

      stub_hsm(fn conn -> Req.Test.json(conn, %{"errorCode" => "00"}) end)

      assert :ok = ProductionHSM.verify_pin("DEADBEEFDEADBEEF", "4242420000000000", account.pan_token)
    end

    test "a PIN verification failure (errorCode 01) is wrong_pin" do
      scope = bank_scoped_fixture()
      account = account_fixture(scope)

      %CardPin{}
      |> CardPin.changeset(%{pan_token: account.pan_token, reference_pin_lmk: "LMK-REF-HEX"})
      |> Repo.insert!()

      stub_hsm(fn conn -> Req.Test.json(conn, %{"errorCode" => "01"}) end)

      assert {:error, :wrong_pin} = ProductionHSM.verify_pin("DEADBEEFDEADBEEF", "4242420000000000", account.pan_token)
    end

    test "no CardPin row for this pan_token is pin_not_set, never calls the HSM" do
      scope = bank_scoped_fixture()
      account = account_fixture(scope)

      stub_hsm(fn _conn -> raise "should not be called" end)

      assert {:error, :pin_not_set} = ProductionHSM.verify_pin("DEADBEEFDEADBEEF", "4242420000000000", account.pan_token)
    end

    test "the incoming pin_block_hex is passed straight through, never decoded" do
      scope = bank_scoped_fixture()
      account = account_fixture(scope)

      %CardPin{}
      |> CardPin.changeset(%{pan_token: account.pan_token, reference_pin_lmk: "LMK-REF-HEX"})
      |> Repo.insert!()

      test_pid = self()

      stub_hsm(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(body)})
        Req.Test.json(conn, %{"errorCode" => "00"})
      end)

      assert :ok = ProductionHSM.verify_pin("DEADBEEFDEADBEEF", "4242420000000000", account.pan_token)

      assert_received {:request_body, body}
      assert body["pinBlock"] == "DEADBEEFDEADBEEF"
      assert body["pin"] == "LMK-REF-HEX"
    end
  end

  describe "change_pin/3" do
    test "remains not_implemented — architecturally blocked, see moduledoc" do
      assert {:error, :not_implemented} = ProductionHSM.change_pin("tok", "1234", "5678")
    end
  end
end
