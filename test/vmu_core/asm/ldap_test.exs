defmodule VmuCore.ASM.LdapTest do
  @moduledoc """
  Real Postgres via Sandbox. Covers `LdapConfig`'s config resolution
  (fully real) and `Auth.authenticate_directory/2` (fully real). Does
  NOT and cannot cover a successful `LdapClient.bind/3` — no real AD/LDAP
  server exists in this environment to test against (see
  `LdapClient`'s moduledoc). What IS tested here for `LdapClient` is real:
  a genuine `:eldap` connection attempt against an address guaranteed to
  refuse it, confirming the unreachable path returns a clean error
  rather than crashing or (worse) being silently treated as success.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.ASM.{Auth, LdapClient, LdapConfig, Operator}
  alias VmuCore.Shared.{BankParameter, ModuleConfigWriter, SysParameter}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
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

  defp operator_fixture(username) do
    %Operator{}
    |> Operator.changeset(%{
      username: username, display_name: "LDAP Test", pw_hash: "x", pw_salt: "x",
      role: "OPS", status: "ACTIVE"
    })
    |> Repo.insert!()
  end

  describe "LdapConfig.resolve/0" do
    test "returns directory_not_enabled when neither \"ad\" nor \"ldap\" is in authn_source" do
      {sys_id, bank_id} = bank_fixture()
      ModuleConfigWriter.put("asm", "authn_source", ["local"],
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

      assert {:error, :directory_not_enabled} = LdapConfig.resolve()
    end

    test "returns directory_not_configured when enabled but no ldap sub-config present" do
      {sys_id, bank_id} = bank_fixture()
      ModuleConfigWriter.put("asm", "authn_source", ["local", "ad"],
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

      assert {:error, :directory_not_configured} = LdapConfig.resolve()
    end

    test "resolves a full config for \"ldap\", defaulting port/ssl" do
      {sys_id, bank_id} = bank_fixture()
      ModuleConfigWriter.put("asm", "authn_source", ["local", "ldap"],
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)
      ModuleConfigWriter.put("asm", "authn_provider_config",
        %{"ldap" => %{"host" => "ldap.test.internal", "bind_dn_template" => "uid=%s,ou=people,dc=test"}},
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

      assert {:ok, cfg} = LdapConfig.resolve()
      assert cfg.host == "ldap.test.internal"
      assert cfg.port == 636
      assert cfg.ssl == true
    end

    test "\"ad\" and \"ldap\" both resolve the same ldap sub-config" do
      {sys_id, bank_id} = bank_fixture()
      ModuleConfigWriter.put("asm", "authn_source", ["ad"],
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)
      ModuleConfigWriter.put("asm", "authn_provider_config",
        %{"ldap" => %{"host" => "dc01.corp.test", "port" => 389, "ssl" => false,
                       "bind_dn_template" => "%s@corp.test"}},
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

      assert {:ok, cfg} = LdapConfig.resolve()
      assert cfg.port == 389
      assert cfg.ssl == false
      assert LdapConfig.bind_principal(cfg, "jsmith") == "jsmith@corp.test"
    end
  end

  describe "LdapClient.bind/3 against an unreachable directory" do
    test "a connection failure returns a clean error, never treated as success" do
      cfg = %LdapConfig{host: "127.0.0.1", port: 1, ssl: false, bind_dn_template: "%s@corp.test"}

      assert {:error, _reason} = LdapClient.bind("nobody@corp.test", "wrong", cfg)
    end
  end

  describe "Auth.authenticate_directory/2" do
    test "matches an existing operator by the bound username" do
      operator = operator_fixture("dir.match.#{System.unique_integer([:positive])}")
      assert {:ok, matched} = Auth.authenticate_directory(operator.username)
      assert matched.operator_id == operator.operator_id
    end

    test "no matching local operator is a clean, distinct error (no JIT provisioning)" do
      assert {:error, :no_matching_operator} =
               Auth.authenticate_directory("no.such.directory.user.#{System.unique_integer([:positive])}")
    end

    test "a LOCKED operator is rejected the same way password auth would reject it" do
      operator = operator_fixture("dir.locked.#{System.unique_integer([:positive])}")
      operator |> Operator.changeset(%{status: "LOCKED"}) |> Repo.update!()

      assert {:error, :locked} = Auth.authenticate_directory(operator.username)
    end
  end
end
