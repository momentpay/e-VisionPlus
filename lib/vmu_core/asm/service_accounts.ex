defmodule VmuCore.ASM.ServiceAccounts do
  @moduledoc """
  Context for `VmuCore.ASM.ServiceAccount` — create (generates and returns
  the raw bearer token exactly once), list, revoke, and authenticate a
  presented token (KYC-P5).
  """

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.ASM.ServiceAccount

  @doc "List all service accounts, newest first."
  @spec list() :: [ServiceAccount.t()]
  def list do
    Repo.all(from s in ServiceAccount, order_by: [desc: s.inserted_at])
  end

  @spec get(binary()) :: ServiceAccount.t() | nil
  def get(id), do: Repo.get(ServiceAccount, id)

  @doc """
  Create a service account. Returns `{:ok, service_account, raw_token}` —
  `raw_token` is only ever available here; only its SHA-256 hash is
  persisted. Show it to the operator once and never again.
  """
  @spec create(map()) :: {:ok, ServiceAccount.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    raw_token = generate_token()

    attrs =
      attrs
      |> Map.put("token_hash", hash_token(raw_token))
      |> Map.put_new("status", "ACTIVE")

    %ServiceAccount{}
    |> ServiceAccount.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, service_account} -> {:ok, service_account, raw_token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Revoke a service account — its token stops authenticating immediately."
  @spec revoke(ServiceAccount.t()) :: {:ok, ServiceAccount.t()} | {:error, Ecto.Changeset.t()}
  def revoke(%ServiceAccount{} = service_account) do
    service_account
    |> ServiceAccount.changeset(%{"status" => "REVOKED"})
    |> Repo.update()
  end

  @doc """
  Authenticate a raw bearer token. Returns the matching `ACTIVE` account
  and bumps `last_used_at`, or `nil` if the token doesn't match any
  account or matches a revoked one.
  """
  @spec authenticate(String.t()) :: ServiceAccount.t() | nil
  def authenticate(raw_token) when is_binary(raw_token) and raw_token != "" do
    hash = hash_token(raw_token)

    case Repo.get_by(ServiceAccount, token_hash: hash, status: "ACTIVE") do
      nil ->
        nil

      account ->
        touch_last_used(account)
    end
  end

  def authenticate(_raw_token), do: nil

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp generate_token do
    "sa_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
  end

  defp hash_token(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end

  defp touch_last_used(account) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    account
    |> Ecto.Changeset.change(last_used_at: now)
    |> Repo.update!()
  end
end
