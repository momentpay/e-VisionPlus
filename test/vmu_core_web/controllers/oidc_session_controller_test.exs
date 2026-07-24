defmodule VmuCoreWeb.OidcSessionControllerTest do
  @moduledoc """
  Real Postgres via Sandbox, real router dispatch (`Phoenix.ConnTest`) —
  this repo's first plain-controller (non-LiveView) test. Drives the
  actual `/visionplus/admin/auth/oidc/start` → `/callback` flow, with
  `OidcClient`'s token/jwks HTTP calls faked via `Req.Test` returning
  real `VmuCoreWeb.MockIdp`-signed data (see `oidc_test.exs`'s moduledoc
  for why this is real coverage, not a mock of vmu_core's own logic).
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Operator, OidcClient}
  alias VmuCore.Shared.{BankParameter, ModuleConfigWriter, SysParameter}
  alias VmuCoreWeb.MockIdp

  @endpoint VmuCoreWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Application.put_env(:vmu_core, :mock_idp_issuer, "https://idp.test")
    :ok
  end

  defp bank_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()

    {sys_id, bank_id}
  end

  defp configure_sso({sys_id, bank_id}) do
    System.put_env("OIDC_TEST_SECRET", "test-secret-value")

    ModuleConfigWriter.put("asm", "authn_source", ["local", "sso"],
      %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

    ModuleConfigWriter.put("asm", "authn_provider_config", %{
      "issuer" => "https://idp.test", "authorize_endpoint" => "https://idp.test/authorize",
      "token_endpoint" => "https://idp.test/token", "jwks_endpoint" => "https://idp.test/jwks",
      "client_id" => "vmu-core-admin", "client_secret_env" => "OIDC_TEST_SECRET",
      "redirect_uri" => "https://admin.test/callback"
    }, %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)
  end

  defp operator_fixture(username) do
    %Operator{}
    |> Operator.changeset(%{
      username: username, display_name: "SSO Ctrl Test", pw_hash: "x", pw_salt: "x",
      role: "OPS", status: "ACTIVE"
    })
    |> Repo.insert!()
  end

  describe "GET /visionplus/admin/auth/oidc/start" do
    test "redirects to the IdP with state/nonce stored in the session" do
      bank_fixture() |> configure_sso()

      conn = get(build_conn(), "/visionplus/admin/auth/oidc/start")

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert location =~ "https://idp.test/authorize?"
      assert location =~ "client_id=vmu-core-admin"
      assert get_session(conn, "oidc_state")
      assert get_session(conn, "oidc_nonce")
    end

    test "redirects straight back to login with an error when SSO isn't configured" do
      conn = get(build_conn(), "/visionplus/admin/auth/oidc/start")

      assert redirected_to(conn) == "/visionplus/admin/login"
      assert get_session(conn, "login_error") =~ "not configured"
    end
  end

  describe "GET /visionplus/admin/auth/oidc/callback" do
    test "a valid code + matching state logs the matched operator in" do
      bank_fixture() |> configure_sso()
      # MockIdp only recognizes fixed test usernames — see its @known_subjects.
      operator = operator_fixture("sso.tester")

      state = "test-state"
      nonce = "test-nonce"

      {:ok, code} = MockIdp.issue_code(operator.username, nonce)
      {:ok, id_token} = MockIdp.exchange_code(code, "vmu-core-admin")

      Req.Test.stub(OidcClient, fn conn ->
        cond do
          conn.request_path == "/token" -> Req.Test.json(conn, %{"id_token" => id_token})
          conn.request_path == "/jwks" -> Req.Test.json(conn, MockIdp.jwks())
        end
      end)

      conn =
        build_conn()
        |> init_test_session(%{"oidc_state" => state, "oidc_nonce" => nonce})
        |> get("/visionplus/admin/auth/oidc/callback?code=#{code}&state=#{state}")

      assert redirected_to(conn) == "/visionplus/admin"
      assert get_session(conn, "operator_id") == operator.operator_id
    end

    test "a state mismatch fails without ever calling the token endpoint" do
      bank_fixture() |> configure_sso()

      conn =
        build_conn()
        |> init_test_session(%{"oidc_state" => "expected", "oidc_nonce" => "n"})
        |> get("/visionplus/admin/auth/oidc/callback?code=whatever&state=WRONG")

      assert redirected_to(conn) == "/visionplus/admin/login"
      assert get_session(conn, "login_error") =~ "invalid state"
      refute get_session(conn, "operator_id")
    end

    test "a token for a username with no matching local operator fails cleanly" do
      bank_fixture() |> configure_sso()

      state = "test-state-2"
      nonce = "test-nonce-2"
      {:ok, code} = MockIdp.issue_code("sso.nomatch", nonce)
      {:ok, id_token} = MockIdp.exchange_code(code, "vmu-core-admin")

      Req.Test.stub(OidcClient, fn conn ->
        cond do
          conn.request_path == "/token" -> Req.Test.json(conn, %{"id_token" => id_token})
          conn.request_path == "/jwks" -> Req.Test.json(conn, MockIdp.jwks())
        end
      end)

      conn =
        build_conn()
        |> init_test_session(%{"oidc_state" => state, "oidc_nonce" => nonce})
        |> get("/visionplus/admin/auth/oidc/callback?code=#{code}&state=#{state}")

      assert redirected_to(conn) == "/visionplus/admin/login"
      assert get_session(conn, "login_error") =~ "No VisionPlus operator account"
      refute get_session(conn, "operator_id")
    end
  end
end
