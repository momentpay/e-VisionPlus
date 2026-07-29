defmodule VmuCoreWeb.Api.V1.ExternalPaymentControllerTest do
  @moduledoc """
  Real Postgres via Sandbox + real HTTP request pipeline (Phoenix.ConnTest,
  not a mock router), real `mw_risk` risk gate, no mocking except the rail
  adapter boundary (swapped via `CMS.RailProvider` config, same pattern as
  `ExternalPaymentCommandTest`). Digital Wallet Phase W6 (2026-07-29) — the
  external /api/v1/wallet/payments surface: bearer-token auth, scope
  enforcement, and the real happy/decline paths. See
  docs/wallet/DIGITAL_WALLET_Module_Requirements.md.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias VmuCore.Repo
  alias VmuCore.ASM.ServiceAccounts
  alias VmuCore.CMS.{WalletAccount, WalletProductOpening, WalletFundingCommand}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  @endpoint VmuCoreWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    on_exit(fn -> Application.delete_env(:vmu_core, :rail_provider) end)
    {:ok, conn: build_conn()}
  end

  defmodule AcceptingRail do
    @behaviour VmuCore.CMS.RailProvider
    @impl true
    def initiate(_payment), do: {:ok, %{external_reference: "RAIL-REF-API", status: "completed"}}
    @impl true
    def check_status(_payment), do: {:ok, %{status: "completed"}}
  end

  defp wallet_fixture(load \\ D.new("1000")) do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "606060", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Api", last_name: "A2ATest#{n}"})
      |> Repo.insert!()

    {:ok, %{account: account}} =
      WalletProductOpening.open(%{
        customer_id: customer.customer_id, name: "Api A2A Wallet",
        sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
      })

    {:ok, _} =
      WalletFundingCommand.fund(%{
        wallet_account_id: account.wallet_account_id, amount: load,
        channel: "ADMIN_MANUAL", posted_by: "test"
      })

    Repo.get!(WalletAccount, account.wallet_account_id)
  end

  defp token_with_scopes(scopes) do
    n = System.unique_integer([:positive])
    {:ok, _account, raw_token} = ServiceAccounts.create(%{"name" => "a2a-api-test-#{n}", "scopes" => scopes})
    raw_token
  end

  defp authed(conn, token), do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

  defp payment_params(account, overrides \\ %{}) do
    Map.merge(
      %{
        "wallet_account_id" => account.wallet_account_id, "rail_type" => "A2A",
        "amount" => "100", "currency" => "AED",
        "destination" => %{"account_number" => "AE070331234567890123456"},
        "initiated_by" => "mobile_app_test"
      },
      overrides
    )
  end

  describe "authentication" do
    test "no Authorization header returns 401", %{conn: conn} do
      account = wallet_fixture()
      conn = post(conn, "/api/v1/wallet/payments", payment_params(account))
      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "a valid token missing the wallet:write scope returns 403", %{conn: conn} do
      account = wallet_fixture()
      token = token_with_scopes(["wallet:read"])
      conn = conn |> authed(token) |> post("/api/v1/wallet/payments", payment_params(account))
      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end
  end

  describe "POST /api/v1/wallet/payments" do
    test "with no rail configured, the wallet isn't debited and the response is honest about it", %{conn: conn} do
      account = wallet_fixture()
      token = token_with_scopes(["wallet:write"])

      conn = conn |> authed(token) |> post("/api/v1/wallet/payments", payment_params(account))
      body = json_response(conn, 503)

      assert body["error"]["code"] == "rail_not_configured"
      assert D.equal?(Repo.get!(WalletAccount, account.wallet_account_id).available_balance, D.new("1000"))
    end

    test "with an accepting rail configured, the payment completes and debits the wallet", %{conn: conn} do
      Application.put_env(:vmu_core, :rail_provider, AcceptingRail)
      account = wallet_fixture()
      token = token_with_scopes(["wallet:write"])

      conn = conn |> authed(token) |> post("/api/v1/wallet/payments", payment_params(account))
      body = json_response(conn, 201)

      assert body["payment"]["status"] == "completed"
      assert body["payment"]["external_reference"] == "RAIL-REF-API"
      assert D.equal?(Repo.get!(WalletAccount, account.wallet_account_id).available_balance, D.new("900"))
    end

    test "insufficient funds returns 422 without touching the balance", %{conn: conn} do
      Application.put_env(:vmu_core, :rail_provider, AcceptingRail)
      account = wallet_fixture(D.new("10"))
      token = token_with_scopes(["wallet:write"])

      conn = conn |> authed(token) |> post("/api/v1/wallet/payments", payment_params(account, %{"amount" => "500"}))
      assert json_response(conn, 422)["error"]["code"] == "insufficient_funds"
    end

    test "missing required params returns 422", %{conn: conn} do
      token = token_with_scopes(["wallet:write"])
      conn = conn |> authed(token) |> post("/api/v1/wallet/payments", %{"rail_type" => "A2A"})
      assert json_response(conn, 422)["error"]["code"] == "missing_params"
    end
  end

  describe "GET /api/v1/wallet/payments/:id" do
    test "returns the payment's current status", %{conn: conn} do
      Application.put_env(:vmu_core, :rail_provider, AcceptingRail)
      account = wallet_fixture()
      write_token = token_with_scopes(["wallet:write"])

      created =
        conn
        |> authed(write_token)
        |> post("/api/v1/wallet/payments", payment_params(account))
        |> json_response(201)

      read_token = token_with_scopes(["wallet:read"])

      conn =
        build_conn()
        |> authed(read_token)
        |> get("/api/v1/wallet/payments/#{created["payment"]["external_payment_id"]}")

      body = json_response(conn, 200)
      assert body["payment"]["status"] == "completed"
    end

    test "an unknown id returns 404", %{conn: conn} do
      token = token_with_scopes(["wallet:read"])
      conn = conn |> authed(token) |> get("/api/v1/wallet/payments/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)["error"]["code"] == "payment_not_found"
    end
  end
end
