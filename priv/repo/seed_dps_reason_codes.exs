# DPS-P4 — Seed illustrative Visa/Mastercard reason code reference data.
#
#   mix run priv/repo/seed_dps_reason_codes.exs
#
# Illustrative defaults only — validate against current Visa/Mastercard operating
# regulations before go-live (docs/tram/08_chargebacks_disputes.md §4). Idempotent
# (on_conflict: :nothing on the [network, reason_code] unique index).

alias VmuCore.Repo
alias VmuCore.DPS.ReasonCode

now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

rows = [
  %{network: "VI", reason_code: "10.4", description: "Other Fraud — Card-Absent Environment",
    category: "FRAUD", dispute_window_days: 120,
    evidence_required: ["fraud_affidavit", "avs_cvv_results"]},
  %{network: "VI", reason_code: "11.3", description: "No Authorization",
    category: "AUTHORIZATION", dispute_window_days: 90,
    evidence_required: ["authorization_log"]},
  %{network: "VI", reason_code: "12.5", description: "Incorrect Amount",
    category: "PROCESSING_ERROR", dispute_window_days: 120,
    evidence_required: ["original_receipt", "corrected_amount_proof"]},
  %{network: "VI", reason_code: "13.1", description: "Merchandise/Services Not Received",
    category: "CONSUMER_DISPUTE", dispute_window_days: 120,
    evidence_required: ["proof_of_non_receipt", "merchant_correspondence"]},
  %{network: "VI", reason_code: "13.7", description: "Cancelled Merchandise/Services",
    category: "CONSUMER_DISPUTE", dispute_window_days: 120,
    evidence_required: ["cancellation_proof", "merchant_correspondence"]},
  %{network: "MC", reason_code: "4837", description: "No Cardholder Authorization",
    category: "FRAUD", dispute_window_days: 120,
    evidence_required: ["fraud_affidavit"]},
  %{network: "MC", reason_code: "4853", description: "Cardholder Dispute",
    category: "CONSUMER_DISPUTE", dispute_window_days: 120,
    evidence_required: ["cardholder_statement", "merchant_correspondence"]},
  %{network: "MC", reason_code: "4855", description: "Goods/Services Not Provided",
    category: "CONSUMER_DISPUTE", dispute_window_days: 120,
    evidence_required: ["proof_of_non_receipt"]},
  %{network: "MC", reason_code: "4863", description: "Cardholder Does Not Recognize — Transaction",
    category: "FRAUD", dispute_window_days: 120,
    evidence_required: ["cardholder_statement"]}
]

attrs = Enum.map(rows, &Map.merge(&1, %{inserted_at: now, updated_at: now}))

{count, _} =
  Repo.insert_all(ReasonCode, attrs,
    on_conflict: :nothing,
    conflict_target: [:network, :reason_code]
  )

IO.puts("DPS reason codes seeded: #{count} new row(s) inserted.")
