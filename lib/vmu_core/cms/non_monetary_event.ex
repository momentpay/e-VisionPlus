defmodule VmuCore.CMS.NonMonetaryEvent do
  @moduledoc """
  Non-monetary account maintenance events — changes that affect account data
  but do not post to the GL or alter the cardholder's balance.

  VisionPlus treats these as a distinct category from financial transactions.
  Each event creates an immutable audit record capturing what changed,
  who changed it, when, and the before/after values.

  ## Supported Event Types

  | Type             | Description                                           |
  |------------------|-------------------------------------------------------|
  | `address_change` | Mailing or billing address updated                   |
  | `phone_change`   | Contact phone number updated                         |
  | `email_change`   | Contact email address updated                        |
  | `cycle_change`   | Billing cycle date changed (requires logo approval)  |
  | `card_reissue`   | Card reissued (renewal, replacement, damage)         |
  | `limit_change`   | Credit limit increase or decrease                    |
  | `name_change`    | Legal name or emboss name update                     |
  | `pin_change`     | PIN change request (no old/new values stored)        |

  ## Usage

      alias VmuCore.CMS.NonMonetaryEvent

      # Record an address change
      {:ok, event} = NonMonetaryEvent.record(
        account_id: acc.account_id,
        event_type: "address_change",
        old_value:  %{"line1" => "Old St", "city" => "Dubai"},
        new_value:  %{"line1" => "New Ave", "city" => "Dubai"},
        reason:     "Customer request via call centre",
        operator_id: operator_id
      )

      # Query history
      events = NonMonetaryEvent.history_for(account_id)
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias VmuCore.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_event_types ~w[
    address_change
    phone_change
    email_change
    cycle_change
    card_reissue
    limit_change
    name_change
    pin_change
    closure_requested
    closure_cancelled
    account_closed
    account_reopened
    product_transfer
    dormancy_flagged
    dormancy_cleared
  ]

  @valid_operator_roles ~w[AGENT SUPERVISOR SYSTEM]

  schema "cms_non_monetary_events" do
    field :account_id,    :binary_id
    field :event_type,    :string
    field :old_value,     :map      # JSONB — before state (nil for pin_change)
    field :new_value,     :map      # JSONB — after state  (nil for pin_change)
    field :reason,        :string
    field :reference_id,  :string   # External reference (e.g. call ID, ticket number)
    field :operator_id,   :binary_id
    field :operator_role, :string, default: "AGENT"
    field :applied_at,    :naive_datetime

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  @required [:account_id, :event_type, :operator_id, :applied_at]
  @optional [:old_value, :new_value, :reason, :reference_id, :operator_role]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:event_type, @valid_event_types)
    |> validate_inclusion(:operator_role, @valid_operator_roles)
    |> validate_length(:reason, max: 255)
    |> validate_length(:reference_id, max: 50)
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Record a non-monetary maintenance event.

  ## Options

    - `:account_id`    — (required) target account UUID
    - `:event_type`    — (required) one of #{inspect(@valid_event_types)}
    - `:old_value`     — map of field(s) before change (omit for pin_change)
    - `:new_value`     — map of field(s) after change  (omit for pin_change)
    - `:reason`        — free-text reason / reference note
    - `:reference_id`  — call ID, ticket number, or other external ref
    - `:operator_id`   — (required) UUID of the operator making the change
    - `:operator_role` — "AGENT" | "SUPERVISOR" | "SYSTEM" (default: "AGENT")
    - `:applied_at`    — override applied_at (default: NaiveDateTime.utc_now/0)

  Returns `{:ok, %NonMonetaryEvent{}}` or `{:error, changeset}`.
  """
  @spec record(keyword()) :: {:ok, __MODULE__.t()} | {:error, Ecto.Changeset.t()}
  def record(opts) do
    attrs =
      opts
      |> Map.new()
      |> Map.put_new(:applied_at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns all non-monetary events for an account, ordered newest-first.
  """
  @spec history_for(binary()) :: [__MODULE__.t()]
  def history_for(account_id) do
    Repo.all(
      from e in __MODULE__,
        where: e.account_id == ^account_id,
        order_by: [desc: e.applied_at]
    )
  end

  @doc """
  Returns events for an account filtered by type, ordered newest-first.
  Useful for fetching the last cycle_change or last card_reissue.
  """
  @spec history_for(binary(), String.t()) :: [__MODULE__.t()]
  def history_for(account_id, event_type) do
    Repo.all(
      from e in __MODULE__,
        where: e.account_id == ^account_id and e.event_type == ^event_type,
        order_by: [desc: e.applied_at]
    )
  end

  @doc """
  Returns the most recent event of a given type, or nil.
  """
  @spec latest_for(binary(), String.t()) :: __MODULE__.t() | nil
  def latest_for(account_id, event_type) do
    Repo.one(
      from e in __MODULE__,
        where: e.account_id == ^account_id and e.event_type == ^event_type,
        order_by: [desc: e.applied_at],
        limit: 1
    )
  end

  @doc "All valid event types."
  def valid_event_types, do: @valid_event_types

  @doc """
  Record a `card_reissue` event and automatically post the card replacement
  fee (4F) if one is configured for the account's logo.

  `account_map` must include `:sys_id`, `:bank_id`, `:logo_id`, `:block_id`
  so the FeeEngine can resolve the `:card_replacement_fee` parameter.

  Returns `{:ok, event, fee_result}` where `fee_result` is one of:
    - `:ok` — fee posted successfully
    - `{:skipped, reason}` — fee not configured or zero
    - `{:error, reason}` — fee post failed (event still recorded)
  """
  @spec record_card_reissue(keyword(), map()) ::
          {:ok, __MODULE__.t(), atom() | {:skipped | :error, term()}} | {:error, Ecto.Changeset.t()}
  def record_card_reissue(opts, account_map) do
    opts_with_type = Keyword.put(opts, :event_type, "card_reissue")

    case record(opts_with_type) do
      {:ok, event} ->
        fee_result =
          VmuCore.CMS.FeeEngine.assess_card_replacement_fee(
            event.account_id,
            account_map,
            event.id,
            Date.utc_today()
          )
        {:ok, event, fee_result}

      {:error, _} = err ->
        err
    end
  end
end
