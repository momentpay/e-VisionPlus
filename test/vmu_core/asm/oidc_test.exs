defmodule VmuCore.ASM.OidcTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking of vmu_core's own code —
  `VmuCoreWeb.MockIdp` is a real GenServer generating a real RSA keypair
  and issuing real, correctly-signed RS256 ID tokens; `OidcClient`'s
  `token_endpoint`/`jwks_endpoint` HTTP calls are routed through
  `Req.Test` (a real Plug pipeline, not a mock — see `config/test.exs`'s
  `:oidc_http_plug`) directly to those real MockIdp values, so the actual
  signature-verification/claims-validation code in `OidcClient.
  verify_id_token/3` runs for real. Covers `OidcConfig.resolve/0`,
  `OidcClient`, `MockIdp`, and `Auth.authenticate_sso/2` — Way4 parity
  plan Phase 0 item 6 (2026-07-24).
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.ASM.{Auth, Operator, OidcClient, OidcConfig}
  alias VmuCore.Shared.{BankParameter, ModuleConfigWriter, SysParameter}
  alias VmuCoreWeb.MockIdp

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    # MockIdp issues "iss" from this app-env key (defaults to a different
    # value than this suite's configured OidcConfig issuer) — align them.
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

  defp operator_fixture(username, role \\ "OPS") do
    %Operator{}
    |> Operator.changeset(%{
      username: username, display_name: "SSO Test", pw_hash: "x", pw_salt: "x",
      role: role, status: "ACTIVE"
    })
    |> Repo.insert!()
  end

  defp configure_sso({sys_id, bank_id}, overrides \\ %{}) do
    provider = Map.merge(%{
      "issuer" => "https://idp.test", "authorize_endpoint" => "https://idp.test/authorize",
      "token_endpoint" => "https://idp.test/token", "jwks_endpoint" => "https://idp.test/jwks",
      "client_id" => "vmu-core-admin", "client_secret_env" => "OIDC_TEST_SECRET",
      "redirect_uri" => "https://admin.test/callback"
    }, overrides)

    System.put_env("OIDC_TEST_SECRET", "test-secret-value")

    ModuleConfigWriter.put("asm", "authn_source", ["local", "sso"],
      %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)
    ModuleConfigWriter.put("asm", "authn_provider_config", provider,
      %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)
  end

  # Real MockIdp round trip: issue + exchange a code, returning a real
  # signed ID token and stubbing OidcClient's HTTP calls to return it.
  # MockIdp already runs app-wide (dev/test supervision tree) — no need
  # to start a second instance.
  defp mock_signed_token(username, nonce) do
    {:ok, code} = MockIdp.issue_code(username, nonce)
    {:ok, id_token} = MockIdp.exchange_code(code, "vmu-core-admin")

    Req.Test.stub(OidcClient, fn conn ->
      cond do
        conn.request_path == "/token" ->
          Req.Test.json(conn, %{"id_token" => id_token, "token_type" => "Bearer"})

        conn.request_path == "/jwks" ->
          Req.Test.json(conn, MockIdp.jwks())
      end
    end)

    id_token
  end

  describe "OidcConfig.resolve/0" do
    test "returns sso_not_enabled when \"sso\" isn't in authn_source" do
      {sys_id, bank_id} = bank_fixture()
      ModuleConfigWriter.put("asm", "authn_source", ["local"],
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

      assert {:error, :sso_not_enabled} = OidcConfig.resolve()
    end

    test "returns sso_not_configured when enabled but provider config is incomplete" do
      {sys_id, bank_id} = bank_fixture()
      ModuleConfigWriter.put("asm", "authn_source", ["local", "sso"],
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)
      ModuleConfigWriter.put("asm", "authn_provider_config", %{"issuer" => "https://idp.test"},
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

      assert {:error, :sso_not_configured} = OidcConfig.resolve()
    end

    test "resolves a full config, reading the client secret from the real env var, never the config map" do
      bank = bank_fixture()
      configure_sso(bank)

      assert {:ok, cfg} = OidcConfig.resolve()
      assert cfg.issuer == "https://idp.test"
      assert cfg.client_secret == "test-secret-value"
      assert cfg.username_claim == "preferred_username"
    end
  end

  describe "OidcClient.verify_id_token/3 against a real MockIdp-signed token" do
    test "a valid token with matching nonce verifies successfully" do
      bank_fixture() |> configure_sso()
      {:ok, cfg} = OidcConfig.resolve()

      nonce = "test-nonce-1"
      id_token = mock_signed_token("sso.tester", nonce)

      assert {:ok, claims} = OidcClient.verify_id_token(cfg, id_token, nonce)
      assert claims["preferred_username"] == "sso.tester"
    end

    test "a nonce mismatch is rejected" do
      bank_fixture() |> configure_sso()
      {:ok, cfg} = OidcConfig.resolve()

      id_token = mock_signed_token("sso.tester", "nonce-the-idp-signed")

      assert {:error, :nonce_mismatch} = OidcClient.verify_id_token(cfg, id_token, "different-nonce")
    end

    test "an audience mismatch (wrong client_id) is rejected" do
      bank_fixture() |> configure_sso(%{"client_id" => "some-other-client"})
      {:ok, cfg} = OidcConfig.resolve()

      nonce = "test-nonce-2"
      # Signed for "vmu-core-admin" (mock_signed_token's hardcoded exchange
      # client_id), but cfg now expects "some-other-client".
      id_token = mock_signed_token("sso.tester", nonce)

      assert {:error, :aud_mismatch} = OidcClient.verify_id_token(cfg, id_token, nonce)
    end
  end

  describe "OidcClient.exchange_code/2" do
    test "a non-200 token endpoint response is a clean error, not a crash" do
      bank_fixture() |> configure_sso()
      {:ok, cfg} = OidcConfig.resolve()

      Req.Test.stub(OidcClient, fn conn -> Plug.Conn.send_resp(conn, 400, ~s({"error":"invalid_grant"})) end)

      assert {:error, :token_exchange_failed} = OidcClient.exchange_code(cfg, "bad-code")
    end
  end

  describe "Auth.authenticate_sso/2" do
    test "matches an existing operator by claimed username" do
      operator = operator_fixture("sso.match.#{System.unique_integer([:positive])}")
      assert {:ok, matched} = Auth.authenticate_sso(operator.username)
      assert matched.operator_id == operator.operator_id
    end

    test "no matching local operator is a clean, distinct error (no JIT provisioning)" do
      assert {:error, :no_matching_operator} = Auth.authenticate_sso("no.such.operator.#{System.unique_integer([:positive])}")
    end

    test "a DISABLED operator is rejected the same way password auth would reject it" do
      operator = operator_fixture("sso.disabled.#{System.unique_integer([:positive])}")
      operator |> VmuCore.ASM.Operator.changeset(%{status: "DISABLED"}) |> Repo.update!()

      assert {:error, :disabled} = Auth.authenticate_sso(operator.username)
    end
  end
end
