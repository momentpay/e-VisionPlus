defmodule VmuCore.Kyc.ConditionalLogic do
  @moduledoc """
  Pure conditional-visibility evaluator for `kyc_methods.conditional_rules`
  (KYC-P3, `docs/kyc/KYC_Implementation_Tracker.md` §4). Ported 1:1 from the
  MMS reference's real rule shape (already proven twice — MMS Laravel, and
  Avenza's `wallet_kyc`):

      %{"target_field" => key, "condition" => %{"field" => key, "operator" => op, "value" => v}}

  No persistence of its own — `Kyc.Method.conditional_rules` already exists
  as a column (added in KYC-P1, unused until now).
  """

  @operators ~w[equals not_equals contains greater_than less_than is_empty is_not_empty in_array]

  @doc "The fixed list of supported condition operators, for the rule-builder UI."
  @spec operators() :: [String.t()]
  def operators, do: @operators

  @doc """
  Given a method's `conditional_rules` and the currently-submitted `data`,
  return whether `field_key` should be visible. A field with no rule
  targeting it is always visible.
  """
  @spec field_visible?(String.t(), [map()], map()) :: boolean()
  def field_visible?(field_key, rules, data) when is_list(rules) do
    case Enum.filter(rules, &(&1["target_field"] == field_key)) do
      [] -> true
      field_rules -> Enum.all?(field_rules, &condition_true?(&1["condition"], data))
    end
  end

  def field_visible?(_field_key, _rules, _data), do: true

  @doc "Return the subset of `fields` (field defs) currently visible given `rules` and `data`."
  @spec visible_fields([map()], [map()], map()) :: [map()]
  def visible_fields(fields, rules, data) when is_list(fields) do
    Enum.filter(fields, &field_visible?(&1["key"], rules, data))
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp condition_true?(nil, _data), do: true

  defp condition_true?(%{"field" => field, "operator" => op, "value" => expected}, data) do
    evaluate(Map.get(data, field), op, expected)
  end

  defp condition_true?(_condition, _data), do: true

  defp evaluate(value, "equals", expected), do: to_string(value || "") == to_string(expected)
  defp evaluate(value, "not_equals", expected), do: to_string(value || "") != to_string(expected)
  defp evaluate(value, "contains", expected), do: is_binary(value) and String.contains?(value, to_string(expected))
  defp evaluate(value, "greater_than", expected), do: numeric_compare(value, expected, &Kernel.>/2)
  defp evaluate(value, "less_than", expected), do: numeric_compare(value, expected, &Kernel.</2)
  defp evaluate(value, "is_empty", _expected), do: blank?(value)
  defp evaluate(value, "is_not_empty", _expected), do: not blank?(value)
  defp evaluate(value, "in_array", expected) when is_list(expected), do: value in expected
  defp evaluate(_value, _op, _expected), do: false

  defp numeric_compare(value, expected, comparator) do
    with {v, ""} <- value |> to_string() |> Float.parse(),
         {e, ""} <- expected |> to_string() |> Float.parse() do
      comparator.(v, e)
    else
      _ -> false
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
