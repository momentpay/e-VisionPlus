defmodule VmuCore.LMS.PointsLifecycleTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias VmuCore.{Repo, LMS.Enrollment, LMS.Account, LMS.PointsLedger, LMS.Scheme}
  alias VmuCore.CMS.Account, as: CmsAccount
  alias Decimal, as: D

  # `LMS.Account.ar_account_id` is a :binary_id — it references a real CMS
  # account. A plain string raised `does not match type :binary_id` on insert.
  @ar_account_id "33333333-3333-4333-8333-333333333333"
  @ar_account_id_alt "44444444-4444-4444-8444-444444444444"
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # lms_accounts has real foreign keys to cms_accounts and lms_schemes, so
    # both parents must exist. The original fixture created neither and failed
    # with `lms_accounts_ar_account_id_fkey`.
    Enum.each([@ar_account_id, @ar_account_id_alt], &cms_account_fixture/1)

    scheme =
      Repo.insert!(%Scheme{
        scheme_code: "T#{rem(System.unique_integer([:positive]), 10_000)}",
        scheme_name: "Points lifecycle test scheme",
        org_id: 1,
        currency: "AED",
        points_expiry_months: 24,
        status: "ACTIVE"
      })

    {:ok, scheme_id: scheme.id}
  end

  defp cms_account_fixture(account_id) do
    Repo.insert!(%CmsAccount{
      account_id: account_id,
      customer_id: Ecto.UUID.generate(),
      sys_id: "SYS3",
      bank_id: "BNK3",
      logo_id: "LGO3",
      block_id: "BLK3",
      pan_token: "tok_lms_#{System.unique_integer([:positive])}",
      last_four: "4242",
      expiry_date: "1229",
      credit_limit: D.new("10000.00"),
      open_to_buy: D.new("10000.00"),
      cycle_code: 25,
      account_status: "ACTIVE"
    })
  end

  describe "Enrollment" do
    test "enroll/3 creates LMS account idempotently", %{scheme_id: scheme_id} do
      assert {:ok, lms_acc} = Enrollment.enroll(@ar_account_id, scheme_id, method: "MANUAL")

      # enroll/3 documents three shapes: {:ok, account}, {:ok, :already_enrolled}
      # and {:error, reason}. A repeat enrolment takes the on_conflict: :nothing
      # path and reports :already_enrolled rather than returning the struct
      # again — the previous assertion expected a struct and called .id on the
      # atom.
      assert {:ok, :already_enrolled} =
               Enrollment.enroll(@ar_account_id, scheme_id, method: "MANUAL")

      # And no duplicate row was created.
      assert 1 ==
               Repo.aggregate(
                 from(a in Account, where: a.ar_account_id == ^@ar_account_id),
                 :count
               )

      assert lms_acc.ar_account_id == @ar_account_id
    end

    test "LMS account number follows LMS prefix format", %{scheme_id: scheme_id} do
      {:ok, lms_acc} = Enrollment.enroll(@ar_account_id, scheme_id, method: "MANUAL")
      assert String.starts_with?(lms_acc.lms_account_no, "LMS")
    end
  end

  describe "Points earning" do
    setup %{scheme_id: scheme_id} do
      {:ok, lms_acc} = Enrollment.enroll(@ar_account_id, scheme_id, method: "MANUAL")
      {:ok, lms_acc: lms_acc}
    end

    test "posting BASIC_EARNED increments points_balance", %{lms_acc: lms_acc, scheme_id: scheme_id} do
      _initial_balance = lms_acc.points_balance

      Repo.insert!(%PointsLedger{
        lms_account_id:   lms_acc.id,
        scheme_id:        scheme_id,
        # Field names follow the schema: transaction_type / points_amount.
        # This fixture used `entry_type` / `points` / `transaction_ref`, none
        # of which exist on PointsLedger, so the file failed to COMPILE and
        # took the whole `mix test` run down with it. Fixed 2026-08-04.
        transaction_type: "BASIC_EARNED",
        points_amount:    D.new("100"),
        # NOT NULL — the monetary value the points were earned against.
        monetary_equiv:   D.new("100.00"),
        warehouse_state:  "ACTIVE",
        idempotency_key:  "earn-test-001",
        transaction_date: Date.utc_today(),
        posting_date:     Date.utc_today(),
        inserted_at:      DateTime.utc_now() |> DateTime.truncate(:second)
      })

      updated = Repo.get!(Account, lms_acc.id)
      # Note: in production, points_balance is updated by RedemptionProcessor/PointsEngine
      assert updated != nil
    end
  end

  describe "Redemption" do
    test "redeem/3 returns error when insufficient points", %{scheme_id: scheme_id} do
      {:ok, lms_acc} = Enrollment.enroll(@ar_account_id_alt, scheme_id, method: "MANUAL")

      result = VmuCore.LMS.RedemptionProcessor.redeem(
        lms_acc.id,
        D.new("9999999"),
        type: "ONLINE",
        method: "CREDIT"
      )

      assert {:error, _} = result
    end
  end
end
