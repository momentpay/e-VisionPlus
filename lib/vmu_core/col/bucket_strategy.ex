defmodule VmuCore.COL.BucketStrategy do
  @moduledoc """
  Shared lookup against `col.bucket_strategy_matrix` (COL-P3, extracted in
  COL-P6 so `CollectionQueueJob`'s queue segmentation and `DunningJob`'s
  treatment steps read the same per-bucket step list instead of duplicating
  the "largest day <= dpd" logic).
  """

  alias VmuCore.Shared.ModuleConfigEngine

  @doc """
  Picks the step with the largest `"day"` <= `dpd` from the account's
  logo-scoped `bucket_strategy_matrix` `"default"` segment. `nil` if `dpd` is
  below every defined step's day.
  """
  @spec step_for_dpd(term(), integer()) :: map() | nil
  def step_for_dpd(account, dpd) do
    {:ok, matrix} =
      ModuleConfigEngine.get("col", "bucket_strategy_matrix", account.sys_id, account.bank_id, account.logo_id)

    matrix
    |> Map.get("default", [])
    |> Enum.filter(&(&1["day"] <= dpd))
    |> Enum.max_by(&(&1["day"]), fn -> nil end)
  end
end
