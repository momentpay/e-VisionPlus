defmodule VmuCore.FAS.ResponseCodes do
  @moduledoc "ISO 8583 response codes used by the issuer FAS."

  # Approval
  def approved,            do: "00"
  def honour_vip,          do: "08"

  # Card-level declines
  def do_not_honour,       do: "05"
  def invalid_card,        do: "14"
  def no_bin_match,        do: "15"
  def pickup_card,         do: "43"  # LOST / STOLEN — instruct terminal to pickup card
  def expired_card,        do: "54"
  def wrong_pin,           do: "55"
  def not_permitted,       do: "57"
  def exceeds_limit,       do: "61"
  def restricted_card,     do: "62"
  def pin_tries_exceeded,  do: "75"
  def invalid_cvv,         do: "82"
  def duplicate_stan,      do: "94"

  # Account-level decline
  def insufficient_funds,  do: "51"

  # System
  def no_match,            do: "25"
  def switch_inoperative,  do: "91"
  def system_malfunction,  do: "96"

  @approved_codes ~w[00 08]

  @doc "True when the RC represents an approved transaction."
  def approved?(rc), do: rc in @approved_codes
end
