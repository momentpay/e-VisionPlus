defmodule VmuCore.MBS.MdrEngine do
  @moduledoc """
  MDR (Merchant Discount Rate) calculation engine.

  MDR = the percentage fee deducted from each transaction before settling
  to the merchant. It is composed of:
    - Interchange (set by Visa/Mastercard, flows through TRAMS)
    - Scheme fee (fixed per-transaction by network)
    - Acquirer margin (configured per mdr_template_id in ParameterEngine)

  MDR resolution priority (analogous to parameter cascade):
    mdr_template_id → logo defaults → bank defaults → system defaults

  Settlement net amount:
    net = gross_amount - (gross_amount × mdr_rate) - scheme_fee

  Rates are stored in ParameterEngine as:
    key = "mdr_<template_id>_rate"         value = "0.0175"  (1.75%)
    key = "mdr_<template_id>_scheme_fee"   value = "0.50"    (fixed AED/USD per txn)

  All monetary values use Decimal — never Float.
  """

  alias VmuCore.Shared.ParameterEngine
  alias Decimal, as: D

  @default_rate       "0.0200"
  @default_scheme_fee "0.50"

  @doc """
  Calculate MDR components for a transaction.

  Returns %{mdr_rate: Decimal, scheme_fee: Decimal, net_amount: Decimal, mdr_amount: Decimal}.
  """
  @spec calculate(Decimal.t(), String.t(), String.t(), String.t(), String.t() | nil) :: map()
  def calculate(gross_amount, sys_id, bank_id, logo_id, mdr_template_id) do
    rate       = resolve_rate(sys_id, bank_id, logo_id, mdr_template_id)
    scheme_fee = resolve_scheme_fee(sys_id, bank_id, logo_id, mdr_template_id)

    mdr_amount  = D.mult(gross_amount, rate) |> D.round(2)
    net_amount  = D.sub(gross_amount, D.add(mdr_amount, scheme_fee)) |> D.round(2)

    %{
      mdr_rate:    rate,
      mdr_amount:  mdr_amount,
      scheme_fee:  scheme_fee,
      net_amount:  net_amount
    }
  end

  @doc """
  Calculate net settlement for a batch of transactions.
  Returns %{gross_total: D, mdr_total: D, scheme_fee_total: D, net_total: D}.
  """
  def calculate_batch(transactions, sys_id, bank_id, logo_id) do
    Enum.reduce(transactions, %{gross: D.new(0), mdr: D.new(0), fees: D.new(0), net: D.new(0)},
      fn txn, acc ->
        result = calculate(txn.amount, sys_id, bank_id, logo_id, txn.mdr_template_id)
        %{
          gross: D.add(acc.gross, txn.amount),
          mdr:   D.add(acc.mdr, result.mdr_amount),
          fees:  D.add(acc.fees, result.scheme_fee),
          net:   D.add(acc.net, result.net_amount)
        }
      end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp resolve_rate(sys_id, bank_id, logo_id, template_id) do
    resolve_param(sys_id, bank_id, logo_id, template_id, "rate", D.new(@default_rate))
  end

  defp resolve_scheme_fee(sys_id, bank_id, logo_id, template_id) do
    resolve_param(sys_id, bank_id, logo_id, template_id, "scheme_fee", D.new(@default_scheme_fee))
  end

  defp resolve_param(sys_id, bank_id, logo_id, template_id, suffix, default) do
    key = "mdr_#{template_id || "default"}_#{suffix}"

    case ParameterEngine.get(sys_id, bank_id, logo_id, nil, key) do
      {:ok, val} ->
        case D.parse(val) do
          {d, ""} -> d
          _       -> default
        end
      _ -> default
    end
  end
end
