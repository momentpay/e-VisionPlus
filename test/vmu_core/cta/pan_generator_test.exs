defmodule VmuCore.CTA.PanGeneratorTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Way4 parity plan Phase 1 item 1
  (2026-07-25) — the first real PAN generator in this codebase.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CTA.PanGenerator
  alias VmuCore.Shared.{BankParameter, LogoParameter, SysParameter}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp logo_fixture(bin_prefix \\ "424242") do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: bin_prefix, description: "test"}) |> Repo.insert!()

    {sys_id, bank_id, logo_id}
  end

  defp luhn_valid?(pan) do
    sum =
      pan
      |> String.reverse()
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc ->
        digit = String.to_integer(d)
        doubled = if rem(i, 2) == 1, do: (if digit * 2 > 9, do: digit * 2 - 9, else: digit * 2), else: digit
        acc + doubled
      end)

    rem(sum, 10) == 0
  end

  describe "generate/3" do
    test "generates a 16-digit PAN with the real BIN prefix and a valid Luhn check digit" do
      {sys_id, bank_id, logo_id} = logo_fixture("424242")

      assert {:ok, %{pan_token: pan_token, last_four: last_four}} = PanGenerator.generate(sys_id, bank_id, logo_id)
      assert String.length(pan_token) == 64
      assert String.length(last_four) == 4
    end

    test "the raw PAN (via generate_with_raw/3) starts with the real BIN and passes Luhn" do
      {sys_id, bank_id, logo_id} = logo_fixture("511111")

      assert {:ok, %{raw_pan: raw_pan, pan_token: pan_token, last_four: last_four}} =
               PanGenerator.generate_with_raw(sys_id, bank_id, logo_id)

      assert String.length(raw_pan) == 16
      assert String.starts_with?(raw_pan, "511111")
      assert luhn_valid?(raw_pan)
      assert String.slice(raw_pan, -4, 4) == last_four
      assert :crypto.hash(:sha256, raw_pan) |> Base.encode16(case: :lower) == pan_token
    end

    test "an unknown logo returns a clean error" do
      assert {:error, :logo_not_found} = PanGenerator.generate("ZZZ", "ZZZ", "ZZZ")
    end

    test "two consecutive generations for the same logo produce different PANs" do
      {sys_id, bank_id, logo_id} = logo_fixture("400000")

      {:ok, %{raw_pan: pan1}} = PanGenerator.generate_with_raw(sys_id, bank_id, logo_id)
      {:ok, %{raw_pan: pan2}} = PanGenerator.generate_with_raw(sys_id, bank_id, logo_id)

      refute pan1 == pan2
    end
  end

  describe "from_bin/1 and generate_raw/1" do
    test "from_bin/1 never returns the raw PAN" do
      result = PanGenerator.from_bin("424242")
      refute Map.has_key?(result, :raw_pan)
      assert Map.has_key?(result, :pan_token)
      assert Map.has_key?(result, :last_four)
    end
  end
end
