defmodule VmuCore.CMS.Bureau.FormatSpec do
  @moduledoc """
  Configurable bureau format layouts (CMS-G5.2, per the 2026-07-05 review
  decision: *"use the web-based publicly available [specs] and keep this
  configurable, so that it can be modified later"*).

  ## How configurability works

  Every layout below is a **default**, derived from publicly available
  documentation of each format's structure. Any part can be replaced at
  runtime without touching generator code:

      config :vmu_core, :bureau_format_overrides, %{
        "CIBIL_TUDF" => %{
          version: "12",
          member_id: "NB1234567890",
          segments: %{
            # replaces ONLY the TL segment's field list
            "TL" => [
              %{tag: "01", source: {:literal, "NB1234567890"}, max: 30},
              ...
            ]
          }
        },
        "AECB" => %{delimiter: ",", account_fields: [...]}
      }

  Top-level keys override wholesale; `:segments` merges per segment id
  (an overridden segment replaces that segment's field list entirely —
  explicit beats clever merging for a compliance artifact).

  ## Source + validation status

  - **CIBIL_TUDF** (India): structure per TransUnion CIBIL's TUDF /
    RBI-mandated Uniform Credit Reporting Format (UCRF) — publicly
    documented segment model: fixed-length `TUDF` header + `TRLR` trailer
    and `ES` end-of-subject, with variable tag-length-value segments
    PN (name), ID, PT (phone), PA (address), TL (account/trade line);
    dates DDMMYYYY; TL carries balances/DPD. Public sources confirm the
    *structure*; exact byte positions live in the member-distributed
    "Uniform Credit Reporting Format – Consumer Repository" guide
    (v3.7x, experian.in/RBI mirrors). ⚠ **Default field layouts below are
    a structured draft — validate against the member's official spec
    version before production submission; corrections go into the
    override config, not code.**
  - **AECB** (UAE, Al Etihad Credit Bureau): no public technical spec —
    provider Data Standards Manual is portal-gated. Default below is a
    delimited provider-file skeleton (header / data / trailer records);
    the real column set drops into the override when the manual is
    available. Same ⚠ as above, more so.
  """

  @doc "Resolved spec for a format key — defaults deep-merged with overrides."
  @spec spec(String.t()) :: map()
  def spec(format_key) do
    default = default_spec(format_key)

    override =
      Application.get_env(:vmu_core, :bureau_format_overrides, %{})
      |> Map.get(format_key, %{})

    merge_spec(default, override)
  end

  # ---------------------------------------------------------------------------
  # Defaults
  # ---------------------------------------------------------------------------

  defp default_spec("CIBIL_TUDF") do
    %{
      name: "CIBIL_TUDF",
      date_format: :ddmmyyyy,
      version: "12",
      # TUDF member (reporting institution) id — MUST be overridden with the
      # institution's CIBIL member id
      member_id: "MEMBER_ID_UNSET",
      # Variable segments: tag(2) + length(2) + value, per TUDF convention.
      # Order within each subject: PN → ID → PT → PA → TL.
      segments: %{
        "PN" => [
          %{tag: "01", source: {:customer, :first_name}, max: 26},
          %{tag: "02", source: {:customer, :last_name}, max: 26},
          %{tag: "07", source: {:customer, :date_of_birth}, max: 8},
          %{tag: "08", source: {:customer, :gender}, max: 1}
        ],
        "ID" => [
          %{tag: "01", source: {:customer, :id_type}, max: 2},
          %{tag: "02", source: {:customer, :id_number}, max: 30}
        ],
        "PT" => [
          %{tag: "01", source: {:customer, :mobile_number}, max: 20}
        ],
        "PA" => [
          %{tag: "01", source: {:customer, :address_line1}, max: 40},
          %{tag: "03", source: {:customer, :city}, max: 20},
          %{tag: "06", source: {:customer, :postal_code}, max: 10}
        ],
        "TL" => [
          %{tag: "01", source: {:computed, :masked_account_ref}, max: 25},
          %{tag: "04", source: {:computed, :account_open_date}, max: 8},
          %{tag: "08", source: {:computed, :report_date}, max: 8},
          %{tag: "12", source: {:account, :credit_limit}, max: 9},
          %{tag: "13", source: {:computed, :outstanding}, max: 9},
          %{tag: "15", source: {:computed, :days_past_due}, max: 3}
        ]
      }
    }
  end

  defp default_spec("AECB") do
    %{
      name: "AECB",
      date_format: :yyyymmdd,
      delimiter: "|",
      provider_code: "PROVIDER_UNSET",
      # Header / per-account / trailer records, first column = record type
      header_fields: [
        {:literal, "H"},
        {:computed, :report_date}
      ],
      account_fields: [
        {:literal, "D"},
        {:computed, :masked_account_ref},
        {:customer, :id_number},
        {:customer, :first_name},
        {:customer, :last_name},
        {:computed, :account_open_date},
        {:account, :credit_limit},
        {:computed, :outstanding},
        {:computed, :days_past_due},
        {:account, :account_status}
      ],
      trailer_fields: [
        {:literal, "T"},
        {:computed, :record_count}
      ]
    }
  end

  # ---------------------------------------------------------------------------
  # Merge
  # ---------------------------------------------------------------------------

  defp merge_spec(default, override) when override == %{}, do: default

  defp merge_spec(default, override) do
    merged = Map.merge(default, Map.drop(override, [:segments, "segments"]))

    case override[:segments] || override["segments"] do
      nil -> merged
      seg_overrides -> Map.put(merged, :segments, Map.merge(default[:segments] || %{}, seg_overrides))
    end
  end
end
