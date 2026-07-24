defmodule VmuCore.ASM.LdapConfig do
  @moduledoc """
  Resolves the pre-existing `authn_source`/`authn_provider_config` Module
  Config Framework keys into a usable LDAP/AD directory-bind
  configuration (Way4 parity plan Phase 0 item 6, 2026-07-24) — the
  directory counterpart to `VmuCore.ASM.OidcConfig`. "ad" and "ldap" are
  both satisfied by the same direct-bind mechanism: Active Directory
  accepts a `userPrincipalName` (`user@corp.example.com`) as a simple-bind
  principal exactly like a plain LDAP DN, so one config shape and one
  client (`VmuCore.ASM.LdapClient`) cover both — only the configured
  `bind_dn_template` differs between an AD and an OpenLDAP deployment.

  Same v1 single-tenant simplification as `OidcConfig.resolve/0` (no
  login-page tenant selector yet — resolves against the first
  `BankParameter` row).

  `authn_provider_config`'s `"ldap"` sub-key shape:
  ```
  %{
    "ldap" => %{
      "host"             => "ldap.example.com",
      "port"             => 636,
      "ssl"              => true,
      # "%s" is replaced with the submitted username. AD: a UPN template
      # ("%s@corp.example.com"). OpenLDAP/generic: a DN template
      # ("uid=%s,ou=people,dc=example,dc=com").
      "bind_dn_template" => "%s@corp.example.com"
    }
  }
  ```
  """

  import Ecto.Query
  alias VmuCore.Repo
  alias VmuCore.Shared.{BankParameter, ModuleConfigEngine}

  defstruct [:host, :port, :ssl, :bind_dn_template]

  @type t :: %__MODULE__{}

  @doc "Returns `{:ok, config}` if AD/LDAP is enabled and fully configured, else `{:error, reason}`."
  @spec resolve() :: {:ok, t()} | {:error, :directory_not_enabled | :directory_not_configured | :no_tenant}
  def resolve do
    with {:ok, {sys_id, bank_id}} <- default_sys_bank(),
         {:ok, sources} <- ModuleConfigEngine.get("asm", "authn_source", sys_id, bank_id),
         true <- Enum.any?(sources, &(&1 in ["ad", "ldap"])),
         {:ok, provider} <- ModuleConfigEngine.get("asm", "authn_provider_config", sys_id, bank_id) do
      build_config(Map.get(provider, "ldap", %{}))
    else
      false -> {:error, :directory_not_enabled}
      {:error, _} -> {:error, :directory_not_enabled}
    end
  end

  @doc "Builds the bind principal for `username` per the configured template."
  @spec bind_principal(t(), String.t()) :: String.t()
  def bind_principal(%__MODULE__{bind_dn_template: template}, username) do
    String.replace(template, "%s", username)
  end

  defp build_config(ldap) when map_size(ldap) == 0, do: {:error, :directory_not_configured}

  defp build_config(ldap) do
    required = ~w[host bind_dn_template]

    if Enum.all?(required, &Map.has_key?(ldap, &1)) do
      {:ok,
       %__MODULE__{
         host: ldap["host"],
         port: Map.get(ldap, "port", 636),
         ssl: Map.get(ldap, "ssl", true),
         bind_dn_template: ldap["bind_dn_template"]
       }}
    else
      {:error, :directory_not_configured}
    end
  end

  defp default_sys_bank do
    case Repo.one(from b in BankParameter, order_by: [asc: b.sys_id, asc: b.bank_id], limit: 1,
                   select: {b.sys_id, b.bank_id}) do
      nil -> {:error, :no_tenant}
      pair -> {:ok, pair}
    end
  end
end
