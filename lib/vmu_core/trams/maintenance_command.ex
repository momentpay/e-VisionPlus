defmodule VmuCore.TRAMS.MaintenanceCommand do
  @moduledoc """
  Controlled manual corrections to transaction records (TRAM-P6 6D, spec 05).

  Non-financial by definition — amount changes go through
  `VmuCore.TRAMS.AdjustmentCommand`. Every applied action appends a
  `maintenance_applied` event carrying before/after values, so maintenance
  history is queryable exactly like lifecycle history (spec 05 §2.2).

  ## Dual control (maker-checker)

  | Action | Approval |
  |---|---|
  | DESCRIPTIVE_CORRECTION (merchant_name / merchant_id / mcc) | immediate — no downstream financial effect |
  | FLAG (fraud/compliance hold — blocks posting cycle) | immediate — blocking is the safe direction |
  | LINKAGE_CORRECTION (re-link clearing record) | second approver required |
  | STATUS_OVERRIDE (force lifecycle state) | second approver required |
  | REDRIVE (re-enqueue matching + posting) | second approver required |

  STATUS_OVERRIDE deliberately bypasses the state machine (that is its job —
  unsticking a transaction after an investigated failure) but the override is
  fully recorded: the event payload carries the forced from→to and the
  approving operator.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.TRAMS.{Transaction, MaintenanceAction, StateMachine, EventStore}

  @immediate_actions ~w[DESCRIPTIVE_CORRECTION FLAG]
  @descriptive_fields ~w[merchant_name merchant_id mcc]

  @doc """
  Request a maintenance action.

  Attrs: `:transaction_id`, `:action_type`, `:reason_code`, `:requested_by`,
  optional `:comment`, `:after_values` (map of proposed field changes —
  required for DESCRIPTIVE_CORRECTION / LINKAGE_CORRECTION / STATUS_OVERRIDE).

  Returns `{:ok, :applied, action}` (immediate actions) or
  `{:ok, :pending_approval, action}` or `{:error, reason}`.
  """
  @spec request(map()) ::
          {:ok, :applied | :pending_approval, MaintenanceAction.t()} | {:error, term()}
  def request(%{transaction_id: transaction_id, action_type: action_type,
                requested_by: requested_by} = attrs) do
    with %Transaction{} = txn <-
           Repo.get(Transaction, transaction_id) || {:error, :transaction_not_found},
         :ok <- validate_after_values(action_type, attrs[:after_values]) do
      after_values = attrs[:after_values] || %{}

      action_attrs = %{
        transaction_id: transaction_id,
        action_type:    action_type,
        reason_code:    Map.fetch!(attrs, :reason_code),
        comment:        attrs[:comment],
        before_values:  before_values(txn, after_values),
        after_values:   after_values,
        requested_by:   requested_by
      }

      if action_type in @immediate_actions do
        insert_and_apply(action_attrs, txn, requested_by)
      else
        case Repo.insert(MaintenanceAction.changeset(%MaintenanceAction{}, action_attrs)) do
          {:ok, action} -> {:ok, :pending_approval, action}
          {:error, cs}  -> {:error, cs}
        end
      end
    end
  end

  @doc "Approve a pending action (checker must differ from maker) and apply it."
  @spec approve(Ecto.UUID.t(), String.t()) ::
          {:ok, MaintenanceAction.t()} | {:error, term()}
  def approve(action_id, approved_by) do
    with %MaintenanceAction{} = action <-
           Repo.get(MaintenanceAction, action_id) || {:error, :not_found},
         :ok <- check_pending(action),
         :ok <- check_maker_checker(action, approved_by),
         %Transaction{} = txn <-
           Repo.get(Transaction, action.transaction_id) || {:error, :transaction_not_found} do
      apply_action(action, txn, approved_by)
    end
  end

  @doc "Reject a pending action, or lift an APPLIED FLAG (unblocks posting)."
  @spec reject(Ecto.UUID.t(), String.t()) ::
          {:ok, MaintenanceAction.t()} | {:error, term()}
  def reject(action_id, rejected_by) do
    case Repo.get(MaintenanceAction, action_id) do
      nil ->
        {:error, :not_found}

      %MaintenanceAction{status: s} = action when s == "PENDING_APPROVAL" or
                                                  (s == "APPLIED" and action.action_type == "FLAG") ->
        action
        |> MaintenanceAction.changeset(%{status: "REJECTED", approved_by: rejected_by})
        |> Repo.update()

      %MaintenanceAction{status: s} ->
        {:error, {:not_rejectable, s}}
    end
  end

  @doc "Pending actions for the ops approval queue."
  @spec pending(non_neg_integer()) :: [MaintenanceAction.t()]
  def pending(limit \\ 50) do
    Repo.all(
      from m in MaintenanceAction,
        where: m.status == "PENDING_APPROVAL",
        order_by: [asc: m.inserted_at],
        limit: ^limit
    )
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_after_values("DESCRIPTIVE_CORRECTION", av) when is_map(av) and av != %{} do
    if Enum.all?(Map.keys(av), &(to_string(&1) in @descriptive_fields)),
      do: :ok,
      else: {:error, {:invalid_fields, Map.keys(av)}}
  end

  defp validate_after_values("LINKAGE_CORRECTION", %{} = av) do
    if Map.has_key?(av, :clearing_id) or Map.has_key?(av, "clearing_id"),
      do: :ok,
      else: {:error, :clearing_id_required}
  end

  defp validate_after_values("STATUS_OVERRIDE", %{} = av) do
    state = av[:state] || av["state"]

    if state in StateMachine.states(),
      do: :ok,
      else: {:error, {:invalid_state, state}}
  end

  defp validate_after_values(type, _) when type in ~w[FLAG REDRIVE], do: :ok
  defp validate_after_values(_type, _), do: {:error, :after_values_required}

  defp before_values(txn, after_values) do
    after_values
    |> Map.keys()
    |> Map.new(fn key ->
      field = key |> to_string() |> String.to_existing_atom()
      {to_string(key), Map.get(txn, field)}
    end)
  rescue
    _ -> %{}
  end

  defp check_pending(%MaintenanceAction{status: "PENDING_APPROVAL"}), do: :ok
  defp check_pending(%MaintenanceAction{status: s}), do: {:error, {:not_pending, s}}

  defp check_maker_checker(%MaintenanceAction{requested_by: maker}, checker)
       when maker == checker,
       do: {:error, :maker_cannot_approve}

  defp check_maker_checker(_, _), do: :ok

  # ---------------------------------------------------------------------------
  # Application
  # ---------------------------------------------------------------------------

  defp insert_and_apply(action_attrs, txn, actor) do
    case Repo.insert(MaintenanceAction.changeset(%MaintenanceAction{}, action_attrs)) do
      {:ok, action} ->
        case apply_action(action, txn, actor) do
          {:ok, applied} -> {:ok, :applied, applied}
          error -> error
        end

      {:error, cs} ->
        {:error, cs}
    end
  end

  defp apply_action(action, txn, actor) do
    result =
      Repo.transaction(fn ->
        apply_effect(action, txn)

        action
        |> MaintenanceAction.changeset(%{
          status: "APPLIED",
          approved_by: actor,
          applied_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update!()
      end)

    case result do
      {:ok, applied} ->
        EventStore.append(action.transaction_id, "maintenance_applied", %{
          maintenance_id: action.id,
          action_type:    action.action_type,
          reason_code:    action.reason_code,
          before:         action.before_values,
          after:          action.after_values
        }, actor: actor)

        {:ok, applied}

      {:error, reason} ->
        Logger.error("[TRAMS.Maintenance] apply failed for #{action.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp apply_effect(%{action_type: "DESCRIPTIVE_CORRECTION", after_values: av}, txn) do
    changes =
      av
      |> Map.take(@descriptive_fields ++ Enum.map(@descriptive_fields, &String.to_atom/1))
      |> Map.new(fn {k, v} -> {k |> to_string() |> String.to_existing_atom(), v} end)

    txn |> Ecto.Changeset.change(changes) |> Repo.update!()
  end

  defp apply_effect(%{action_type: "LINKAGE_CORRECTION", after_values: av}, txn) do
    clearing_id = av[:clearing_id] || av["clearing_id"]
    txn |> Ecto.Changeset.change(clearing_id: clearing_id) |> Repo.update!()
  end

  defp apply_effect(%{action_type: "STATUS_OVERRIDE", after_values: av}, txn) do
    new_state = av[:state] || av["state"]

    Logger.warning("[TRAMS.Maintenance] STATUS_OVERRIDE #{txn.transaction_id}: " <>
                   "#{txn.state} → #{new_state} (state machine bypassed by design)")

    txn |> Ecto.Changeset.change(state: new_state) |> Repo.update!()
  end

  # FLAG: no field change — its existence in APPLIED status blocks the posting
  # cycle (checked by PostingCycleJob.fraud_flagged?/1)
  defp apply_effect(%{action_type: "FLAG"}, _txn), do: :ok

  # REDRIVE: re-enqueue the posting cycle (re-runs matching sweep + posting)
  defp apply_effect(%{action_type: "REDRIVE"}, _txn) do
    case Oban.insert(VmuCore.TRAMS.Oban.PostingCycleJob.new(%{})) do
      {:ok, _job} -> :ok
      {:error, reason} ->
        Logger.warning("[TRAMS.Maintenance] REDRIVE enqueue failed: #{inspect(reason)}")
        :ok
    end
  end
end
