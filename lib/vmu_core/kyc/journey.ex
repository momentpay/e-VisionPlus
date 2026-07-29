defmodule VmuCore.Kyc.Journey do
  @moduledoc """
  Sequential step-gating for a product's KYC (KYC-P3.5, confirmed with the
  user 2026-07-29 — "sequential gate," not just informational ordering):
  a method at `step` N is locked until every `required` method at a lower
  step for the same product has an **approved** request for that customer.
  Methods sharing a step number unlock together. A method with `required:
  false` doesn't block later steps even if never submitted (mirrors the MMS
  reference's `StepBypassConfig`).

  Read-only / no persistence of its own — derives everything live from
  `Kyc.Methods.ordered_for_product/2` and approved `Kyc.Request` rows.
  """

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.Kyc.{Method, Methods, Request}

  @type status :: :done | :current | :locked

  @doc """
  A product's ordered journey for one customer:
  `[%{method: Method.t(), status: :done | :current | :locked}]`.
  """
  @spec progress(binary(), String.t()) :: [%{method: Method.t(), status: status()}]
  def progress(customer_id, product_type) do
    methods = Methods.ordered_for_product(product_type)
    approved_steps = approved_step_set(customer_id, product_type)

    Enum.map(methods, fn method ->
      status =
        cond do
          method.step in approved_steps -> :done
          unlocked?(method, methods, approved_steps) -> :current
          true -> :locked
        end

      %{method: method, status: status}
    end)
  end

  @doc "Whether `method` can be submitted right now for this customer (not blocked by an earlier required step)."
  @spec submittable?(binary(), Method.t()) :: boolean()
  def submittable?(customer_id, %Method{} = method) do
    methods = Methods.ordered_for_product(method.product_type)
    approved_steps = approved_step_set(customer_id, method.product_type)
    unlocked?(method, methods, approved_steps)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp unlocked?(method, methods, approved_steps) do
    methods
    |> Enum.filter(&(&1.required and &1.step < method.step))
    |> Enum.all?(&(&1.step in approved_steps))
  end

  defp approved_step_set(customer_id, product_type) do
    Repo.all(
      from r in Request,
        where: r.customer_id == ^customer_id and r.product_type == ^product_type and r.status == "approved",
        select: r.step
    )
    |> MapSet.new()
  end
end
