defmodule VmuCore.Shared.SysParameter do
  @moduledoc """
  VisionPlus SYSTEM control record — global processor-level defaults.

  The SYS record is the root of the parameter hierarchy:

      SYS  →  BANK  →  LOGO  →  BLOCK

  All lower levels inherit from SYS unless they override a value explicitly.

  ## Key Fields

  - `base_currency`      — ISO 4217 code used for all monetary values (e.g. "AED")
  - `batch_controls`     — EOD batch window, retry limits, job sequencing
  - `cycle_controls`     — default billing cycle day and cycle length
  - `global_status_codes`— list of valid account_status values for this processor
  - `posting_rules`      — posting window hours, backdating limit (days), cutoff time

  ## batch_controls Example

      %{
        "eod_window_start" => "22:00",
        "eod_window_end"   => "04:00",
        "max_job_retries"  => 3,
        "lock_timeout_sec" => 120
      }

  ## cycle_controls Example

      %{
        "default_cycle_day"    => 1,
        "cycle_length_days"    => 30,
        "grace_days_default"   => 25
      }

  ## posting_rules Example

      %{
        "posting_cutoff_time"  => "23:59",
        "max_backdate_days"    => 3,
        "same_day_value"       => true
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:sys_id, :string, []}

  schema "sys_parameters" do
    field :description,        :string
    field :base_currency,      :string, default: "AED"

    # Extended control fields
    field :batch_controls,     :map
    field :cycle_controls,     :map
    field :global_status_codes, {:array, :string}
    field :posting_rules,      :map

    timestamps()
  end

  @required [:sys_id, :description]
  @optional [:base_currency, :batch_controls, :cycle_controls,
             :global_status_codes, :posting_rules]

  def changeset(sys_parameter, attrs) do
    sys_parameter
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:sys_id,       is: 4)
    |> validate_length(:base_currency, is: 3)
  end

  # ── Convenience accessors ───────────────────────────────────────────────────

  @doc "EOD batch window start time string, e.g. \"22:00\". Nil if not configured."
  def eod_window_start(%__MODULE__{batch_controls: bc}), do: bc && Map.get(bc, "eod_window_start")

  @doc "Default cycle length in days (falls back to 30)."
  def cycle_length_days(%__MODULE__{cycle_controls: cc}) do
    (cc && Map.get(cc, "cycle_length_days")) || 30
  end

  @doc "Maximum days a posting can be backdated (falls back to 3)."
  def max_backdate_days(%__MODULE__{posting_rules: pr}) do
    (pr && Map.get(pr, "max_backdate_days")) || 3
  end
end
