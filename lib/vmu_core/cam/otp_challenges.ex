defmodule VmuCore.CAM.OtpChallenges do
  @moduledoc """
  Context for `CAM.OtpChallenge` — create + verify a cardholder's one-time
  login code. Does not send the code itself (see `CAM.Auth.request_otp/2`
  for the `NotificationDispatcher` dispatch) — this module is pure
  persistence + verification logic.
  """

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.CAM.OtpChallenge

  @code_ttl_seconds 300

  @doc """
  Creates a challenge for `customer_id` and returns the RAW 6-digit code
  (caller must dispatch it immediately and never persist it elsewhere) plus
  the challenge record.

  Invalidates any previously-unconsumed challenge for the same
  `(customer_id, purpose)` first — at most one code is ever live at a
  time, both a real security property (an old code stops working the
  moment a new one is requested) and what makes `verify/3`'s "most
  recent unconsumed" lookup unambiguous even when two challenges are
  created within the same `inserted_at` second.
  """
  @spec create(binary(), String.t()) :: {:ok, String.t(), OtpChallenge.t()} | {:error, Ecto.Changeset.t()}
  def create(customer_id, purpose \\ "LOGIN") do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(c in OtpChallenge, where: c.customer_id == ^customer_id and c.purpose == ^purpose and is_nil(c.consumed_at))
    |> Repo.update_all(set: [consumed_at: now, updated_at: now])

    code = generate_code()
    expires_at = now |> DateTime.add(@code_ttl_seconds, :second)

    %OtpChallenge{}
    |> OtpChallenge.changeset(%{
      "customer_id" => customer_id, "purpose" => purpose,
      "code_hash" => hash(code), "expires_at" => expires_at
    })
    |> Repo.insert()
    |> case do
      {:ok, challenge} -> {:ok, code, challenge}
      error -> error
    end
  end

  @doc """
  Verifies `code` against the most recent unconsumed, unexpired challenge
  for `customer_id`. Consumes it (stamps `consumed_at`) on success — a
  code is single-use. Bumps `attempts` on every failed try and locks the
  challenge out once `OtpChallenge.max_attempts/0` is reached, regardless
  of whether the code was actually correct.
  """
  @spec verify(binary(), String.t(), String.t()) :: :ok | {:error, :invalid_code | :expired | :not_found | :too_many_attempts}
  def verify(customer_id, code, purpose \\ "LOGIN") do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    challenge =
      Repo.one(
        from c in OtpChallenge,
          where: c.customer_id == ^customer_id and c.purpose == ^purpose and is_nil(c.consumed_at),
          order_by: [desc: c.inserted_at],
          limit: 1
      )

    cond do
      is_nil(challenge) ->
        {:error, :not_found}

      challenge.attempts >= OtpChallenge.max_attempts() ->
        {:error, :too_many_attempts}

      DateTime.compare(challenge.expires_at, now) == :lt ->
        {:error, :expired}

      challenge.code_hash != hash(code) ->
        challenge |> OtpChallenge.changeset(%{"attempts" => challenge.attempts + 1}) |> Repo.update()
        {:error, :invalid_code}

      true ->
        {:ok, _} = challenge |> OtpChallenge.changeset(%{"consumed_at" => now}) |> Repo.update()
        :ok
    end
  end

  defp generate_code do
    :crypto.strong_rand_bytes(4)
    |> :binary.decode_unsigned()
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  defp hash(code), do: :crypto.hash(:sha256, code) |> Base.encode16(case: :lower)
end
