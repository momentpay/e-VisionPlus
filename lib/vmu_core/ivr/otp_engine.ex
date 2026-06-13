defmodule VmuCore.IVR.OtpEngine do
  @moduledoc """
  One-Time Password engine for digital cardholder channels.

  Supports:
    - HOTP (HMAC-based, RFC 4226) — counter-based, used for card-not-present transactions
    - TOTP (Time-based, RFC 6238) — 30-second window, used for mobile/web portal login

  OTPs are 6 digits. The secret is per-account, stored encrypted at rest.
  This module handles generation and verification only — persistence is
  handled by the caller (ASM session store or IVR session).

  Renamed from VmuCore.ITS.OtpEngine (ITS = Interchange Tracking System in canonical VisionPlus).
  """

  use Bitwise

  @otp_length 6
  @totp_step  30    # seconds per TOTP window
  @hotp_drift 1     # allow ±1 counter window for HOTP

  # ---------------------------------------------------------------------------
  # HOTP — RFC 4226
  # ---------------------------------------------------------------------------

  @doc "Generate an HOTP value for a given secret and counter. Returns a zero-padded 6-digit string."
  def hotp(secret, counter) when is_integer(counter) do
    counter_bytes = <<counter::unsigned-big-integer-64>>
    mac = :crypto.mac(:hmac, :sha, secret, counter_bytes)
    truncate(mac) |> pad_otp()
  end

  @doc """
  Verify a presented HOTP. Checks counter and counter+1 (drift tolerance).
  Returns {:ok, next_counter} or {:error, :invalid_otp}.
  """
  def verify_hotp(secret, presented_otp, expected_counter) do
    expected = hotp(secret, expected_counter)
    drifted  = hotp(secret, expected_counter + @hotp_drift)

    cond do
      presented_otp == expected -> {:ok, expected_counter + 1}
      presented_otp == drifted  -> {:ok, expected_counter + 2}
      true                      -> {:error, :invalid_otp}
    end
  end

  # ---------------------------------------------------------------------------
  # TOTP — RFC 6238
  # ---------------------------------------------------------------------------

  @doc "Generate a TOTP for the current time window."
  def totp(secret, at \\ DateTime.utc_now()) do
    counter = div(DateTime.to_unix(at), @totp_step)
    hotp(secret, counter)
  end

  @doc """
  Verify a presented TOTP. Checks current window, previous, and next (clock skew tolerance).
  Returns :ok or {:error, :invalid_otp}.
  """
  def verify_totp(secret, presented_otp, at \\ DateTime.utc_now()) do
    counter = div(DateTime.to_unix(at), @totp_step)

    valid =
      Enum.any?([counter - 1, counter, counter + 1], fn c ->
        hotp(secret, c) == presented_otp
      end)

    if valid, do: :ok, else: {:error, :invalid_otp}
  end

  @doc "Generate a random 20-byte TOTP secret (Base32-encodable)."
  def generate_secret, do: :crypto.strong_rand_bytes(20)

  # ---------------------------------------------------------------------------
  # Private — RFC 4226 truncation
  # ---------------------------------------------------------------------------

  defp truncate(mac) do
    offset = :binary.at(mac, byte_size(mac) - 1) &&& 0x0F
    <<_::binary-size(offset), p::unsigned-big-integer-32, _::binary>> = mac
    rem(p &&& 0x7FFFFFFF, trunc(:math.pow(10, @otp_length)))
  end

  defp pad_otp(n), do: Integer.to_string(n) |> String.pad_leading(@otp_length, "0")
end
