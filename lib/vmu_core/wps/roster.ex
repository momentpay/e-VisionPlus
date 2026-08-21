defmodule VmuCore.WPS.Roster do
  @moduledoc """
  Employer onboarding and worker roster management (W1).

  This is the context the ingestion and disbursement phases resolve against:
  a salary file line carries an employer's own `employee_id`, and
  `resolve/2` turns that into an account to pay.

  ## Bulk resolution, not per-line lookup

  `resolve_many/2` exists because a salary file is a batch. Resolving ten
  thousand lines one query at a time is the shape that makes a file import
  take minutes instead of seconds, and it is the reason `COL.AgencyDesk`-style
  imports are written against sets rather than rows.
  """

  import Ecto.Query, warn: false

  alias VmuCore.Repo
  alias VmuCore.CMS.PrepaidAccount
  alias VmuCore.WPS.{BeneficiaryLink, Employer}

  # ---------------------------------------------------------------------------
  # Employers
  # ---------------------------------------------------------------------------

  @doc "Onboards an employer."
  @spec onboard_employer(map()) :: {:ok, Employer.t()} | {:error, Ecto.Changeset.t()}
  def onboard_employer(attrs) do
    attrs = Map.put_new(attrs, :onboarded_at, DateTime.utc_now())

    %Employer{}
    |> Employer.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetches an employer by id."
  @spec get_employer(Ecto.UUID.t()) :: Employer.t() | nil
  def get_employer(employer_id), do: Repo.get(Employer, employer_id)

  @doc "Fetches an employer by its code within an institution."
  @spec get_employer_by_code(String.t(), String.t(), String.t()) :: Employer.t() | nil
  def get_employer_by_code(sys_id, bank_id, employer_code) do
    Repo.get_by(Employer, sys_id: sys_id, bank_id: bank_id, employer_code: employer_code)
  end

  @doc "Employers for an institution, newest first."
  @spec list_employers(String.t(), String.t(), keyword()) :: [Employer.t()]
  def list_employers(sys_id, bank_id, opts \\ []) do
    Employer
    |> where([e], e.sys_id == ^sys_id and e.bank_id == ^bank_id)
    |> then(fn q ->
      case Keyword.get(opts, :status) do
        nil -> q
        status -> where(q, [e], e.status == ^status)
      end
    end)
    |> order_by([e], desc: e.inserted_at)
    |> Repo.all()
  end

  @doc """
  Changes an employer's status.

  Suspension stops money moving; it does not unwind what already moved, and it
  leaves the roster intact.
  """
  @spec set_employer_status(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, Employer.t()} | {:error, term()}
  def set_employer_status(employer_id, status, opts \\ []) do
    case get_employer(employer_id) do
      nil ->
        {:error, :employer_not_found}

      employer ->
        employer
        |> Employer.changeset(%{status: status, notes: Keyword.get(opts, :notes, employer.notes)})
        |> Repo.update()
    end
  end

  # ---------------------------------------------------------------------------
  # Roster
  # ---------------------------------------------------------------------------

  @doc """
  Creates or updates the link between an employer's `employee_id` and a
  disbursement account.

  Upserts on `(employer_id, employee_id)` — a salary file re-stating a worker
  the bank already knows is the normal case, not a conflict.

  Passing a `:prepaid_account_id` promotes the link to `ACTIVE` unless the
  caller says otherwise, because a link with an account and no reason to be
  suspended is payable by definition.
  """
  @spec link(map()) :: {:ok, BeneficiaryLink.t()} | {:error, term()}
  def link(attrs) do
    attrs = normalise_link_attrs(attrs)

    with :ok <- validate_account_exists(attrs[:prepaid_account_id]) do
      case get_link(attrs.employer_id, attrs.employee_id) do
        nil ->
          %BeneficiaryLink{}
          |> BeneficiaryLink.changeset(attrs)
          |> Repo.insert()

        existing ->
          existing
          |> BeneficiaryLink.changeset(attrs)
          |> Repo.update()
      end
    end
  end

  defp normalise_link_attrs(attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_atom(k), v} end)
      |> Map.put_new(:linked_at, DateTime.utc_now())

    # An account was supplied and no status was asked for: the link is payable.
    if attrs[:prepaid_account_id] && is_nil(attrs[:status]) do
      Map.put(attrs, :status, "ACTIVE")
    else
      attrs
    end
  end

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_existing_atom(k)

  # The account has no foreign key — `cms_prepaid_accounts` is one of five
  # product tables addressed by bare binary ids — so existence is checked here
  # rather than by the database. Skipped when no account is supplied, because
  # an UNVERIFIED link legitimately has none.
  defp validate_account_exists(nil), do: :ok

  defp validate_account_exists(prepaid_account_id) do
    if Repo.exists?(
         from p in PrepaidAccount, where: p.prepaid_account_id == ^prepaid_account_id
       ) do
      :ok
    else
      {:error, {:prepaid_account_not_found, prepaid_account_id}}
    end
  end

  @doc "The link for one employee of one employer."
  @spec get_link(Ecto.UUID.t(), String.t()) :: BeneficiaryLink.t() | nil
  def get_link(employer_id, employee_id) do
    Repo.get_by(BeneficiaryLink, employer_id: employer_id, employee_id: to_string(employee_id))
  end

  @doc """
  Resolves one `employee_id` to an account to pay.

  Returns `{:error, :not_linked}` when the employer has never seen this
  employee, and `{:error, {:not_payable, status}}` when the link exists but is
  not `ACTIVE` — the two are different remediation paths and the caller needs to
  tell them apart.
  """
  @spec resolve(Ecto.UUID.t(), String.t()) ::
          {:ok, Ecto.UUID.t()} | {:error, :not_linked | {:not_payable, String.t()}}
  def resolve(employer_id, employee_id) do
    case get_link(employer_id, employee_id) do
      nil ->
        {:error, :not_linked}

      link ->
        if BeneficiaryLink.payable?(link) do
          {:ok, link.prepaid_account_id}
        else
          {:error, {:not_payable, link.status}}
        end
    end
  end

  @doc """
  Resolves many employee ids in one query.

  Returns a map of `employee_id => {:ok, account_id} | {:error, reason}`, with
  the same reasons `resolve/2` gives. Every requested id appears in the result,
  including the ones that failed — a caller processing a file needs a verdict
  per line, not a filtered list.
  """
  @spec resolve_many(Ecto.UUID.t(), [String.t()]) :: %{String.t() => term()}
  def resolve_many(employer_id, employee_ids) do
    ids = employee_ids |> Enum.map(&to_string/1) |> Enum.uniq()

    links =
      BeneficiaryLink
      |> where([l], l.employer_id == ^employer_id and l.employee_id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.employee_id, &1})

    Map.new(ids, fn employee_id ->
      result =
        case Map.get(links, employee_id) do
          nil ->
            {:error, :not_linked}

          link ->
            if BeneficiaryLink.payable?(link),
              do: {:ok, link.prepaid_account_id},
              else: {:error, {:not_payable, link.status}}
        end

      {employee_id, result}
    end)
  end

  @doc "The roster for an employer."
  @spec list_links(Ecto.UUID.t(), keyword()) :: [BeneficiaryLink.t()]
  def list_links(employer_id, opts \\ []) do
    BeneficiaryLink
    |> where([l], l.employer_id == ^employer_id)
    |> then(fn q ->
      case Keyword.get(opts, :status) do
        nil -> q
        status -> where(q, [l], l.status == ^status)
      end
    end)
    |> order_by([l], asc: l.employee_id)
    |> Repo.all()
  end

  @doc """
  Suspends a link — worker left, disputed, or KYC lapsed.

  The link and its history are kept. Suspension stops future disbursement; it
  does not reverse past ones, which is what an employer refund is for.
  """
  @spec suspend_link(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, BeneficiaryLink.t()} | {:error, term()}
  def suspend_link(employer_id, employee_id, reason) do
    case get_link(employer_id, employee_id) do
      nil ->
        {:error, :not_linked}

      link ->
        link
        |> BeneficiaryLink.changeset(%{status: "SUSPENDED", suspended_reason: reason})
        |> Repo.update()
    end
  end

  @doc """
  Accounts receiving salary from more than one employer.

  Not an error condition — second jobs are legal and common in this population
  — but it is a signal worth surfacing, because it is also what payroll fraud
  looks like. Returns `%{prepaid_account_id => [employer_id]}`.
  """
  @spec accounts_with_multiple_employers(String.t(), String.t()) :: %{Ecto.UUID.t() => [Ecto.UUID.t()]}
  def accounts_with_multiple_employers(sys_id, bank_id) do
    BeneficiaryLink
    |> join(:inner, [l], e in Employer, on: e.employer_id == l.employer_id)
    |> where([l, e], e.sys_id == ^sys_id and e.bank_id == ^bank_id)
    |> where([l, _e], not is_nil(l.prepaid_account_id) and l.status == "ACTIVE")
    |> select([l, _e], {l.prepaid_account_id, l.employer_id})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_account, employers} -> length(Enum.uniq(employers)) > 1 end)
    |> Map.new(fn {account, employers} -> {account, Enum.uniq(employers)} end)
  end
end
