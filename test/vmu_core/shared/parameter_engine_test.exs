defmodule VmuCore.Shared.ParameterEngineTest do
  @moduledoc """
  Tests for the VisionPlus SYS→BANK→LOGO→BLOCK parameter cascade engine.

  These tests operate entirely in-memory using :ets directly so they can run
  without a live database connection (no Ecto sandbox required).
  """

  use ExUnit.Case, async: false

  alias VmuCore.Shared.ParameterEngine

  @table :vmu_parameter_cache

  # ---------------------------------------------------------------------------
  # Setup: boot a fresh ETS table before each test
  # ---------------------------------------------------------------------------

  setup do
    # Ensure the named ETS table exists (ParameterEngine may not be started in test)
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, {:read_concurrency, true}])
    else
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helper: seed individual ETS entries the same way ParameterEngine does
  # ---------------------------------------------------------------------------

  defp put_sys(sys_id, field, value),
    do: :ets.insert(@table, {{:sys, sys_id, field}, value})

  defp put_bank(sys_id, bank_id, field, value),
    do: :ets.insert(@table, {{:bank, sys_id, bank_id, field}, value})

  defp put_logo(sys_id, bank_id, logo_id, field, value),
    do: :ets.insert(@table, {{:logo, sys_id, bank_id, logo_id, field}, value})

  defp put_block(sys_id, bank_id, logo_id, block_id, field, value),
    do: :ets.insert(@table, {{:block, sys_id, bank_id, logo_id, block_id, field}, value})

  defp put_bin(sys_id, bank_id, logo_id, bin_prefix),
    do: :ets.insert(@table, {{:logo, sys_id, bank_id, logo_id, :bin_prefix}, bin_prefix})

  # ---------------------------------------------------------------------------
  # Cascade resolution tests
  # ---------------------------------------------------------------------------

  describe "get/5 — Block level (most specific)" do
    test "returns block-level value when explicitly configured" do
      put_sys("0001", :apr_percentage, Decimal.new("15.00"))
      put_bank("0001", "0010", :apr_percentage, Decimal.new("18.00"))
      put_logo("0001", "0010", "0100", :apr_percentage, Decimal.new("21.00"))
      put_block("0001", "0010", "0100", "1000", :apr_percentage, Decimal.new("24.99"))

      assert {:ok, %Decimal{} = apr} =
               ParameterEngine.get("0001", "0010", "0100", "1000", :apr_percentage)

      assert Decimal.equal?(apr, Decimal.new("24.99"))
    end
  end

  describe "get/5 — Logo fallback" do
    test "falls back to logo value when block has no entry" do
      put_logo("0001", "0010", "0100", :apr_percentage, Decimal.new("21.00"))
      # No block entry for this param — logo value must be returned

      assert {:ok, apr} =
               ParameterEngine.get("0001", "0010", "0100", "9999", :apr_percentage)

      assert Decimal.equal?(apr, Decimal.new("21.00"))
    end
  end

  describe "get/5 — Bank fallback" do
    test "falls back to bank value when block and logo have no entry" do
      put_bank("0001", "0010", :country_code, "ARE")
      # No block or logo entry

      assert {:ok, "ARE"} =
               ParameterEngine.get("0001", "0010", "9999", "9999", :country_code)
    end
  end

  describe "get/5 — System fallback" do
    test "falls back to system global value when block/logo/bank are absent" do
      put_sys("0001", :base_currency, "AED")

      assert {:ok, "AED"} =
               ParameterEngine.get("0001", "9999", "9999", "9999", :base_currency)
    end
  end

  describe "get/5 — not found" do
    test "returns :parameter_not_found when no level has the key" do
      assert {:error, :parameter_not_found} =
               ParameterEngine.get("0001", "0010", "0100", "1000", :non_existent_param)
    end

    test "returns :parameter_not_found for an unknown sys_id" do
      put_sys("0001", :base_currency, "AED")

      assert {:error, :parameter_not_found} =
               ParameterEngine.get("XXXX", "0010", "0100", "1000", :base_currency)
    end
  end

  describe "get/5 — cascade precedence" do
    test "block overrides logo which overrides bank which overrides system" do
      put_sys("0001", :apr_percentage, Decimal.new("10.00"))
      put_bank("0001", "0010", :apr_percentage, Decimal.new("15.00"))
      put_logo("0001", "0010", "0100", :apr_percentage, Decimal.new("20.00"))
      put_block("0001", "0010", "0100", "1000", :apr_percentage, Decimal.new("25.00"))

      # Block wins
      assert {:ok, block_val} =
               ParameterEngine.get("0001", "0010", "0100", "1000", :apr_percentage)
      assert Decimal.equal?(block_val, Decimal.new("25.00"))

      # Remove block entry — logo should win
      :ets.delete(@table, {:block, "0001", "0010", "0100", "1000", :apr_percentage})
      assert {:ok, logo_val} =
               ParameterEngine.get("0001", "0010", "0100", "1000", :apr_percentage)
      assert Decimal.equal?(logo_val, Decimal.new("20.00"))

      # Remove logo entry — bank should win
      :ets.delete(@table, {:logo, "0001", "0010", "0100", :apr_percentage})
      assert {:ok, bank_val} =
               ParameterEngine.get("0001", "0010", "0100", "1000", :apr_percentage)
      assert Decimal.equal?(bank_val, Decimal.new("15.00"))

      # Remove bank entry — system should win
      :ets.delete(@table, {:bank, "0001", "0010", :apr_percentage})
      assert {:ok, sys_val} =
               ParameterEngine.get("0001", "0010", "0100", "1000", :apr_percentage)
      assert Decimal.equal?(sys_val, Decimal.new("10.00"))
    end
  end

  # ---------------------------------------------------------------------------
  # BIN resolution tests
  # ---------------------------------------------------------------------------

  describe "resolve_bin/1" do
    test "matches a PAN to the correct logo by 6-digit BIN prefix" do
      put_bin("0001", "0010", "0100", "543210")

      assert {:ok, {"0001", "0010", "0100"}} =
               ParameterEngine.resolve_bin("543210XXXXXXXXXX")
    end

    test "returns :no_bin_match for an unregistered BIN" do
      assert {:error, :no_bin_match} =
               ParameterEngine.resolve_bin("999999XXXXXXXXXX")
    end

    test "returns :no_bin_match for a PAN shorter than 6 digits" do
      assert {:error, :no_bin_match} = ParameterEngine.resolve_bin("1234")
    end

    test "handles multiple BINs — returns correct logo for each" do
      put_bin("0001", "0010", "0100", "411111")
      put_bin("0001", "0010", "0200", "541234")

      assert {:ok, {"0001", "0010", "0100"}} =
               ParameterEngine.resolve_bin("411111XXXXXXXXXX")

      assert {:ok, {"0001", "0010", "0200"}} =
               ParameterEngine.resolve_bin("541234XXXXXXXXXX")
    end
  end

  # ---------------------------------------------------------------------------
  # Diagnostics
  # ---------------------------------------------------------------------------

  describe "cache_size/0" do
    test "returns zero for empty cache" do
      assert ParameterEngine.cache_size() == 0
    end

    test "returns correct count after seeding" do
      put_sys("0001", :base_currency, "AED")
      put_sys("0001", :description, "Gulf System")
      put_bank("0001", "0010", :country_code, "ARE")

      assert ParameterEngine.cache_size() == 3
    end
  end
end
