defmodule VmuCore.ASM.Auth do
  @moduledoc """
  Operator authentication context (ASM-P1, ADR-A1).

  - PBKDF2-SHA256, 100k iterations, per-operator random salt
  - Lockout after #{5} consecutive failures (`status: "LOCKED"`); unlock is an
    ADMIN action (`unlock/1`) — no time-based auto-unlock in P1
  - Every attempt (success or failure, known user or not) lands in
    `asm_login_audit` (FR-ASM-008)
  - Password policy: ≥ 10 chars, at least one letter and one digit

  SSO/LDAP later slots in behind `authenticate/3` without touching callers
  (ADR-A1).
  """

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.ASM.Operator

  @max_failed_attempts 5
  @pbkdf2_iterations 100_000

  # ---------------------------------------------------------------------------
  # Authentication
  # ---------------------------------------------------------------------------

  @doc """
  Authenticate a username/password pair.

  Returns `{:ok, operator}` or `{:error, :invalid_credentials | :locked | :disabled}`.
  Unknown usernames return `:invalid_credentials` after a constant-shape hash
  computation (no user-enumeration timing shortcut).
  """
  @spec authenticate(String.t(), String.t(), keyword()) ::
          {:ok, Operator.t()} | {:error, :invalid_credentials | :locked | :disabled}
  def authenticate(username, password, opts \\ []) do
    ip = Keyword.get(opts, :ip_address)
    operator = Repo.get_by(Operator, username: String.downcase(String.trim(username)))

    cond do
      is_nil(operator) ->
        # burn a hash anyway so unknown vs wrong-password timing is similar
        hash_password(password, random_salt())
        audit(username, nil, "unknown_user", ip)
        {:error, :invalid_credentials}

      operator.status == "DISABLED" ->
        audit(username, operator.operator_id, "disabled", ip)
        {:error, :disabled}

      operator.status == "LOCKED" ->
        audit(username, operator.operator_id, "locked", ip)
        {:error, :locked}

      correct_password?(operator, password) ->
        record_success(operator)
        audit(username, operator.operator_id, "success", ip)
        {:ok, operator}

      true ->
        record_failure(operator)
        audit(username, operator.operator_id, "bad_password", ip)
        {:error, :invalid_credentials}
    end
  end

  @doc "Fetch an ACTIVE operator by ID — session revalidation on every LiveView mount."
  @spec get_active_operator(Ecto.UUID.t() | nil) :: Operator.t() | nil
  def get_active_operator(nil), do: nil

  def get_active_operator(operator_id) do
    case Repo.get(Operator, operator_id) do
      %Operator{status: "ACTIVE"} = op -> op
      _ -> nil
    end
  rescue
    Ecto.Query.CastError -> nil
  end

  # ---------------------------------------------------------------------------
  # Operator management
  # ---------------------------------------------------------------------------

  @doc """
  Create an operator. Attrs: `:username`, `:display_name`, `:password`,
  `:role`, optional `:bank_scope`.
  """
  @spec create_operator(map()) :: {:ok, Operator.t()} | {:error, term()}
  def create_operator(%{password: password} = attrs) do
    with :ok <- validate_password_policy(password) do
      salt = random_salt()

      %Operator{}
      |> Operator.changeset(
        attrs
        |> Map.drop([:password])
        |> Map.merge(%{
          username: attrs.username |> String.trim() |> String.downcase(),
          pw_hash: hash_password(password, salt),
          pw_salt: salt,
          password_changed_at: now()
        })
      )
      |> Repo.insert()
    end
  end

  @doc "Change an operator's own password (requires the current one)."
  @spec change_password(Operator.t(), String.t(), String.t()) ::
          {:ok, Operator.t()} | {:error, term()}
  def change_password(%Operator{} = operator, current_password, new_password) do
    cond do
      not correct_password?(operator, current_password) ->
        {:error, :invalid_credentials}

      :ok != validate_password_policy(new_password) ->
        validate_password_policy(new_password)

      true ->
        set_password(operator, new_password)
    end
  end

  @doc "ADMIN action: reset a password without the current one."
  @spec reset_password(Operator.t(), String.t()) :: {:ok, Operator.t()} | {:error, term()}
  def reset_password(%Operator{} = operator, new_password) do
    with :ok <- validate_password_policy(new_password) do
      set_password(operator, new_password)
    end
  end

  @doc "ADMIN action: unlock a LOCKED operator."
  @spec unlock(Operator.t()) :: {:ok, Operator.t()}
  def unlock(%Operator{} = operator) do
    operator
    |> Operator.changeset(%{status: "ACTIVE", failed_attempts: 0, locked_at: nil})
    |> Repo.update()
  end

  @doc "ADMIN action: disable an operator (terminations)."
  @spec disable(Operator.t()) :: {:ok, Operator.t()}
  def disable(%Operator{} = operator) do
    operator
    |> Operator.changeset(%{status: "DISABLED"})
    |> Repo.update()
  end

  @doc "Password policy: ≥ 10 chars, at least one letter and one digit."
  @spec validate_password_policy(String.t()) :: :ok | {:error, :weak_password}
  def validate_password_policy(password) when is_binary(password) do
    if String.length(password) >= 10 and
         String.match?(password, ~r/[a-zA-Z]/) and
         String.match?(password, ~r/\d/) do
      :ok
    else
      {:error, :weak_password}
    end
  end

  def validate_password_policy(_), do: {:error, :weak_password}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp correct_password?(operator, password) do
    computed = hash_password(password, operator.pw_salt)
    Plug.Crypto.secure_compare(computed, operator.pw_hash)
  end

  defp hash_password(password, salt) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, @pbkdf2_iterations, 32)
    |> Base.encode16(case: :lower)
  end

  defp random_salt, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp set_password(operator, new_password) do
    salt = random_salt()

    operator
    |> Operator.changeset(%{
      pw_hash: hash_password(new_password, salt),
      pw_salt: salt,
      password_changed_at: now(),
      failed_attempts: 0
    })
    |> Repo.update()
  end

  defp record_success(operator) do
    Repo.update_all(
      from(o in Operator, where: o.operator_id == ^operator.operator_id),
      set: [failed_attempts: 0, last_login_at: now()]
    )
  end

  defp record_failure(operator) do
    new_count = operator.failed_attempts + 1

    updates =
      if new_count >= @max_failed_attempts do
        Logger.warning("[ASM.Auth] Locking operator #{operator.username} after " <>
                       "#{new_count} failed attempts")
        [failed_attempts: new_count, status: "LOCKED", locked_at: now()]
      else
        [failed_attempts: new_count]
      end

    Repo.update_all(
      from(o in Operator, where: o.operator_id == ^operator.operator_id),
      set: updates
    )
  end

  defp audit(username, operator_id, outcome, ip) do
    Repo.insert_all("asm_login_audit", [
      %{
        id: Ecto.UUID.bingenerate(),
        username: String.slice(to_string(username), 0, 40),
        operator_id: operator_id && Ecto.UUID.dump!(operator_id),
        outcome: outcome,
        ip_address: ip && String.slice(to_string(ip), 0, 45),
        inserted_at: DateTime.utc_now()
      }
    ])
  rescue
    e -> Logger.error("[ASM.Auth] login audit insert failed: #{Exception.message(e)}")
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
