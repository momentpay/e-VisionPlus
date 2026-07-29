defmodule VmuCore.ASM.ServiceAccountsTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. KYC-P5 (2026-07-29) — API
  credential provisioning/authentication. See docs/kyc/
  KYC_Implementation_Tracker.md §7.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.ASM.ServiceAccounts

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "create/1 returns a raw token that authenticates, and only its hash is persisted" do
    n = System.unique_integer([:positive])

    assert {:ok, account, raw_token} =
             ServiceAccounts.create(%{"name" => "test-caller-#{n}", "scopes" => ["kyc:read", "kyc:write"]})

    assert String.starts_with?(raw_token, "sa_")
    assert account.token_hash != raw_token
    refute account.token_hash =~ raw_token

    assert authenticated = ServiceAccounts.authenticate(raw_token)
    assert authenticated.service_account_id == account.service_account_id
    assert authenticated.last_used_at != nil
  end

  test "authenticate/1 rejects an unknown token" do
    assert ServiceAccounts.authenticate("sa_not_a_real_token") == nil
  end

  test "authenticate/1 rejects a revoked account's token even though it once worked" do
    n = System.unique_integer([:positive])
    {:ok, account, raw_token} = ServiceAccounts.create(%{"name" => "revoke-test-#{n}", "scopes" => ["kyc:read"]})

    assert ServiceAccounts.authenticate(raw_token) != nil

    {:ok, _revoked} = ServiceAccounts.revoke(account)

    assert ServiceAccounts.authenticate(raw_token) == nil
  end

  test "create/1 rejects a scope outside the fixed catalog" do
    n = System.unique_integer([:positive])
    assert {:error, changeset} = ServiceAccounts.create(%{"name" => "bad-scope-#{n}", "scopes" => ["not_a_real_scope"]})
    refute changeset.valid?
  end

  test "VmuCore.ASM.ServiceAccount.authorized?/2 checks both status and scope" do
    n = System.unique_integer([:positive])
    {:ok, account, _token} = ServiceAccounts.create(%{"name" => "authz-test-#{n}", "scopes" => ["kyc:read"]})

    assert VmuCore.ASM.ServiceAccount.authorized?(account, "kyc:read")
    refute VmuCore.ASM.ServiceAccount.authorized?(account, "kyc:write")

    {:ok, revoked} = ServiceAccounts.revoke(account)
    refute VmuCore.ASM.ServiceAccount.authorized?(revoked, "kyc:read")
  end
end
