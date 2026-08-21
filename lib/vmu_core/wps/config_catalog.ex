defmodule VmuCore.WPS.ConfigCatalog do
  @moduledoc """
  WPS module configuration (Phase W2).

  ## Why the file layout is configuration, not code

  There is no single "WPS file format". The UAE, Saudi Arabia and Bahrain each
  run their own Wage Protection scheme with its own layout, and a bank or
  exchange house intermediating for several markets sees all of them — plus
  whatever variation an individual employer's payroll system emits.

  `WPS_Module_Requirements.md` answers Open Question 2 with *"we have to be open
  as per market as we are building the product"*, and its §4 warns
  *"don't guess a file format, get the real spec"*. Both point the same way:
  the layout belongs in configuration.

  This is the same conclusion `COL.AgencyDesk` reached for collections agencies,
  whose config moduledoc says *"agency file layouts genuinely vary by
  region/agency; a fixed CSV/JSON schema per agency was the wrong long-term
  shape."* WPS reuses that pattern deliberately rather than inventing a second
  one.

  The practical effect: **a missing scheme specification is not a blocker.**
  Onboarding a new market is a configuration entry, not a code change.

  ## `wps.employer_config` shape

  Keyed by employer code, per bank (scope `:bank`):

      %{
        "EMP001" => %{
          "file_format"   => "CSV" | "FIXED_WIDTH",

          # CSV only.
          "delimiter"     => ",",
          "has_header"    => true,
          "skip_lines"    => 0,

          # Their header name (or, for FIXED_WIDTH, their field name) => our
          # canonical field. Any header not listed passes through unchanged, so
          # an employer already sending our names needs none of this.
          #
          # Canonical fields: employee_id, employee_name, payment_reference,
          # gross_amount, deduction_amount, net_amount, currency,
          # pay_period_start, pay_period_end, payment_date.
          "import_mapping" => %{
            "EmpID"    => "employee_id",
            "NetPay"   => "net_amount",
            "PayDate"  => "payment_date"
          },

          # FIXED_WIDTH only: canonical field => {start, length}, 1-based.
          # Positions come from the scheme's published record layout.
          "fixed_width_fields" => %{
            "employee_id" => [1, 20],
            "net_amount"  => [21, 15]
          },

          # strptime-style. Absent => ISO-8601 (yyyy-mm-dd). The GCC schemes
          # commonly use positional "%Y%m%d".
          "date_format"   => "%Y%m%d",

          # How amounts are written. "decimal" is a plain "1234.56".
          # "implied_2dp" is an integer of minor units — "123456" meaning
          # 1234.56 — which fixed-width salary files use almost universally and
          # which is the single most dangerous field to guess: read it wrong and
          # every worker is paid a hundred times too much or too little.
          "amount_format" => "decimal" | "implied_2dp",

          "currency"      => "AED"
        }
      }
  """

  @spec entries() :: [VmuCore.Shared.ModuleConfigCatalog.spec()]
  def entries do
    [
      %{
        key: "employer_config",
        module: "wps",
        type: :map,
        allowed: nil,
        default: %{},
        scope: :bank,
        description:
          "Per-employer salary-file layout, keyed by employer code. file_format " <>
            "(CSV | FIXED_WIDTH), import_mapping (their column name => our canonical " <>
            "field), fixed_width_fields (field => [start, length], 1-based), " <>
            "date_format (strptime-style, default ISO-8601), amount_format " <>
            "(decimal | implied_2dp), currency, delimiter, has_header, skip_lines. " <>
            "All optional — absent means this repository's own field names, " <>
            "ISO-8601 dates and plain decimal amounts. Layouts vary by scheme " <>
            "(UAE/Saudi/Bahrain) and by employer payroll system, which is why they " <>
            "are configured rather than coded."
      },
      %{
        key: "duplicate_file_policy",
        module: "wps",
        type: :enum,
        allowed: ["reject", "warn"],
        default: "reject",
        scope: :bank,
        description:
          "What to do when a file whose content hash was already ingested arrives " <>
            "again. 'reject' refuses it outright; 'warn' ingests it and flags the " <>
            "duplicate for an operator. Defaults to reject, because the failure it " <>
            "guards against is paying every worker on the file twice."
      },
      %{
        key: "require_net_equals_gross_minus_deductions",
        module: "wps",
        type: :boolean,
        allowed: nil,
        default: true,
        scope: :bank,
        description:
          "Validate that net = gross - deductions on every line where all three " <>
            "are present. A file failing this is usually a column-mapping error " <>
            "rather than a payroll error, which makes it the cheapest available " <>
            "check that the layout config is right."
      }
    ]
  end
end
