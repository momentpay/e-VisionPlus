defmodule VmuCore.ASM.LdapClient do
  @moduledoc """
  Real LDAP/AD simple-bind authentication via Erlang/OTP's built-in
  `:eldap` module (Way4 parity plan Phase 0 item 6, 2026-07-24) — no
  external dependency needed, unlike SSO's OIDC client.

  **Honestly unverified against a live directory** — no real AD/LDAP
  server is available in this environment to test against (same posture
  as FAS's `ProductionHSM` stub: real protocol code, real crypto/TLS,
  just never proven against a live counterpart). `bind/3` is a genuine
  `:eldap` simple-bind attempt, not a stub — but treat it as unverified
  until exercised against a real directory before relying on it in
  production.

  A successful bind is itself the authentication proof — LDAP simple
  bind rejects the connection outright on a wrong password, no separate
  password check needed on this side.
  """

  require Logger

  alias VmuCore.ASM.LdapConfig

  @doc """
  Attempts a simple bind as `bind_principal` (already resolved from the
  username via `LdapConfig.bind_principal/2`) with `password` against
  `config`. Returns `:ok` on a successful bind, `{:error,
  :directory_unreachable}` if the server can't be reached at all, or
  `{:error, reason}` for a rejected bind (bad credentials, etc.) —
  callers must never treat an unreachable server as a successful
  authentication.
  """
  @spec bind(String.t(), String.t(), LdapConfig.t()) :: :ok | {:error, term()}
  def bind(bind_principal, password, %LdapConfig{} = config) do
    case :eldap.open([String.to_charlist(config.host)], connect_opts(config)) do
      {:ok, handle} ->
        try do
          case :eldap.simple_bind(handle, String.to_charlist(bind_principal), String.to_charlist(password)) do
            :ok -> :ok
            {:error, reason} -> {:error, reason}
          end
        after
          :eldap.close(handle)
        end

      {:error, reason} ->
        Logger.warning("[ASM.LdapClient] connect failed host=#{config.host} port=#{config.port}: #{inspect(reason)}")
        {:error, :directory_unreachable}
    end
  end

  defp connect_opts(%LdapConfig{port: port, ssl: ssl}) do
    base = [{:port, port}, {:timeout, 5_000}]
    if ssl, do: [{:ssl, true} | base], else: base
  end
end
