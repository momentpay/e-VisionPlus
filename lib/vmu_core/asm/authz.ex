defmodule VmuCore.ASM.Authz do
  @moduledoc """
  Permission checks (ASM-P2, ADR-A3).

  The single question every admin surface asks:

      Authz.can?(operator, "account", "approve")

  - **ADMIN** short-circuits to `true` for everything — including the
    `operators` module, which no role rows grant (that's what makes it
    ADMIN-only).
  - All other roles resolve against `asm_role_permissions`, cached per role
    in `:persistent_term` (the matrix changes rarely; call `refresh/0`
    after editing it).
  - `permitted_modules/1` drives sidebar filtering; a module is visible
    when the role holds its `view` action.
  - `bank_scope/1` returns the operator's data-scope BANK (nil = all) for
    components to apply to their queries (P2.4).
  """

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.ASM.{Operator, RolePermission}

  @doc "May this operator perform `action` on admin `module`?"
  @spec can?(Operator.t() | nil, String.t(), String.t()) :: boolean()
  def can?(%Operator{role: "ADMIN"}, _module, _action), do: true

  def can?(%Operator{role: role}, module, action) do
    MapSet.member?(permissions_for(role), {module, action})
  end

  def can?(nil, _module, _action), do: false

  @doc "Modules this operator can see in the sidebar (has `view`)."
  @spec permitted_modules(Operator.t()) :: MapSet.t(String.t())
  def permitted_modules(%Operator{role: "ADMIN"}) do
    MapSet.new(RolePermission.modules())
  end

  def permitted_modules(%Operator{role: role}) do
    permissions_for(role)
    |> Enum.filter(fn {_module, action} -> action == "view" end)
    |> Enum.map(fn {module, _} -> module end)
    |> MapSet.new()
  end

  @doc "Operator's BANK data-scope: nil = all banks, else restrict to this bank_id."
  @spec bank_scope(Operator.t()) :: String.t() | nil
  def bank_scope(%Operator{role: "ADMIN"}), do: nil
  def bank_scope(%Operator{bank_scope: scope}), do: scope

  # ---------------------------------------------------------------------------
  # Authority limits (ASM-P3.2)
  # ---------------------------------------------------------------------------

  @default_authority_limits %{
    "SUPERVISOR" => "10000.00",
    "RISK"       => "5000.00",
    "OPS"        => "1000.00"
  }

  @doc """
  Maximum monetary amount this operator may approve. `:unlimited` for ADMIN;
  `Decimal.new(0)` for roles with no configured authority.

      config :vmu_core, :asm_authority_limits,
        %{"SUPERVISOR" => "10000.00", "RISK" => "5000.00", "OPS" => "1000.00"}
  """
  @spec authority_limit(Operator.t()) :: :unlimited | Decimal.t()
  def authority_limit(%Operator{role: "ADMIN"}), do: :unlimited

  def authority_limit(%Operator{role: role}) do
    limits = Application.get_env(:vmu_core, :asm_authority_limits, @default_authority_limits)

    case Map.get(limits, role) do
      nil -> Decimal.new(0)
      amount -> Decimal.new(amount)
    end
  end

  @doc "May this operator approve a financial action of `amount`?"
  @spec within_authority?(Operator.t(), Decimal.t()) :: boolean()
  def within_authority?(operator, amount) do
    case authority_limit(operator) do
      :unlimited -> true
      limit -> Decimal.compare(Decimal.abs(amount), limit) != :gt
    end
  end

  @doc """
  Resolve and validate a checker (second approver) for a 4-eyes action
  (ASM-P3.1): the username must belong to an ACTIVE operator, different from
  the maker, holding `approve` on `module`, and within authority for
  `amount` (pass `nil` amount for non-financial actions).

  Returns `{:ok, checker}` or `{:error, reason}` with reasons:
  `:checker_not_found` · `:checker_is_maker` · `:checker_lacks_permission` ·
  `:checker_exceeds_authority`.
  """
  @spec validate_checker(String.t(), Operator.t(), String.t(), Decimal.t() | nil) ::
          {:ok, Operator.t()} | {:error, atom()}
  def validate_checker(checker_username, %Operator{} = maker, module, amount) do
    checker =
      Repo.one(
        from o in Operator,
          where: o.username == ^String.downcase(String.trim(checker_username || ""))
             and o.status == "ACTIVE"
      )

    cond do
      is_nil(checker) ->
        {:error, :checker_not_found}

      checker.operator_id == maker.operator_id ->
        {:error, :checker_is_maker}

      not can?(checker, module, "approve") ->
        {:error, :checker_lacks_permission}

      not is_nil(amount) and not within_authority?(checker, amount) ->
        {:error, :checker_exceeds_authority}

      true ->
        {:ok, checker}
    end
  end

  @doc "Full permission set for a role — cached in :persistent_term."
  @spec permissions_for(String.t()) :: MapSet.t({String.t(), String.t()})
  def permissions_for(role) do
    case :persistent_term.get({__MODULE__, role}, :miss) do
      :miss ->
        perms = load_role(role)
        :persistent_term.put({__MODULE__, role}, perms)
        perms

      perms ->
        perms
    end
  end

  @doc "Drop the cache after matrix edits — next check reloads from DB."
  @spec refresh() :: :ok
  def refresh do
    Enum.each(Operator.roles(), fn role ->
      :persistent_term.erase({__MODULE__, role})
    end)

    :ok
  end

  @doc "Insert the shipped default matrix (idempotent). Returns row count granted."
  @spec seed_default_matrix() :: non_neg_integer()
  def seed_default_matrix do
    now = DateTime.utc_now()

    rows =
      for {role, module, actions} <- RolePermission.default_matrix(),
          action <- actions do
        %{id: Ecto.UUID.bingenerate(), role: role, module: module,
          action: action, inserted_at: now}
      end

    {count, _} =
      Repo.insert_all("asm_role_permissions", rows,
        on_conflict: :nothing, conflict_target: [:role, :module, :action])

    refresh()
    count
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_role(role) do
    Repo.all(
      from p in RolePermission,
        where: p.role == ^role,
        select: {p.module, p.action}
    )
    |> MapSet.new()
  end
end
