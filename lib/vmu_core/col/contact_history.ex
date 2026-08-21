defmodule VmuCore.COL.ContactHistory do
  @moduledoc """
  Contact-attempt history (COL-P2, FR-COL-005) — the previously-missing piece
  that makes `col.contact_cap_*`/`col.contact_cooloff_hours` enforceable
  instead of config sitting unused.

  `record_attempt/3` is called by `DunningJob` after every automated dispatch
  (sms/email/letter/courier/registered_mail). `record_call/3` is a manual
  entry point for a collector logging a phone call outcome (FR-COL-005's
  "call outcomes, right-party-contact") — there is still no admin screen to
  drive it from; it exists so the capability is real at the code layer, the
  same honesty split DPS-P3 used for its stubbed adapters.

  Caps are enforced as rolling windows (last 24h for the daily SMS cap, last
  7 days for the weekly call/email caps), not calendar-day/week boundaries —
  simpler and avoids "reset exactly at midnight" edge cases.
  """

  import Ecto.Query

  # M2 (2026-07-17): config-injected — see vmu_shared's identical fix.
  @repo Application.compile_env(:vmu_col, :repo, VmuCore.Repo)
  alias VmuCore.COL.ContactAttempt
  alias VmuCore.Shared.ModuleConfigEngine

  @cap_by_channel %{
    "sms"   => {"contact_cap_sms_per_day", 24},
    "call"  => {"contact_cap_calls_per_week", 24 * 7},
    "email" => {"contact_cap_emails_per_week", 24 * 7}
  }

  @doc "Record a contact attempt. `opts`: :dpd_bucket, :outcome, :notes, :attempted_by (default \"SYSTEM_DUNNING\")."
  @spec record_attempt(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, ContactAttempt.t()} | {:error, Ecto.Changeset.t()}
  def record_attempt(account_id, channel, opts \\ []) do
    attrs = %{
      account_id:   account_id,
      channel:      channel,
      dpd_bucket:   Keyword.get(opts, :dpd_bucket),
      outcome:      Keyword.get(opts, :outcome),
      notes:        Keyword.get(opts, :notes),
      attempted_by: Keyword.get(opts, :attempted_by, "SYSTEM_DUNNING")
    }

    @repo.insert(ContactAttempt.changeset(%ContactAttempt{}, attrs))
  end

  @doc "Log a manual collector call outcome (FR-COL-005) — no admin UI drives this yet."
  @spec record_call(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, ContactAttempt.t()} | {:error, Ecto.Changeset.t()}
  def record_call(account_id, outcome, opts \\ []) do
    record_attempt(account_id, "call", Keyword.put(opts, :outcome, outcome))
  end

  @doc "Attempts of `channel` for this account since `since` (UTC datetime)."
  @spec count_since(Ecto.UUID.t(), String.t(), DateTime.t()) :: non_neg_integer()
  def count_since(account_id, channel, since) do
    @repo.one(
      from a in ContactAttempt,
        where: a.account_id == ^account_id and a.channel == ^channel and a.inserted_at >= ^since,
        select: count(a.id)
    )
  end

  @doc "Most recent contact attempt of any channel for this account, or nil."
  @spec last_attempt(Ecto.UUID.t()) :: ContactAttempt.t() | nil
  def last_attempt(account_id) do
    @repo.one(
      from a in ContactAttempt,
        where: a.account_id == ^account_id,
        order_by: [desc: a.inserted_at],
        limit: 1
    )
  end

  @doc "All contact attempts for an account, newest first."
  @spec list_for_account(Ecto.UUID.t(), non_neg_integer()) :: [ContactAttempt.t()]
  def list_for_account(account_id, limit \\ 100) do
    @repo.all(
      from a in ContactAttempt,
        where: a.account_id == ^account_id,
        order_by: [desc: a.inserted_at],
        limit: ^limit
    )
  end

  @doc """
  Whether `channel` is still within its configured cap for this account.
  Channels with no configured cap (letter/courier/registered_mail) always
  return true.
  """
  @spec within_cap?(Ecto.UUID.t(), String.t(), String.t(), String.t()) :: boolean()
  def within_cap?(account_id, channel, sys_id, bank_id) do
    case Map.get(@cap_by_channel, channel) do
      nil ->
        true

      {config_key, window_hours} ->
        {:ok, cap} = ModuleConfigEngine.get("col", config_key, sys_id, bank_id)
        since = DateTime.add(DateTime.utc_now(), -window_hours * 3600, :second)
        count_since(account_id, channel, since) < cap
    end
  end

  @doc "Whether enough time has passed since the last contact attempt (any channel)."
  @spec cooloff_ok?(Ecto.UUID.t(), String.t(), String.t()) :: boolean()
  def cooloff_ok?(account_id, sys_id, bank_id) do
    {:ok, cooloff_hours} = ModuleConfigEngine.get("col", "contact_cooloff_hours", sys_id, bank_id)

    cond do
      cooloff_hours <= 0 ->
        true

      true ->
        case last_attempt(account_id) do
          nil ->
            true

          %ContactAttempt{inserted_at: last_at} ->
            cutoff = DateTime.add(DateTime.utc_now(), -cooloff_hours * 3600, :second)
            DateTime.compare(last_at, cutoff) != :gt
        end
    end
  end
end
