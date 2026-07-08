defmodule VmuCore.Shared.ModuleConfigWriter do
  @moduledoc """
  Authoritative write path for the Module Configuration Framework (2026-07-08).
  Mirrors `VmuCore.Shared.ParameterWriter`'s guarantee: every successful write
  refreshes `ModuleConfigEngine`'s ETS cache in the same call, and is audited via the
  existing `VmuCore.ASM.AuditLog` sink — no new audit table needed.

  ## Usage

      alias VmuCore.Shared.ModuleConfigWriter

      ModuleConfigWriter.put(
        "cta", "renewal_lead_time_days", 45,
        %{scope_type: "logo", sys_id: "0001", bank_id: "0010", logo_id: "0100"},
        current_operator
      )
  """

  require Logger

  alias VmuCore.Repo
  alias VmuCore.ASM.AuditLog
  alias VmuCore.Shared.{ModuleConfigEntry, ModuleConfigEngine, ModuleConfigCatalog}

  @type scope :: %{
          required(:scope_type) => String.t(),
          required(:sys_id) => String.t(),
          optional(:bank_id) => String.t(),
          optional(:logo_id) => String.t()
        }

  @doc """
  Validates `value` against the module/key's catalog spec, upserts the row, refreshes
  the ETS cache, and writes an audit entry. Returns `{:ok, ModuleConfigEntry.t()}` or
  `{:error, :unknown_key | :invalid_value | Ecto.Changeset.t()}`.
  """
  @spec put(String.t(), String.t(), term(), scope(), VmuCore.ASM.Operator.t() | nil) ::
          {:ok, ModuleConfigEntry.t()} | {:error, term()}
  def put(module, key, value, scope, operator) do
    with {:ok, ^value} <- ModuleConfigCatalog.validate(module, key, value) do
      old_value = current_value(module, key, scope)

      attrs = %{
        scope_type: scope.scope_type,
        sys_id: scope.sys_id,
        bank_id: Map.get(scope, :bank_id, ""),
        logo_id: Map.get(scope, :logo_id, ""),
        module: module,
        config_key: key,
        value: %{"v" => value},
        updated_by: operator_name(operator)
      }

      %ModuleConfigEntry{}
      |> ModuleConfigEntry.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:value, :updated_by, :updated_at]},
        conflict_target: [:scope_type, :sys_id, :bank_id, :logo_id, :module, :config_key]
      )
      |> case do
        {:ok, entry} ->
          :ok = ModuleConfigEngine.refresh_all()

          AuditLog.record(operator, "config_update", "#{module}.#{key}", %{
            scope: attrs |> Map.take([:scope_type, :sys_id, :bank_id, :logo_id]),
            old_value: old_value,
            new_value: value
          })

          {:ok, entry}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp current_value(module, key, scope) do
    case ModuleConfigEngine.get(module, key, scope.sys_id, Map.get(scope, :bank_id, ""), Map.get(scope, :logo_id, "")) do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  defp operator_name(nil), do: "system"
  defp operator_name(%{username: username}), do: username
end
