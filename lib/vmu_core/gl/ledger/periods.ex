defmodule VmuCore.GL.Periods do
  @moduledoc """
  Banking dates, accounting periods, and the gate every posting must pass
  (GL Phase A4).

  `validate_gl_date/3` is the enforcement point. It answers one question —
  *may a posting with this GL date be accepted?* — and it is the reason the
  platform can now have a defensible cut-off at all.

  Nothing calls it yet; A5's rule engine will.
  """

  import Ecto.Query, warn: false

  alias VmuCore.Repo
  alias VmuCore.GL.{BankingDate, Period, PostingException}

  # ---------------------------------------------------------------------------
  # Banking date
  # ---------------------------------------------------------------------------

  @spec banking_date(String.t(), String.t()) :: BankingDate.t() | nil
  def banking_date(sys_id, bank_id), do: Repo.get_by(BankingDate, sys_id: sys_id, bank_id: bank_id)

  @doc "Opens `date` as the institution's banking day."
  @spec open_banking_date(String.t(), String.t(), Date.t()) ::
          {:ok, BankingDate.t()} | {:error, Ecto.Changeset.t()}
  def open_banking_date(sys_id, bank_id, date) do
    (banking_date(sys_id, bank_id) || %BankingDate{})
    |> BankingDate.changeset(%{
      sys_id: sys_id, bank_id: bank_id,
      current_banking_date: date, status: "OPEN",
      opened_at: DateTime.utc_now(), closed_at: nil
    })
    |> Repo.insert_or_update()
  end

  @doc """
  Closes the current banking day and records the close point.

  `last_closed_date` becomes WAY4's `CLOSE_GL` consistency point: anything
  arriving afterwards with a `gl_date` on or before it is an exception.
  """
  @spec close_banking_date(String.t(), String.t()) ::
          {:ok, BankingDate.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def close_banking_date(sys_id, bank_id) do
    case banking_date(sys_id, bank_id) do
      nil ->
        {:error, :not_found}

      bd ->
        bd
        |> BankingDate.changeset(%{
          status: "CLOSED",
          last_closed_date: bd.current_banking_date,
          closed_at: DateTime.utc_now()
        })
        |> Repo.update()
    end
  end

  # ---------------------------------------------------------------------------
  # Periods
  # ---------------------------------------------------------------------------

  @spec create_period(String.t(), String.t(), Date.t(), Date.t()) ::
          {:ok, Period.t()} | {:error, Ecto.Changeset.t()}
  def create_period(sys_id, bank_id, period_start, period_end) do
    %Period{}
    |> Period.changeset(%{
      sys_id: sys_id, bank_id: bank_id,
      period_start: period_start, period_end: period_end, status: "OPEN"
    })
    |> Repo.insert()
  end

  @doc "The period covering `date`, whatever its status."
  @spec period_for(String.t(), String.t(), Date.t()) :: Period.t() | nil
  def period_for(sys_id, bank_id, date) do
    Period
    |> where([p], p.sys_id == ^sys_id and p.bank_id == ^bank_id)
    |> where([p], p.period_start <= ^date and p.period_end >= ^date)
    |> Repo.one()
  end

  @spec close_period(Period.t(), String.t()) :: {:ok, Period.t()} | {:error, Ecto.Changeset.t()}
  def close_period(%Period{} = period, closed_by) do
    period
    |> Period.changeset(%{status: "CLOSED", closed_at: DateTime.utc_now(), closed_by: closed_by})
    |> Repo.update()
  end

  @doc "Locks a period permanently. A locked period can never be reopened."
  @spec lock_period(Period.t()) :: {:ok, Period.t()} | {:error, :not_closed | Ecto.Changeset.t()}
  def lock_period(%Period{status: "CLOSED"} = period) do
    period
    |> Period.changeset(%{status: "LOCKED", locked_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def lock_period(%Period{}), do: {:error, :not_closed}

  @doc "Reopens a closed period. Refuses on LOCKED — that is the point of locking."
  @spec reopen_period(Period.t()) :: {:ok, Period.t()} | {:error, :locked | Ecto.Changeset.t()}
  def reopen_period(%Period{status: "LOCKED"}), do: {:error, :locked}

  def reopen_period(%Period{} = period) do
    period
    |> Period.changeset(%{status: "OPEN", closed_at: nil, closed_by: nil})
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # The gate
  # ---------------------------------------------------------------------------

  @doc """
  May a posting with this `gl_date` be accepted?

  Returns `{:ok, period}` when it may, or `{:error, reason}` naming which
  rule refused — the reasons map 1:1 onto `PostingException.reasons/0`, so a
  refusal can be quarantined without re-deriving why.

  Checked in order of severity:

  1. The institution's books are open at all.
  2. `gl_date` is after the last close point (WAY4's `CLOSE_GL` consistency point).
  3. A period covers `gl_date`.
  4. That period is OPEN.
  """
  @spec validate_gl_date(String.t(), String.t(), Date.t()) ::
          {:ok, Period.t()}
          | {:error, :BANKING_DATE_CLOSED | :GL_DATE_BEFORE_CLOSE_POINT | :NO_OPEN_PERIOD |
                     :GL_DATE_IN_CLOSED_PERIOD}
  def validate_gl_date(sys_id, bank_id, gl_date) do
    bd = banking_date(sys_id, bank_id)

    cond do
      is_nil(bd) or not BankingDate.open?(bd) ->
        {:error, :BANKING_DATE_CLOSED}

      not is_nil(bd.last_closed_date) and Date.compare(gl_date, bd.last_closed_date) != :gt ->
        {:error, :GL_DATE_BEFORE_CLOSE_POINT}

      true ->
        case period_for(sys_id, bank_id, gl_date) do
          nil -> {:error, :NO_OPEN_PERIOD}
          %Period{status: "OPEN"} = p -> {:ok, p}
          %Period{} -> {:error, :GL_DATE_IN_CLOSED_PERIOD}
        end
    end
  end

  @doc """
  Quarantines a refused posting.

  Deliberately never raises and never rolls the caller back: losing a real
  financial event is worse than recording it as an exception.
  """
  @spec quarantine(String.t(), String.t(), Date.t(), atom(), keyword()) ::
          {:ok, PostingException.t()} | {:error, Ecto.Changeset.t()}
  def quarantine(sys_id, bank_id, gl_date, reason, opts \\ []) do
    bd = banking_date(sys_id, bank_id)

    %PostingException{}
    |> PostingException.changeset(%{
      sys_id: sys_id,
      bank_id: bank_id,
      attempted_gl_date: gl_date,
      banking_date: opts[:banking_date] || (bd && bd.current_banking_date) || gl_date,
      close_point: bd && bd.last_closed_date,
      reason: Atom.to_string(reason),
      detail: opts[:detail],
      posting_set_id: opts[:posting_set_id]
    })
    |> Repo.insert()
  end

  @doc "Unresolved exceptions. Should be empty in a healthy system."
  @spec open_exceptions(String.t(), String.t()) :: [PostingException.t()]
  def open_exceptions(sys_id, bank_id) do
    PostingException
    |> where([e], e.sys_id == ^sys_id and e.bank_id == ^bank_id and e.resolved == false)
    |> order_by([e], desc: e.inserted_at)
    |> Repo.all()
  end
end
