defmodule VmuCore.CTA.PanGenerator do
  @moduledoc """
  Generates a new PAN for card issuance (Way4 parity plan Phase 1 item 1,
  2026-07-25).

  No PAN-generation utility existed anywhere in this codebase before this
  — `Cards.issue/1` always required a caller-supplied `pan_token`, and
  the one existing caller that needs a *new* PAN (`CardLifecycle.
  replace/3`'s LOST/STOLEN/FRAUD path) requires the caller to pass
  `opts[:new_pan_token]` manually (no generator to call). This is the
  first real implementation — wired into new-card issuance
  (`CardLifecycle.issue_new/2`/`issue_virtual_with_credentials/2`) only;
  `replace/3`'s manual-PAN requirement is untouched, out of this item's
  scope.

  16-digit PAN: 6-digit BIN prefix (from the account's `LogoParameter`,
  never guessed) + 9 random digits + 1 Luhn check digit. The raw PAN is
  never returned or persisted by `generate/3` — only the SHA-256
  `pan_token` (matching `CardActivation`'s hashing convention) and
  `last_four`, which is all `Cards.issue/1` needs.
  """

  alias VmuCore.Repo
  alias VmuCore.Shared.LogoParameter

  @pan_length 16
  @check_digit_count 1

  @doc """
  Generates a new tokenized PAN for the given sys/bank/logo scope.
  Returns `{:ok, %{pan_token: String.t(), last_four: String.t()}}` or
  `{:error, :logo_not_found}`.
  """
  @spec generate(String.t(), String.t(), String.t()) ::
          {:ok, %{pan_token: String.t(), last_four: String.t()}} | {:error, :logo_not_found}
  def generate(sys_id, bank_id, logo_id) do
    case Repo.get_by(LogoParameter, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id) do
      nil ->
        {:error, :logo_not_found}

      %LogoParameter{bin_prefix: bin_prefix} ->
        {:ok, from_bin(bin_prefix)}
    end
  end

  @doc "Same as `generate/3` but also returns the raw PAN — see `generate_raw/1`."
  @spec generate_with_raw(String.t(), String.t(), String.t()) ::
          {:ok, %{pan_token: String.t(), last_four: String.t(), raw_pan: String.t()}} | {:error, :logo_not_found}
  def generate_with_raw(sys_id, bank_id, logo_id) do
    case Repo.get_by(LogoParameter, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id) do
      nil -> {:error, :logo_not_found}
      %LogoParameter{bin_prefix: bin_prefix} -> {:ok, generate_raw(bin_prefix)}
    end
  end

  @doc "Generates a tokenized PAN from an already-known BIN prefix (skips the LogoParameter lookup)."
  @spec from_bin(String.t()) :: %{pan_token: String.t(), last_four: String.t()}
  def from_bin(bin_prefix) when is_binary(bin_prefix) do
    generate_raw(bin_prefix) |> Map.drop([:raw_pan])
  end

  @doc """
  Same as `from_bin/1` but also returns the raw PAN — needed exactly
  once, transiently, to compute the CVV and show the cardholder their
  real card number at virtual-card issuance time. Callers must not
  persist the `raw_pan` value; it's discarded after being handed to
  `CTA.CredentialVault` for one-time reveal.
  """
  @spec generate_raw(String.t()) :: %{pan_token: String.t(), last_four: String.t(), raw_pan: String.t()}
  def generate_raw(bin_prefix) when is_binary(bin_prefix) do
    body_length = @pan_length - String.length(bin_prefix) - @check_digit_count
    body = random_digits(body_length)
    partial = bin_prefix <> body
    check_digit = luhn_check_digit(partial)
    raw_pan = partial <> check_digit

    %{
      pan_token: :crypto.hash(:sha256, raw_pan) |> Base.encode16(case: :lower),
      last_four: String.slice(raw_pan, -4, 4),
      raw_pan: raw_pan
    }
  end

  # ---------------------------------------------------------------------------
  # Luhn check digit (ISO/IEC 7812)
  # ---------------------------------------------------------------------------

  defp random_digits(length) do
    1..length
    |> Enum.map(fn _ -> Integer.to_string(:rand.uniform(10) - 1) end)
    |> Enum.join()
  end

  defp luhn_check_digit(partial_number) do
    sum =
      partial_number
      |> String.reverse()
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {digit_str, index}, acc ->
        digit = String.to_integer(digit_str)

        doubled =
          if rem(index, 2) == 0 do
            case digit * 2 do
              d when d > 9 -> d - 9
              d -> d
            end
          else
            digit
          end

        acc + doubled
      end)

    check = rem(10 - rem(sum, 10), 10)
    Integer.to_string(check)
  end
end
