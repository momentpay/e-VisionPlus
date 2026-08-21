defmodule VmuCore.CAM.OtpChallengesTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. CAM Phase F1 (2026-08-02).
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.Shared.Customer
  alias VmuCore.CAM.{OtpChallenge, OtpChallenges}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp customer_fixture do
    n = System.unique_integer([:positive])

    %Customer{}
    |> Customer.changeset(%{
      sys_id: "T#{100 + rem(n, 900)}", bank_id: "B#{100 + rem(n, 900)}",
      first_name: "Otp", last_name: "Test#{n}",
      mobile_country: "+971", mobile_number: "5#{100_000_000 + rem(n, 899_999_999)}"
    })
    |> Repo.insert!()
  end

  test "create/2 returns a 6-digit code and persists only its hash" do
    customer = customer_fixture()

    assert {:ok, code, challenge} = OtpChallenges.create(customer.customer_id)
    assert String.match?(code, ~r/^\d{6}$/)
    assert challenge.code_hash != code
    assert challenge.consumed_at == nil
  end

  test "verify/3 succeeds with the right code and consumes the challenge" do
    customer = customer_fixture()
    {:ok, code, _challenge} = OtpChallenges.create(customer.customer_id)

    assert :ok = OtpChallenges.verify(customer.customer_id, code)
    # single-use — verifying again with the same code fails
    assert {:error, :not_found} = OtpChallenges.verify(customer.customer_id, code)
  end

  test "verify/3 fails with the wrong code and increments attempts" do
    customer = customer_fixture()
    {:ok, _code, challenge} = OtpChallenges.create(customer.customer_id)

    assert {:error, :invalid_code} = OtpChallenges.verify(customer.customer_id, "000000")
    reloaded = Repo.get!(OtpChallenge, challenge.otp_challenge_id)
    assert reloaded.attempts == 1
  end

  test "verify/3 locks out after max_attempts wrong tries" do
    customer = customer_fixture()
    {:ok, _code, _challenge} = OtpChallenges.create(customer.customer_id)

    for _ <- 1..OtpChallenge.max_attempts() do
      OtpChallenges.verify(customer.customer_id, "000000")
    end

    assert {:error, :too_many_attempts} = OtpChallenges.verify(customer.customer_id, "000000")
  end

  test "verify/3 fails once the challenge has expired" do
    customer = customer_fixture()
    {:ok, code, challenge} = OtpChallenges.create(customer.customer_id)

    past = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)
    challenge |> OtpChallenge.changeset(%{"expires_at" => past}) |> Repo.update!()

    assert {:error, :expired} = OtpChallenges.verify(customer.customer_id, code)
  end

  test "verify/3 returns :not_found when no challenge exists" do
    customer = customer_fixture()
    assert {:error, :not_found} = OtpChallenges.verify(customer.customer_id, "123456")
  end
end
