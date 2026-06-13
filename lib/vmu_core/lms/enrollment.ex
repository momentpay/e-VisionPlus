defmodule VmuCore.LMS.Enrollment do
  @moduledoc "Manages LMS account enrollment (auto on CDM approval, or manual via ASM)."

  alias VmuCore.LMS.Account
  alias VmuCore.Repo

  @doc """
  Enroll an AR account in a scheme.
  On_conflict: :nothing ensures idempotency — duplicate calls are safe.
  Returns {:ok, lms_account} or {:ok, :already_enrolled} or {:error, reason}.
  """
  def enroll(ar_account_id, scheme_id, opts \\ []) do
    method         = Keyword.get(opts, :method, "MANUAL")
    lms_account_no = generate_lms_account_no(scheme_id)

    cs = %Account{}
    |> Account.changeset(%{
      lms_account_no:   lms_account_no,
      ar_account_id:    ar_account_id,
      scheme_id:        scheme_id,
      enrollment_date:  Date.utc_today(),
      enrollment_method: method,
      status:           "ACTIVE"
    })

    case Repo.insert(cs, on_conflict: :nothing, conflict_target: [:ar_account_id, :scheme_id]) do
      {:ok, %Account{id: nil}} -> {:ok, :already_enrolled}
      {:ok, account}           -> {:ok, account}
      {:error, cs}             -> {:error, cs}
    end
  end

  @doc "Unenroll an account from a scheme (sets status=CLOSED)."
  def unenroll(lms_account_id) do
    import Ecto.Query
    Repo.update_all(
      from(a in Account, where: a.id == ^lms_account_id),
      set: [status: "CLOSED", updated_at: DateTime.utc_now()]
    )
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp generate_lms_account_no(scheme_id) do
    ts = System.system_time(:microsecond)
    "LMS#{String.pad_leading(to_string(scheme_id), 4, "0")}#{ts}"
  end
end
