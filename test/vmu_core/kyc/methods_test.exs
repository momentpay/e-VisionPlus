defmodule VmuCore.Kyc.MethodsTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. KYC-P1 (2026-07-29) — method
  template schema, per-product scoping, version bump, clone-to-product.
  See docs/kyc/KYC_Implementation_Tracker.md.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.Kyc.{Method, Methods}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp valid_fields do
    [
      %{"key" => "full_name", "label" => "Full Name", "type" => "text", "required" => true, "options" => []},
      %{"key" => "id_number", "label" => "ID Number", "type" => "text", "required" => true, "options" => []}
    ]
  end

  defp method_attrs(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        "name" => "Test Method #{n}",
        "title" => "Test Method Title #{n}",
        "product_type" => "DEBIT",
        "status" => "active",
        "fields" => valid_fields()
      },
      overrides
    )
  end

  test "creates a method scoped to a real product_type" do
    assert {:ok, method} = Methods.create(method_attrs())
    assert method.product_type == "DEBIT"
    assert method.version == 1
    assert length(method.fields) == 2
  end

  test "rejects a product_type outside CMS.Arrangement.product_types/0" do
    assert {:error, changeset} = Methods.create(method_attrs(%{"product_type" => "NOT_A_REAL_PRODUCT"}))
    refute changeset.valid?
    assert %{product_type: ["is invalid"]} = errors_on(changeset)
  end

  test "rejects a field missing a label" do
    bad_fields = [%{"key" => "x", "label" => "", "type" => "text"}]
    assert {:error, changeset} = Methods.create(method_attrs(%{"fields" => bad_fields}))
    refute changeset.valid?
  end

  test "rejects a field with an unknown type" do
    bad_fields = [%{"key" => "x", "label" => "X", "type" => "not_a_real_type"}]
    assert {:error, changeset} = Methods.create(method_attrs(%{"fields" => bad_fields}))
    refute changeset.valid?
  end

  test "update bumps version when fields change" do
    {:ok, method} = Methods.create(method_attrs())
    assert method.version == 1

    new_fields = valid_fields() ++ [%{"key" => "extra", "label" => "Extra", "type" => "text", "required" => false, "options" => []}]
    {:ok, updated} = Methods.update(method, %{"fields" => new_fields})

    assert updated.version == 2
    assert length(updated.fields) == 3
  end

  test "update does NOT bump version when only status changes" do
    {:ok, method} = Methods.create(method_attrs())
    {:ok, updated} = Methods.update(method, %{"status" => "inactive"})

    assert updated.version == 1
    assert updated.status == "inactive"
  end

  test "clone copies fields into a new, independent method in another product" do
    {:ok, source} = Methods.create(method_attrs(%{"product_type" => "DEBIT", "status" => "active"}))

    assert {:ok, cloned} = Methods.clone(source, "PREPAID")

    assert cloned.method_id != source.method_id
    assert cloned.product_type == "PREPAID"
    assert cloned.status == "inactive"
    assert cloned.cloned_from_method_id == source.method_id
    assert cloned.fields == source.fields
    assert cloned.version == 1

    # source is untouched -- always separate, not a live shared reference
    reloaded_source = Repo.get!(Method, source.method_id)
    assert reloaded_source.product_type == "DEBIT"
    assert reloaded_source.status == "active"
  end

  test "list/1 filters by product_type and status" do
    {:ok, _debit_active} = Methods.create(method_attrs(%{"product_type" => "DEBIT", "status" => "active"}))
    {:ok, _debit_inactive} = Methods.create(method_attrs(%{"product_type" => "DEBIT", "status" => "inactive"}))
    {:ok, _wallet_active} = Methods.create(method_attrs(%{"product_type" => "WALLET", "status" => "active"}))

    debit_only = Methods.list(%{"product_type" => "DEBIT"})
    assert Enum.all?(debit_only, &(&1.product_type == "DEBIT"))
    assert length(debit_only) >= 2

    debit_active_only = Methods.list(%{"product_type" => "DEBIT", "status" => "active"})
    assert Enum.all?(debit_active_only, &(&1.status == "active" and &1.product_type == "DEBIT"))
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
