defmodule VmuCoreWeb.DirectorySessionControllerTest do
  @moduledoc """
  Real Postgres via Sandbox, real router dispatch. Cannot cover a
  successful directory bind (no real AD/LDAP server available — see
  `LdapClient`'s moduledoc); covers the config-resolution and
  unreachable-server paths for real, and confirms the controller never
  logs an operator in on either.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias VmuCore.Repo
  alias VmuCore.Shared.{BankParameter, ModuleConfigWriter, SysParameter}

  @endpoint VmuCoreWeb.Endpoint

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

  test "not configured for this deployment redirects to login with a clean error" do
    conn = post(build_conn(), "/visionplus/admin/login/directory", %{"username" => "jsmith", "password" => "x"})

    assert redirected_to(conn) == "/visionplus/admin/login"
    assert get_session(conn, "login_error") =~ "not configured"
    refute get_session(conn, "operator_id")
  end

  test "an unreachable directory server redirects with a clean error, never logs anyone in" do
    {sys_id, bank_id} = bank_fixture()

    ModuleConfigWriter.put("asm", "authn_source", ["local", "ldap"],
      %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)
    ModuleConfigWriter.put("asm", "authn_provider_config",
      %{"ldap" => %{"host" => "127.0.0.1", "port" => 1, "ssl" => false, "bind_dn_template" => "%s@corp.test"}},
      %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

    conn = post(build_conn(), "/visionplus/admin/login/directory", %{"username" => "jsmith", "password" => "x"})

    assert redirected_to(conn) == "/visionplus/admin/login"
    refute get_session(conn, "operator_id")
  end

  test "missing username/password is rejected without attempting a bind" do
    conn = post(build_conn(), "/visionplus/admin/login/directory", %{"username" => "", "password" => ""})

    assert redirected_to(conn) == "/visionplus/admin/login"
    assert get_session(conn, "login_error") =~ "Enter your directory"
  end
end
