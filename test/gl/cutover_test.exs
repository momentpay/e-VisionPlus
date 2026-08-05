defmodule VmuCore.Posting.CutoverTest do
  @moduledoc """
  Phase C1 — the authority flip.

  The whole change is one inversion: for a cut-over product, a failed engine
  write must abort the legacy posting; for everything else it must not. These
  tests pin both halves, because getting either wrong is serious — one silently
  lets rejected postings stand, the other breaks products that were never
  cut over.
  """
  use VmuCore.DataCase, async: false

  alias VmuCore.Posting.{Cutover, RuleEngine}

  setup do
    original = Application.get_env(:vmu_core, Cutover, [])
    policy = Application.get_env(:vmu_core, RuleEngine, [])

    on_exit(fn ->
      Application.put_env(:vmu_core, Cutover, original)
      Application.put_env(:vmu_core, RuleEngine, policy)
    end)

    :ok
  end

  describe "cutover switch" do
    test "nothing is cut over by default" do
      Application.delete_env(:vmu_core, Cutover)

      assert Cutover.products() == []
      refute Cutover.authoritative?("WALLET")
      refute Cutover.authoritative?("CREDIT")
    end

    test "only listed products are authoritative" do
      Application.put_env(:vmu_core, Cutover, products: ["WALLET"])

      assert Cutover.authoritative?("WALLET")
      refute Cutover.authoritative?("DEBIT"), "cutting over one product must not affect another"
      refute Cutover.authoritative?("CREDIT")
      refute Cutover.authoritative?(nil)
    end

    test "pending/0 lists what is still on the legacy path" do
      Application.put_env(:vmu_core, Cutover, products: ["WALLET", "PREPAID"])

      pending = Cutover.pending()

      refute "WALLET" in pending
      refute "PREPAID" in pending
      assert "CREDIT" in pending
      assert "DEBIT" in pending
    end

    test "a typo in the product list is reported, not silently ignored" do
      Application.put_env(:vmu_core, Cutover, products: ["WALLET", "WALET"])

      assert Cutover.unknown_products() == ["WALET"],
             "an unrecognised product would look cut over in config while " <>
               "still running on the legacy path"
    end
  end

  describe "closed-period policy (C0)" do
    test "defaults to quarantine" do
      Application.delete_env(:vmu_core, RuleEngine)
      assert RuleEngine.closed_period_policy() == :quarantine
    end

    test "can be relaxed to allow" do
      Application.put_env(:vmu_core, RuleEngine, on_closed_period: :allow)
      assert RuleEngine.closed_period_policy() == :allow
    end
  end
end
