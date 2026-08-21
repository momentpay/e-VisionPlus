defmodule VmuCore.ASM.OidcConfig do
  @moduledoc """
  Resolves the pre-existing `authn_source`/`authn_provider_config` Module
  Config Framework keys (ASM-P6, previously unwired — see
  `docs/asm/ASM_Module_Requirements.md` open question 1) into a usable
  OIDC client configuration (Way4 parity plan Phase 0 item 6, 2026-07-24).

  `authn_provider_config` stores explicit endpoint URLs rather than a bare
  `issuer` + a guessed discovery-path convention — real IdPs don't agree
  on one (Okta, Azure AD, Keycloak all differ), and this codebase's
  standing rule is to never build against a guessed spec.

  ## v1 simplification, explicitly flagged

  `authn_source`/`authn_provider_config` are scoped per SYS+BANK in the
  Module Config Framework (fits multi-tenant products like HCS/COL), but
  the ASM login page itself has no tenant selector today — `Auth.
  authenticate/3` looks up an `Operator` by username globally, with no
  bank context. This resolves SSO config against the **first**
  `BankParameter` row in the system, matching that same single-tenant-in-
  practice posture. Real multi-tenant SSO (different IdP per bank) would
  need a tenant-selection step at login — a separate, bigger feature, not
  assumed here.

  `authn_provider_config` shape:
  ```
  %{
    "issuer"             => "https://idp.example.com",
    "authorize_endpoint" => "https://idp.example.com/authorize",
    "token_endpoint"     => "https://idp.example.com/token",
    "jwks_endpoint"      => "https://idp.example.com/jwks",
    "client_id"          => "vmu-core-admin",
    "client_secret_env"  => "VMU_OIDC_CLIENT_SECRET",  # never a raw secret
    "redirect_uri"       => "https://admin.example.com/visionplus/admin/auth/oidc/callback",
    "username_claim"     => "preferred_username"
  }
  ```
  """

  import Ecto.Query
  alias VmuCore.Repo
  alias VmuCore.Shared.{BankParameter, ModuleConfigEngine}

  defstruct [:issuer, :authorize_endpoint, :token_endpoint, :jwks_endpoint, :client_id,
             :client_secret, :redirect_uri, :username_claim]

  @type t :: %__MODULE__{}

  @doc "Returns `{:ok, config}` if SSO is enabled and fully configured, else `{:error, reason}`."
  @spec resolve() :: {:ok, t()} | {:error, :sso_not_enabled | :sso_not_configured | :no_tenant}
  def resolve do
    with {:ok, {sys_id, bank_id}} <- default_sys_bank(),
         {:ok, sources} <- ModuleConfigEngine.get("asm", "authn_source", sys_id, bank_id),
         true <- "sso" in sources,
         {:ok, provider} <- ModuleConfigEngine.get("asm", "authn_provider_config", sys_id, bank_id) do
      build_config(provider)
    else
      false -> {:error, :sso_not_enabled}
      {:error, _} -> {:error, :sso_not_enabled}
    end
  end

  defp build_config(provider) when map_size(provider) == 0, do: {:error, :sso_not_configured}

  defp build_config(provider) do
    required = ~w[issuer authorize_endpoint token_endpoint jwks_endpoint client_id client_secret_env redirect_uri]

    if Enum.all?(required, &Map.has_key?(provider, &1)) do
      {:ok,
       %__MODULE__{
         issuer:              provider["issuer"],
         authorize_endpoint:  provider["authorize_endpoint"],
         token_endpoint:      provider["token_endpoint"],
         jwks_endpoint:       provider["jwks_endpoint"],
         client_id:           provider["client_id"],
         client_secret:       System.get_env(provider["client_secret_env"]),
         redirect_uri:        provider["redirect_uri"],
         username_claim:      Map.get(provider, "username_claim", "preferred_username")
       }}
    else
      {:error, :sso_not_configured}
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
