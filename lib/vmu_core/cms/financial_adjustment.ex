defmodule VmuCore.CMS.FinancialAdjustment do
  @moduledoc """
  Financial adjustment operator function — manual credit or debit postings
  made by an authorised supervisor outside the normal transaction flow.

  ## When adjustments are used

  - Goodwill credits (waive a charge that was not a fee)
  - Correction of a mis-posted purchase amount
  - Manual debit for a disputed chargeback recovered from the cardholder
  - Balance correction after a system error

  ## Security model

  Every adjustment requires:
    1. `operator_id`   — the agent who initiates it
    2. `supervisor_id` — a *different* supervisor who approves it (4-eyes rule)
    3. `reason`        — free-text justification (100 char max)
    4. `reference_id`  — external ticket or case number for traceability

  The operator and supervisor must be different UUIDs.

  ## GL posting

  | Direction | GL debit         | GL credit        | Effect on balance |
  |-----------|------------------|------------------|-------------------|
  | CREDIT    | 3001 (payment)   | 1001 (receivable)| Reduces balance   |
  | DEBIT     | 1001 (receivable)| 3001 (payment)   | Increases balance |

  Both directions post with `transaction_code: "ADJUSTMENT"`.

  ## Usage

      alias VmuCore.CMS.FinancialAdjustment

      {:ok, entry} = FinancialAdjustment.post_credit(
        account_id:    acc.account_id,
        amount:        Decimal.new("50.00"),
        reason:        "Goodwill credit — call centre resolution CAS-1234",
        reference_id:  "CAS-1234",
        operator_id:   agent_id,
        supervisor_id: supervisor_id,
        posting_date:  Date.utc_today()
      )
  """

  alias VmuCore.CMS.InternalGlPoster
  alias VmuCore.Posting.JournalEntry
  alias VmuCore.GL.LedgerQuery
  alias Decimal, as: D

  @doc """
  Post a credit adjustment — reduces the cardholder's outstanding balance.

  ## Options (keyword list)

    - `:account_id`    — (required) target account UUID
    - `:amount`        — (required) Decimal, must be > 0
    - `:reason`        — (required) free-text justification (max 100 chars)
    - `:reference_id`  — (required) external ticket / case reference
    - `:operator_id`   — (required) UUID of initiating agent
    - `:supervisor_id` — (required) UUID of approving supervisor (must differ from operator)
    - `:posting_date`  — `Date.t()` (default: `Date.utc_today/0`)

  Returns `{:ok, %Posting.JournalEntry{}}` or `{:error, reason}` — GL Phase C3
  changed the posting return from a `cms_ledger_entries` row to the journal entry.
  """
  @spec post_credit(keyword()) :: {:ok, JournalEntry.t()} | {:error, term()}
  def post_credit(opts) do
    post_adjustment(:credit, opts)
  end

  @doc """
  Post a debit adjustment — increases the cardholder's outstanding balance.

  Same options as `post_credit/1`.
  Returns `{:ok, %Posting.JournalEntry{}}` or `{:error, reason}` — GL Phase C3
  changed the posting return from a `cms_ledger_entries` row to the journal entry.
  """
  @spec post_debit(keyword()) :: {:ok, JournalEntry.t()} | {:error, term()}
  def post_debit(opts) do
    post_adjustment(:debit, opts)
  end

  @doc """
  List all adjustments for an account, newest first.

  GL Phase C2 — reads the posting tables via `GL.LedgerQuery`, and so returns
  maps rather than `CMS.LedgerEntry` structs. Each carries an explicit
  `:direction` and `:reference`.

  **`:direction` is now read, not inferred.** The display previously decided
  CREDIT vs DEBIT by testing whether the debit leg was the receivable account
  `"1001"`. That happened to be right, but it is the same class of assumption
  Phase 4A's account remap invalidated elsewhere, and it would have silently
  flipped every badge on this screen if the adjustment pair were ever
  renumbered. `posting_sets.event_type` states the direction outright.
  """
  @spec list_for(binary()) :: [map()]
  def list_for(account_id) do
    account_id
    |> then(&LedgerQuery.entries(account_ref: &1, transaction_code: "ADJUSTMENT"))
    |> Enum.map(fn e ->
      direction = if e.event_type == "ADJUSTMENT_DEBIT", do: "DEBIT", else: "CREDIT"

      e
      |> Map.put(:direction, direction)
      |> Map.put(:reference, reference_from_key(e.idempotency_key, account_id, e.posting_date))
    end)
  end

  # `post_adjustment/2` writes "ADJ:<direction>:<account>:<reference>:<date>".
  # The operator-supplied reference is the only free-form segment and may itself
  # contain colons, so it is recovered by stripping the two known ends rather
  # than by splitting — which would truncate any reference containing one.
  defp reference_from_key(nil, _account_id, _posting_date), do: nil

  defp reference_from_key(key, account_id, posting_date) do
    suffix = ":" <> Date.to_iso8601(posting_date)

    Enum.find_value(["credit", "debit"], key, fn dir ->
      prefix = "ADJ:#{dir}:#{account_id}:"

      with true <- String.starts_with?(key, prefix),
           true <- String.ends_with?(key, suffix) do
        key
        |> binary_slice(byte_size(prefix)..-(byte_size(suffix) + 1)//1)
      else
        _ -> nil
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp post_adjustment(direction, opts) do
    with :ok <- validate_opts(direction, opts) do
      account_id    = Keyword.fetch!(opts, :account_id)
      amount        = Keyword.fetch!(opts, :amount)
      reason        = Keyword.fetch!(opts, :reason)
      reference_id  = Keyword.fetch!(opts, :reference_id)
      operator_id   = Keyword.fetch!(opts, :operator_id)
      supervisor_id = Keyword.fetch!(opts, :supervisor_id)
      posting_date  = Keyword.get(opts, :posting_date, Date.utc_today())

      idempotency_key = "ADJ:#{direction}:#{account_id}:#{reference_id}:#{Date.to_iso8601(posting_date)}"

      narrative = build_narrative(direction, reason, operator_id, supervisor_id)

      {gl_dr, gl_cr} = gl_accounts_for(direction)

      InternalGlPoster.post(%{
        account_id:       account_id,
        idempotency_key:  idempotency_key,
        transaction_code: "ADJUSTMENT",
        dr_amount:        amount,
        cr_amount:        amount,
        gl_account_dr:    gl_dr,
        gl_account_cr:    gl_cr,
        posting_date:     posting_date,
        value_date:       posting_date,
        narrative:        narrative,
        source_ref:       reference_id
      })
    end
  end

  defp validate_opts(direction, opts) do
    required = [:account_id, :amount, :reason, :reference_id, :operator_id, :supervisor_id]

    missing = Enum.filter(required, &(!Keyword.has_key?(opts, &1)))

    cond do
      missing != [] ->
        {:error, {:missing_fields, missing}}

      direction not in [:credit, :debit] ->
        {:error, {:invalid_direction, direction}}

      not is_decimal_positive?(Keyword.get(opts, :amount)) ->
        {:error, :amount_must_be_positive}

      Keyword.get(opts, :operator_id) == Keyword.get(opts, :supervisor_id) ->
        {:error, :operator_and_supervisor_must_differ}

      String.length(Keyword.get(opts, :reason, "")) > 100 ->
        {:error, :reason_too_long}

      true ->
        :ok
    end
  end

  defp is_decimal_positive?(nil), do: false
  defp is_decimal_positive?(%Decimal{} = d), do: D.compare(d, D.new(0)) == :gt
  defp is_decimal_positive?(_), do: false

  # CREDIT: reduces cardholder balance (payment liability debited, receivable credited)
  defp gl_accounts_for(:credit), do: {"3001", "1001"}
  # DEBIT:  increases cardholder balance (receivable debited, payment liability credited)
  defp gl_accounts_for(:debit),  do: {"1001", "3001"}

  defp build_narrative(direction, reason, operator_id, supervisor_id) do
    dir_label = if direction == :credit, do: "CR ADJ", else: "DR ADJ"
    "#{dir_label} | op=#{String.slice(to_string(operator_id), 0, 8)} " <>
    "sup=#{String.slice(to_string(supervisor_id), 0, 8)} | #{reason}"
  end
end
