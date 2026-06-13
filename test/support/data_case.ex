defmodule VmuCore.DataCase do
  @moduledoc """
  ExUnit case template for tests that require a real database connection.
  Each test runs inside a transaction that is rolled back on completion,
  keeping tests isolated without truncating tables between runs.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias VmuCore.Repo
      import Ecto.Query
      import VmuCore.DataCase
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(VmuCore.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(VmuCore.Repo, {:shared, self()})
    end

    :ok
  end

  @doc "Insert a struct or changeset, raising on failure."
  def insert!(schema_or_changeset, attrs \\ %{})

  def insert!(%Ecto.Changeset{} = cs, _attrs) do
    VmuCore.Repo.insert!(cs)
  end

  def insert!(module, attrs) when is_atom(module) do
    struct(module)
    |> module.changeset(attrs)
    |> VmuCore.Repo.insert!()
  end
end
