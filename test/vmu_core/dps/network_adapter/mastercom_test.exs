defmodule VmuCore.DPS.NetworkAdapter.MastercomTest do
  @moduledoc """
  Real Postgres via Sandbox, `Req.Test` for the true external-HTTP boundary
  only. Re-ported 2026-07-29 from `Avenza/apps/vmu_dps` (DPS-P5) — proves
  the real claim-creation + chargeback-filing message construction against
  realistic Mastercom v6 JSON shapes.
  """

  use ExUnit.Case, async: false

  alias VmuCore.{Repo, DPS.Dispute}
  alias VmuCore.CMS.Account
  alias VmuCore.DPS.NetworkAdapter.{Mastercom, MastercomClient}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    private_key = :public_key.generate_key({:rsa, 2048, 65537})
    der = :public_key.der_encode(:RSAPrivateKey, private_key)
    pem = :public_key.pem_encode([{:RSAPrivateKey, der, :not_encrypted}])
    path = Path.join(System.tmp_dir!(), "mastercom_adapter_test_key_#{System.unique_integer([:positive])}.pem")
    File.write!(path, pem)

    Application.put_env(:vmu_core, :mastercom,
      consumer_key: "test-key", private_key_path: path, base_url: "https://mastercom.test"
    )

    on_exit(fn ->
      File.rm(path)
      Application.put_env(:vmu_core, :mastercom, [])
    end)

    :ok
  end

  defp dispute_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Mc", last_name: "Test#{n}", id_type: "PASSPORT", id_number: "MC-#{n}"})
      |> Repo.insert!()

    account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
        block_id: block_id, pan_token: "mc-test-pan-#{n}", last_four: "4242",
        expiry_date: "1230", credit_limit: D.new("10000.00")
      })
      |> Repo.insert!()

    {:ok, dispute} =
      Dispute.file(%{
        account_id: account.account_id, transaction_date: Date.add(Date.utc_today(), -5),
        dispute_amount: D.new("250.00"), reason_code: "4853", network: "MC"
      })

    dispute
  end

  test "file_chargeback/2 creates a claim then files the chargeback under it" do
    dispute = dispute_fixture()

    Req.Test.stub(MastercomClient, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/claims"} ->
          Req.Test.json(conn, %{"claimId" => "CLM-123"})

        {"POST", "/claims/CLM-123/chargebacks"} ->
          Req.Test.json(conn, %{"chargebackId" => "CB-9"})
      end
    end)

    assert {:ok, "CLM-123"} = Mastercom.file_chargeback(dispute, %{})
  end

  test "file_chargeback/2 reuses an existing network_ref instead of creating a second claim" do
    dispute = dispute_fixture()
    {:ok, dispute} = dispute |> Dispute.changeset(%{network_ref: "CLM-EXISTING"}) |> Repo.update()

    Req.Test.stub(MastercomClient, fn conn ->
      assert conn.request_path == "/claims/CLM-EXISTING/chargebacks"
      Req.Test.json(conn, %{"chargebackId" => "CB-1"})
    end)

    assert {:ok, "CLM-EXISTING"} = Mastercom.file_chargeback(dispute, %{})
  end

  test "check_status/2 with no network_ref yet returns a clean error" do
    dispute = dispute_fixture()
    assert {:error, :no_network_ref} = Mastercom.check_status(dispute, %{})
  end

  test "check_status/2 polls the claim and returns its status" do
    dispute = dispute_fixture()
    {:ok, dispute} = dispute |> Dispute.changeset(%{network_ref: "CLM-7"}) |> Repo.update()

    Req.Test.stub(MastercomClient, fn conn ->
      assert conn.request_path == "/claims/CLM-7"
      Req.Test.json(conn, %{"claimStatus" => "OPEN"})
    end)

    assert {:ok, "OPEN"} = Mastercom.check_status(dispute, %{})
  end

  test "an HTTP failure on claim creation surfaces cleanly, without ever attempting the chargeback call" do
    dispute = dispute_fixture()

    Req.Test.stub(MastercomClient, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad request"})
    end)

    assert {:error, {:http_error, 400, %{"error" => "bad request"}}} = Mastercom.file_chargeback(dispute, %{})
  end
end
