defmodule VmuCore.Kyc.ConditionalLogicTest do
  @moduledoc """
  Pure unit tests, no DB. KYC-P3 (2026-07-29) conditional-visibility
  evaluator. See docs/kyc/KYC_Implementation_Tracker.md §4.
  """

  use ExUnit.Case, async: true

  alias VmuCore.Kyc.ConditionalLogic

  describe "field_visible?/3" do
    test "a field with no targeting rule is always visible" do
      assert ConditionalLogic.field_visible?("full_name", [], %{})
    end

    test "equals: visible only when the source field matches" do
      rules = [%{"target_field" => "other_id", "condition" => %{"field" => "country", "operator" => "equals", "value" => "IN"}}]

      refute ConditionalLogic.field_visible?("other_id", rules, %{"country" => "AE"})
      assert ConditionalLogic.field_visible?("other_id", rules, %{"country" => "IN"})
    end

    test "not_equals" do
      rules = [%{"target_field" => "x", "condition" => %{"field" => "type", "operator" => "not_equals", "value" => "individual"}}]

      refute ConditionalLogic.field_visible?("x", rules, %{"type" => "individual"})
      assert ConditionalLogic.field_visible?("x", rules, %{"type" => "corporate"})
    end

    test "contains" do
      rules = [%{"target_field" => "x", "condition" => %{"field" => "notes", "operator" => "contains", "value" => "urgent"}}]

      assert ConditionalLogic.field_visible?("x", rules, %{"notes" => "this is urgent please"})
      refute ConditionalLogic.field_visible?("x", rules, %{"notes" => "routine"})
    end

    test "greater_than / less_than" do
      gt_rules = [%{"target_field" => "x", "condition" => %{"field" => "turnover", "operator" => "greater_than", "value" => "100000"}}]
      assert ConditionalLogic.field_visible?("x", gt_rules, %{"turnover" => "250000"})
      refute ConditionalLogic.field_visible?("x", gt_rules, %{"turnover" => "50000"})

      lt_rules = [%{"target_field" => "x", "condition" => %{"field" => "turnover", "operator" => "less_than", "value" => "100000"}}]
      assert ConditionalLogic.field_visible?("x", lt_rules, %{"turnover" => "50000"})
      refute ConditionalLogic.field_visible?("x", lt_rules, %{"turnover" => "250000"})
    end

    test "is_empty / is_not_empty" do
      empty_rules = [%{"target_field" => "x", "condition" => %{"field" => "email", "operator" => "is_empty", "value" => nil}}]
      assert ConditionalLogic.field_visible?("x", empty_rules, %{})
      assert ConditionalLogic.field_visible?("x", empty_rules, %{"email" => ""})
      refute ConditionalLogic.field_visible?("x", empty_rules, %{"email" => "a@b.com"})

      not_empty_rules = [%{"target_field" => "x", "condition" => %{"field" => "email", "operator" => "is_not_empty", "value" => nil}}]
      refute ConditionalLogic.field_visible?("x", not_empty_rules, %{})
      assert ConditionalLogic.field_visible?("x", not_empty_rules, %{"email" => "a@b.com"})
    end

    test "in_array" do
      rules = [%{"target_field" => "x", "condition" => %{"field" => "country", "operator" => "in_array", "value" => ["AE", "SA", "KW"]}}]

      assert ConditionalLogic.field_visible?("x", rules, %{"country" => "AE"})
      refute ConditionalLogic.field_visible?("x", rules, %{"country" => "US"})
    end

    test "multiple rules on the same target field all require satisfaction" do
      rules = [
        %{"target_field" => "x", "condition" => %{"field" => "country", "operator" => "equals", "value" => "AE"}},
        %{"target_field" => "x", "condition" => %{"field" => "tier", "operator" => "equals", "value" => "CORPORATE"}}
      ]

      assert ConditionalLogic.field_visible?("x", rules, %{"country" => "AE", "tier" => "CORPORATE"})
      refute ConditionalLogic.field_visible?("x", rules, %{"country" => "AE", "tier" => "RETAIL"})
    end
  end

  describe "visible_fields/3" do
    test "filters a field list down to only the currently-visible ones" do
      fields = [
        %{"key" => "full_name", "label" => "Full Name"},
        %{"key" => "company_name", "label" => "Company Name"}
      ]

      rules = [%{"target_field" => "company_name", "condition" => %{"field" => "tier", "operator" => "equals", "value" => "CORPORATE"}}]

      assert Enum.map(ConditionalLogic.visible_fields(fields, rules, %{"tier" => "RETAIL"}), & &1["key"]) == ["full_name"]
      assert Enum.map(ConditionalLogic.visible_fields(fields, rules, %{"tier" => "CORPORATE"}), & &1["key"]) == ["full_name", "company_name"]
    end
  end
end
