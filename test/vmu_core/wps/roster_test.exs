defmodule VmuCore.WPS.RosterTest do
  @moduledoc """
  WPS employer onboarding and worker roster (Phase W1).

  Real Postgres via the sandbox — several of the invariants under test live in
  the database (the unique index scoped to employer, the ACTIVE-needs-account
  check constraint) and would simply be absent from a mock.
  """
  use VmuCore.DataCase, async: false

  alias VmuCore.CMS.PrepaidAccount
  alias VmuCore.GL.InstitutionResolver
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias VmuCore.WPS.{BeneficiaryLink, Employer, Roster}
  alias Decimal, as: D

  setup do
    InstitutionResolver.reset()
    on_exit(&InstitutionResolver.reset/0)
    :ok
  end

  defp institution do
    n = System.unique_integer([:positive])
    sys_id = "W#{100 + rem(n, 900)}"
    bank_id = "P#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "t"}) |> Repo.insert!()

    %BankParameter{}
    |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "t"})
    |> Repo.insert!()

    %LogoParameter{}
    |> LogoParameter.changeset(%{
      sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "606060", description: "t"
    })
    |> Repo.insert!()

    %BlockParameter{}
    |> BlockParameter.changeset(%{
      sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
    })
    |> Repo.insert!()

    # Stash the card hierarchy so `prepaid_account_fixture/2` can create
    # accounts for this institution without re-deriving it.
    Process.put({:wps_hierarchy, sys_id, bank_id}, {logo_id, block_id})

    {sys_id, bank_id}
  end

  defp employer_fixture(attrs \\ %{}) do
    {sys_id, bank_id} = institution()
    n = System.unique_integer([:positive])

    {:ok, employer} =
      Roster.onboard_employer(
        Map.merge(
          %{
            sys_id: sys_id,
            bank_id: bank_id,
            employer_code: "EMP#{n}",
            employer_name: "Test Employer #{n}",
            jurisdiction: "AE"
          },
          attrs
        )
      )

    employer
  end

  defp prepaid_account_fixture(sys_id, bank_id) do
    n = System.unique_integer([:positive])
    {logo_id, block_id} = Process.get({:wps_hierarchy, sys_id, bank_id})

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "W", last_name: "Worker#{n}",
        id_type: "PASSPORT", id_number: "WPS-#{n}"
      })
      |> Repo.insert!()

    %PrepaidAccount{}
    |> PrepaidAccount.changeset(%{
      customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id,
      logo_id: logo_id, block_id: block_id,
      currency: "AED", status: "ACTIVE", opened_at: Date.utc_today()
    })
    |> Repo.insert!()
  end

  describe "employer onboarding" do
    test "an employer is ACTIVE and disbursable on onboarding" do
      employer = employer_fixture()

      assert employer.status == "ACTIVE"
      assert Employer.disbursable?(employer)
      assert employer.onboarded_at
    end

    test "employer_code is unique within an institution, not globally" do
      first = employer_fixture()

      # Same code, *different* institution — must be allowed. Two banks running
      # on the same platform will both have an "EMP001".
      other_employer =
        employer_fixture(%{employer_code: first.employer_code})

      assert other_employer.employer_id != first.employer_id

      # Same code, same institution — refused.
      assert {:error, changeset} =
               Roster.onboard_employer(%{
                 sys_id: first.sys_id, bank_id: first.bank_id,
                 employer_code: first.employer_code, employer_name: "Impostor"
               })

      refute changeset.valid?
    end

    test "a suspended employer is not disbursable but keeps its roster" do
      employer = employer_fixture()
      {sys_id, bank_id} = {employer.sys_id, employer.bank_id}
      account = prepaid_account_fixture(sys_id, bank_id)

      {:ok, _} =
        Roster.link(%{
          employer_id: employer.employer_id, employee_id: "E1",
          prepaid_account_id: account.prepaid_account_id
        })

      {:ok, suspended} = Roster.set_employer_status(employer.employer_id, "SUSPENDED")

      refute Employer.disbursable?(suspended)
      assert length(Roster.list_links(employer.employer_id)) == 1
    end
  end

  describe "the roster" do
    test "an employee id is unique per employer, so two employers may both use it" do
      a = employer_fixture()
      b = employer_fixture()

      {:ok, _} = Roster.link(%{employer_id: a.employer_id, employee_id: "001"})
      {:ok, _} = Roster.link(%{employer_id: b.employer_id, employee_id: "001"})

      assert Roster.get_link(a.employer_id, "001").employer_id == a.employer_id
      assert Roster.get_link(b.employer_id, "001").employer_id == b.employer_id
    end

    test "linking twice updates rather than duplicating" do
      employer = employer_fixture()
      account = prepaid_account_fixture(employer.sys_id, employer.bank_id)

      {:ok, first} = Roster.link(%{employer_id: employer.employer_id, employee_id: "E1"})
      assert first.status == "UNVERIFIED"

      {:ok, second} =
        Roster.link(%{
          employer_id: employer.employer_id, employee_id: "E1",
          prepaid_account_id: account.prepaid_account_id
        })

      assert second.link_id == first.link_id
      assert second.status == "ACTIVE"
      assert length(Roster.list_links(employer.employer_id)) == 1
    end

    test "a link with no account is UNVERIFIED and not payable" do
      employer = employer_fixture()

      {:ok, link} = Roster.link(%{employer_id: employer.employer_id, employee_id: "E1"})

      assert link.status == "UNVERIFIED"
      refute BeneficiaryLink.payable?(link)
      assert {:error, {:not_payable, "UNVERIFIED"}} = Roster.resolve(employer.employer_id, "E1")
    end

    test "an ACTIVE link cannot exist without an account" do
      employer = employer_fixture()

      assert {:error, changeset} =
               Roster.link(%{
                 employer_id: employer.employer_id, employee_id: "E1", status: "ACTIVE"
               })

      refute changeset.valid?
      assert changeset.errors[:prepaid_account_id]
    end

    test "linking to an account that does not exist is refused" do
      employer = employer_fixture()
      ghost = Ecto.UUID.generate()

      assert {:error, {:prepaid_account_not_found, ^ghost}} =
               Roster.link(%{
                 employer_id: employer.employer_id, employee_id: "E1", prepaid_account_id: ghost
               })
    end

    test "suspending stops resolution but keeps the link" do
      employer = employer_fixture()
      account = prepaid_account_fixture(employer.sys_id, employer.bank_id)

      {:ok, _} =
        Roster.link(%{
          employer_id: employer.employer_id, employee_id: "E1",
          prepaid_account_id: account.prepaid_account_id
        })

      assert {:ok, _} = Roster.resolve(employer.employer_id, "E1")

      {:ok, _} = Roster.suspend_link(employer.employer_id, "E1", "left the company")

      assert {:error, {:not_payable, "SUSPENDED"}} = Roster.resolve(employer.employer_id, "E1")
      assert Roster.get_link(employer.employer_id, "E1")
    end
  end

  describe "resolve_many/2" do
    test "returns a verdict for every requested id, including the failures" do
      employer = employer_fixture()
      account = prepaid_account_fixture(employer.sys_id, employer.bank_id)

      {:ok, _} =
        Roster.link(%{
          employer_id: employer.employer_id, employee_id: "PAYABLE",
          prepaid_account_id: account.prepaid_account_id
        })

      {:ok, _} = Roster.link(%{employer_id: employer.employer_id, employee_id: "UNVERIFIED"})

      results = Roster.resolve_many(employer.employer_id, ["PAYABLE", "UNVERIFIED", "UNKNOWN"])

      # A file needs a verdict per line, not a filtered list — every id is present.
      assert map_size(results) == 3
      assert {:ok, _} = results["PAYABLE"]
      assert {:error, {:not_payable, "UNVERIFIED"}} = results["UNVERIFIED"]
      assert {:error, :not_linked} = results["UNKNOWN"]
    end

    test "resolves a batch in one query rather than one per line" do
      employer = employer_fixture()

      for i <- 1..25 do
        account = prepaid_account_fixture(employer.sys_id, employer.bank_id)

        {:ok, _} =
          Roster.link(%{
            employer_id: employer.employer_id, employee_id: "E#{i}",
            prepaid_account_id: account.prepaid_account_id
          })
      end

      ids = Enum.map(1..25, &"E#{&1}")
      results = Roster.resolve_many(employer.employer_id, ids)

      assert map_size(results) == 25
      assert Enum.all?(results, fn {_id, r} -> match?({:ok, _}, r) end)
    end
  end

  describe "GL product resolution" do
    test "a prepaid account becomes WPS_PREPAID once it joins a roster" do
      employer = employer_fixture()
      account = prepaid_account_fixture(employer.sys_id, employer.bank_id)
      ref = account.prepaid_account_id

      # Before: an ordinary prepaid account.
      assert {:ok, "PREPAID"} = InstitutionResolver.resolve_product(ref)

      {:ok, _} =
        Roster.link(%{
          employer_id: employer.employer_id, employee_id: "E1", prepaid_account_id: ref
        })

      InstitutionResolver.reset()

      # After: salary float, reportable apart from ordinary prepaid.
      assert {:ok, "WPS_PREPAID"} = InstitutionResolver.resolve_product(ref)
      assert {:ok, "WPS_PREPAID"} = InstitutionResolver.wps_overlay(ref)
    end

    test "the institution is unchanged by the relabel" do
      employer = employer_fixture()
      account = prepaid_account_fixture(employer.sys_id, employer.bank_id)
      ref = account.prepaid_account_id
      {sys_id, bank_id} = {employer.sys_id, employer.bank_id}

      {:ok, _} =
        Roster.link(%{
          employer_id: employer.employer_id, employee_id: "E1", prepaid_account_id: ref
        })

      InstitutionResolver.reset()

      # Both labels read the same `cms_prepaid_accounts` row, so neither may
      # poison the other's cache entry.
      assert {:ok, {^sys_id, ^bank_id}} = InstitutionResolver.resolve(ref, "WPS_PREPAID")
      assert {:ok, {^sys_id, ^bank_id}} = InstitutionResolver.resolve(ref, "PREPAID")
    end

    test "one account joining a roster does not relabel any other prepaid account" do
      employer = employer_fixture()
      joined = prepaid_account_fixture(employer.sys_id, employer.bank_id)
      untouched = prepaid_account_fixture(employer.sys_id, employer.bank_id)

      {:ok, _} =
        Roster.link(%{
          employer_id: employer.employer_id, employee_id: "E1",
          prepaid_account_id: joined.prepaid_account_id
        })

      InstitutionResolver.reset()

      assert {:ok, "WPS_PREPAID"} = InstitutionResolver.resolve_product(joined.prepaid_account_id)
      assert {:ok, "PREPAID"} = InstitutionResolver.resolve_product(untouched.prepaid_account_id)
    end

    test "an HCS account is never tested against the WPS overlay, or vice versa" do
      # Overlays are scoped to the base table the account lives in. A prepaid
      # account asked the HCS question must answer :none regardless of rosters.
      employer = employer_fixture()
      account = prepaid_account_fixture(employer.sys_id, employer.bank_id)

      {:ok, _} =
        Roster.link(%{
          employer_id: employer.employer_id, employee_id: "E1",
          prepaid_account_id: account.prepaid_account_id
        })

      InstitutionResolver.reset()

      assert :none = InstitutionResolver.hcs_overlay(account.prepaid_account_id)
      assert {:ok, "WPS_PREPAID"} = InstitutionResolver.wps_overlay(account.prepaid_account_id)
    end
  end

  describe "accounts_with_multiple_employers/2" do
    test "surfaces one account being paid by two employers" do
      a = employer_fixture()
      # Same institution, so the query scope catches both.
      {:ok, b} =
        Roster.onboard_employer(%{
          sys_id: a.sys_id, bank_id: a.bank_id,
          employer_code: "EMP-B-#{System.unique_integer([:positive])}",
          employer_name: "Second Employer"
        })

      shared = prepaid_account_fixture(a.sys_id, a.bank_id)
      solo = prepaid_account_fixture(a.sys_id, a.bank_id)

      {:ok, _} = Roster.link(%{employer_id: a.employer_id, employee_id: "X", prepaid_account_id: shared.prepaid_account_id})
      {:ok, _} = Roster.link(%{employer_id: b.employer_id, employee_id: "Y", prepaid_account_id: shared.prepaid_account_id})
      {:ok, _} = Roster.link(%{employer_id: a.employer_id, employee_id: "Z", prepaid_account_id: solo.prepaid_account_id})

      flagged = Roster.accounts_with_multiple_employers(a.sys_id, a.bank_id)

      # Not an error — second jobs are legal — but it is also what payroll fraud
      # looks like, so it has to be visible.
      assert Map.has_key?(flagged, shared.prepaid_account_id)
      refute Map.has_key?(flagged, solo.prepaid_account_id)
      assert length(flagged[shared.prepaid_account_id]) == 2
    end
  end

end
