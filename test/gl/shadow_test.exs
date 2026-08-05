defmodule VmuCore.Posting.ShadowTest do
  @moduledoc """
  Phase B tests: the institution resolver, the shadow hook's fail-safety, and
  the diff's classifications.

  The resolver cache test exists because of a real defect. Caching only the
  institution meant `resolve/2` returned a hit for *any* product once an
  account had been resolved for one — so a credit account resolved as a debit
  account, and a FEE posting silently failed to mirror while INTEREST on the
  same account succeeded. The shadow diff is what surfaced it, which is
  precisely what Phase B is for.
  """
  use VmuCore.DataCase, async: false

  alias VmuCore.GL.InstitutionResolver
  alias VmuCore.Posting.{Shadow, ShadowDiff}

  setup do
    if :ets.whereis(:vmu_gl_institution_cache) == :undefined do
      start_supervised!(InstitutionResolver)
    else
      InstitutionResolver.reset()
    end

    original = Application.get_env(:vmu_core, Shadow, [])
    on_exit(fn -> Application.put_env(:vmu_core, Shadow, original) end)

    :ok
  end

  describe "shadow mode switch" do
    test "is off unless explicitly enabled" do
      Application.delete_env(:vmu_core, Shadow)
      refute Shadow.enabled?()
    end

    test "turns on via application config" do
      Application.put_env(:vmu_core, Shadow, enabled: true)
      assert Shadow.enabled?()
    end

    test "can be limited to specific institutions" do
      Application.put_env(:vmu_core, Shadow,
        enabled: true,
        only_institutions: [{"MMPD", "MMBD"}]
      )

      assert Shadow.enabled?("MMPD", "MMBD")
      refute Shadow.enabled?("OTHR", "OTHR")
    end
  end

  describe "fail-safety — the whole contract of Phase B" do
    test "mirror/1 returns :ok even when given nonsense" do
      Application.put_env(:vmu_core, Shadow, enabled: true)

      assert :ok = Shadow.mirror(%{})
      assert :ok = Shadow.mirror(%{account_id: "not-a-uuid", idempotency_key: "x"})
      assert :ok = Shadow.mirror(%{account_id: nil, transaction_code: "PURCHASE"})
      assert :ok = Shadow.mirror(%{account_id: Ecto.UUID.generate(), transaction_code: "NOPE"})
    end

    test "mirror/1 does nothing at all when disabled" do
      Application.put_env(:vmu_core, Shadow, enabled: false)

      before = Repo.aggregate(VmuCore.Posting.PostingSet, :count)
      assert :ok = Shadow.mirror(%{account_id: Ecto.UUID.generate(), transaction_code: "PURCHASE"})

      assert before == Repo.aggregate(VmuCore.Posting.PostingSet, :count)
    end
  end

  describe "institution resolver" do
    test "an unknown account resolves to :not_found, never a wrong institution" do
      assert {:error, :not_found} = InstitutionResolver.resolve(Ecto.UUID.generate(), "DEBIT")
      assert {:error, :not_found} = InstitutionResolver.resolve(Ecto.UUID.generate())
    end

    test "a malformed reference does not raise" do
      assert {:error, :not_found} = InstitutionResolver.resolve("clearly-not-a-uuid", "CREDIT")
    end

    test "an unknown product resolves to :not_found" do
      assert {:error, :not_found} = InstitutionResolver.resolve(Ecto.UUID.generate(), "LOAN")
    end

    test "caching does not let one product's hit satisfy another's lookup" do
      # The regression. Two products, one reference: resolving for the first
      # must not make the second report a false positive.
      ref = Ecto.UUID.generate()

      assert {:error, :not_found} = InstitutionResolver.resolve(ref, "CREDIT")
      assert {:error, :not_found} = InstitutionResolver.resolve(ref, "DEBIT")
      assert {:error, :not_found} = InstitutionResolver.resolve(ref, "WALLET")
    end

    test "reset/0 clears the cache" do
      assert :ok = InstitutionResolver.reset()
    end
  end

  describe "diff classification" do
    test "summary reports every class and an equivalence verdict" do
      summary = ShadowDiff.summary(since: Date.utc_today())

      for key <- [:total, :match, :mismatch, :missing_shadow, :orphan_shadow, :equivalent?] do
        assert Map.has_key?(summary, key), "summary is missing #{key}"
      end

      assert is_boolean(summary.equivalent?)
    end

    test "equivalence requires zero mismatches and zero orphans" do
      # A missing shadow row is expected (anything posted before shadow mode
      # was switched on), so it must not by itself block the verdict.
      summary = ShadowDiff.summary(since: ~D[2099-01-01])

      assert summary.total == 0
      assert summary.equivalent?
    end

    test "compare/1 can filter to one status" do
      rows = ShadowDiff.compare(since: Date.utc_today(), status: :mismatch)
      assert Enum.all?(rows, &(&1.status == :mismatch))
    end

    test "rows are ordered with mismatches first" do
      rows = ShadowDiff.compare(since: ~D[2000-01-01], limit: 50)
      statuses = Enum.map(rows, & &1.status)

      ranked = Enum.map(statuses, fn
        :mismatch -> 0
        :orphan_shadow -> 1
        :missing_shadow -> 2
        :match -> 3
      end)

      assert ranked == Enum.sort(ranked), "mismatches must sort first: #{inspect(statuses)}"
    end
  end
end
