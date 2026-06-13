defmodule VmuCore.CTA.EmbossingFileGenerator do
  @moduledoc """
  Generates the card personalisation (embossing) file for submission to the card bureau.

  File format: fixed-width ASCII, one record per card.
  Fields follow the Giesecke+Devrient / Thales common format:
    - Record type (1)
    - PAN token (19)     — bureau decrypts from HSM to recover real PAN
    - Expiry MMYY (4)
    - Cardholder name (26, left-justified, space-padded)
    - Service code (3)   — 101 for magnetic stripe + chip + PIN
    - Card sequence no (3)
    - CVC2 placeholder (3) — populated by HSM at bureau
    - Track 2 equivalent (37, encrypted)
    - Logo ID (4)
    - Filler (space to 128 chars)

  Each file is named: EMBOSS_YYYYMMDD_HHMMSS_<batch>.dat
  """

  require Logger
  alias VmuCore.CTA.StockInventory
  import Ecto.Query
  alias VmuCore.Repo

  @record_length 128
  @service_code  "101"

  @doc """
  Generate an embossing file for all pending orders, write to `output_dir`.
  Returns {:ok, file_path, record_count} or {:error, reason}.
  """
  def generate(output_dir \\ System.tmp_dir!()) do
    orders = pending_orders()

    if Enum.empty?(orders) do
      Logger.info("[EmbossGen] No pending orders — skipping")
      {:ok, nil, 0}
    else
      filename = "EMBOSS_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.dat"
      path = Path.join(output_dir, filename)

      records = Enum.map(orders, &format_record/1)
      File.write!(path, Enum.join(records, "\n"))

      Logger.info("[EmbossGen] Written #{length(records)} records to #{path}")
      {:ok, path, length(records)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp pending_orders do
    Repo.all(
      from o in "cta_embossing_orders",
        join: a in VmuCore.CMS.Account, on: a.account_id == o.account_id,
        where: o.order_status == "PENDING",
        select: %{
          order_id:        o.id,
          pan_token:       o.pan_token,
          expiry_date:     o.expiry_date,
          cardholder_name: o.cardholder_name,
          logo_id:         a.logo_id
        }
    )
  end

  defp format_record(order) do
    # Record type 'C' = card personalisation
    rec =
      "C" <>
      pad(order.pan_token, 19) <>
      pad(order.expiry_date, 4) <>
      pad(order.cardholder_name, 26) <>
      @service_code <>
      "001" <>       # card sequence number
      "   " <>       # CVC2 placeholder — HSM fills at bureau
      pad("", 37) <> # Track 2 encrypted — HSM fills at bureau
      pad(order.logo_id, 4)

    String.pad_trailing(rec, @record_length)
  end

  defp pad(value, length), do: String.slice(to_string(value) |> String.pad_trailing(length), 0, length)
end
