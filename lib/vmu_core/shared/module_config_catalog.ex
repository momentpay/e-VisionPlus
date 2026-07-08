defmodule VmuCore.Shared.ModuleConfigCatalog do
  @moduledoc """
  Registry of every module's config specs (Module Configuration Framework, 2026-07-08).

  A spec is what makes a `config_key` real: its type, its allowed values (for
  `:enum`/`:list`), its default (returned by `ModuleConfigEngine.get/5` when no DB row
  exists at any scope), and which scope level it's meant to be set at.

  ## Adding configuration for a new module

  1. Create `lib/vmu_core/<module>/config_catalog.ex` exposing `entries/0` — a list of
     specs shaped like the ones in `VmuCore.CTA.ConfigCatalog`.
  2. Register it in `all/0` below.

  No migration, no new admin UI code — `ModuleConfigComponent` renders any registered
  catalog automatically. See `docs/shared/Module_Configuration_Framework.md`.
  """

  @type spec :: %{
          key: String.t(),
          module: String.t(),
          type: :string | :boolean | :integer | :enum | :map | :list,
          allowed: [String.t()] | nil,
          default: term(),
          scope: :system | :bank | :logo,
          description: String.t()
        }

  @spec all() :: [spec()]
  def all do
    VmuCore.CTA.ConfigCatalog.entries() ++
      VmuCore.ASM.ConfigCatalog.entries() ++
      VmuCore.DPS.ConfigCatalog.entries()
  end

  @spec for_module(String.t()) :: [spec()]
  def for_module(module), do: Enum.filter(all(), &(&1.module == module))

  @spec fetch(String.t(), String.t()) :: spec() | nil
  def fetch(module, key), do: Enum.find(all(), &(&1.module == module and &1.key == key))

  @doc """
  Validates `value` against the module/key's spec type + allowed-values constraint.
  Returns `{:ok, value}` or `{:error, :unknown_key | :invalid_value}`.
  """
  @spec validate(String.t(), String.t(), term()) :: {:ok, term()} | {:error, atom()}
  def validate(module, key, value) do
    case fetch(module, key) do
      nil -> {:error, :unknown_key}
      spec -> if valid_for_type?(spec, value), do: {:ok, value}, else: {:error, :invalid_value}
    end
  end

  defp valid_for_type?(%{type: :string}, v), do: is_binary(v)
  defp valid_for_type?(%{type: :boolean}, v), do: is_boolean(v)
  defp valid_for_type?(%{type: :integer}, v), do: is_integer(v)
  defp valid_for_type?(%{type: :map}, v), do: is_map(v)

  defp valid_for_type?(%{type: :enum, allowed: allowed}, v),
    do: is_binary(v) and v in allowed

  defp valid_for_type?(%{type: :list, allowed: nil}, v), do: is_list(v)

  defp valid_for_type?(%{type: :list, allowed: allowed}, v),
    do: is_list(v) and Enum.all?(v, &(&1 in allowed))

  defp valid_for_type?(_spec, _v), do: false
end
