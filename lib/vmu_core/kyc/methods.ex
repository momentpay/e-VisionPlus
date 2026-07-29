defmodule VmuCore.Kyc.Methods do
  @moduledoc """
  Context for `VmuCore.Kyc.Method` — create/update/list/clone, version bump on
  every field-set edit (`docs/kyc/KYC_Implementation_Tracker.md` §7 KYC-P1).
  """

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.Kyc.Method

  @doc "List methods, optionally filtered by product_type and/or status."
  @spec list(map()) :: [Method.t()]
  def list(filters \\ %{}) do
    Method
    |> maybe_filter(:product_type, Map.get(filters, "product_type"))
    |> maybe_filter(:status, Map.get(filters, "status"))
    |> order_by([m], asc: m.product_type, asc: m.name)
    |> Repo.all()
  end

  @spec get(binary()) :: Method.t() | nil
  def get(method_id), do: Repo.get(Method, method_id)

  @spec get!(binary()) :: Method.t()
  def get!(method_id), do: Repo.get!(Method, method_id)

  @doc "Create a new method template."
  @spec create(map()) :: {:ok, Method.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Method{}
    |> Method.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update a method. Bumps `version` whenever `fields` or `conditional_rules`
  actually change — a version bump is a real edit to what's being asked,
  belt-and-suspenders alongside each submission's own frozen field snapshot.
  """
  @spec update(Method.t(), map()) :: {:ok, Method.t()} | {:error, Ecto.Changeset.t()}
  def update(%Method{} = method, attrs) do
    changeset = Method.changeset(method, attrs)

    changeset =
      if Map.has_key?(changeset.changes, :fields) or
           Map.has_key?(changeset.changes, :conditional_rules) do
        Ecto.Changeset.put_change(changeset, :version, method.version + 1)
      else
        changeset
      end

    Repo.update(changeset)
  end

  @doc """
  Clone an existing method's `fields`/`conditional_rules` into a new
  `product_type` — the "copy to seed a new product's KYC" action
  (`docs/kyc/KYC_Implementation_Tracker.md` §2). Always creates a new,
  independent method row (`cloned_from_method_id` records the source for
  traceability); never a live shared reference between products, and the
  new method starts at version 1 with its own edit history from here.
  """
  @spec clone(Method.t(), String.t()) :: {:ok, Method.t()} | {:error, Ecto.Changeset.t()}
  def clone(%Method{} = source, target_product_type) do
    create(%{
      name: source.name <> " (copy)",
      title: source.title,
      product_type: target_product_type,
      status: "inactive",
      fields: source.fields,
      conditional_rules: source.conditional_rules,
      cloned_from_method_id: source.method_id,
      sys_id: source.sys_id,
      bank_id: source.bank_id
    })
  end

  @spec delete(Method.t()) :: {:ok, Method.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Method{} = method), do: Repo.delete(method)

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query
  defp maybe_filter(query, field, value), do: where(query, [m], field(m, ^field) == ^value)
end
