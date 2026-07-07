defmodule VmuCore.CMS.RepaymentDistributor do
  @moduledoc """
  Allocates an incoming payment across balance buckets using the
  VisionPlus configurable payment hierarchy.

  ## Default VisionPlus payment order (CARD SCHEME REQUIRED)

  ```
  Priority 1  — Unpaid fees
  Priority 2  — Accrued interest
  Priority 3  — EMI instalments (by due date)
  Priority 4  — Cash advance principal
  Priority 5  — Balance transfer principal
  Priority 6  — Retail purchase principal
  ```

  This ordering maximises interest income for the issuer and is required
  by most card scheme rules (Visa/Mastercard interchange regulations).

  ## Configurable payment priority (3H)

  When an account has active `PlanSegment` records, each plan's
  `payment_priority` field (1 = highest) overrides the default bucket ordering
  for the principal component. Lower payment_priority numbers are paid first.

  Pass a sorted list of `{bucket_atom, plan_payment_priority, tx_code}` tuples
  to `distribute/3` to use plan-level ordering. Use `distribute/2` for the
  hardcoded default hierarchy.

  ## Balance transfer billing (3C)

  Balance transfer (BT) balances are tracked in the `:bt_balance` bucket field.
  BT plans typically carry a promotional APR (0% or low) during the promo period,
  then revert to the standard purchase APR. BT interest is computed identically to
  retail interest via `InterestEngine.calculate/6` using the effective BT APR from
  `PlanSegment.effective_apr/1`.

  ## All arithmetic is Decimal — never Float.
  """

  import Ecto.Query
  require Logger

  alias VmuCore.{Repo, CMS.PlanSegment, CMS.Account}
  alias VmuCore.Shared.ParameterEngine
  alias Decimal, as: D

  # Default payment order when no plan-level override is in effect.
  # Tuple: {bucket_field_atom, gl_transaction_code, display_label}
  @default_hierarchy [
    {:unpaid_fees,     "FEE_PAYMENT",      "Fee payment"},
    {:accrued_interest,"INTEREST_PAYMENT", "Interest payment"},
    {:emi_balance,     "EMI_PAYMENT",      "EMI instalment"},
    {:cash_balance,    "CASH_PAYMENT",     "Cash advance payment"},
    {:bt_balance,      "BT_PAYMENT",       "Balance transfer payment"},
    {:retail_balance,  "RETAIL_PAYMENT",   "Retail purchase payment"}
  ]

  @doc """
  Distribute `payment_amount` across the balance bucket using the default hierarchy.

  Returns:
      {:ok, %{updated_bucket: map(), gl_postings: [map()], remainder: Decimal.t()}}
  """
  @spec distribute(Decimal.t(), map()) ::
          {:ok, %{updated_bucket: map(), gl_postings: [map()], remainder: Decimal.t()}}
  def distribute(payment_amount, bucket) do
    distribute_by(payment_amount, bucket, @default_hierarchy)
  end

  @doc """
  Distribute `payment_amount` using a plan-aware payment order derived from
  `PlanSegment.payment_priority` for the account's active plans.

  Fetches active plan segments for `account_id` and sorts principal buckets
  by `payment_priority` (ascending = pay first). Fees and interest are always
  paid first regardless of plan priority.

  Returns same shape as `distribute/2`.
  """
  @spec distribute_with_plan_priority(Decimal.t(), map(), binary()) ::
          {:ok, %{updated_bucket: map(), gl_postings: [map()], remainder: Decimal.t()}}
  def distribute_with_plan_priority(payment_amount, bucket, account_id) do
    hierarchy = build_plan_hierarchy(account_id)
    distribute_by(payment_amount, bucket, hierarchy)
  end

  @doc """
  Distribute using the LOGO-configured hierarchy (CMS-G1 ADR-C1).

  Reads the `repayment_hierarchy_order` parameter through the SYS→BANK→LOGO
  cascade for the given account. The parameter is a CSV of bucket names,
  highest priority first, e.g.

      "unpaid_fees,accrued_interest,cash_balance,bt_balance,retail_balance,emi_balance"

  Unknown bucket names are logged and skipped; buckets omitted from the
  configured list are appended at the end in scheme-default order (so a
  partial configuration can never strand a balance unpayable). When the
  parameter is unset or entirely invalid, the scheme-default hierarchy is
  used unchanged.
  """
  @spec distribute_configured(Decimal.t(), map(), Account.t() | binary()) ::
          {:ok, %{updated_bucket: map(), gl_postings: [map()], remainder: Decimal.t()}}
  def distribute_configured(payment_amount, bucket, %Account{} = account) do
    hierarchy = configured_hierarchy(account.sys_id, account.bank_id,
                                     account.logo_id, account.block_id)
    distribute_by(payment_amount, bucket, hierarchy)
  end

  def distribute_configured(payment_amount, bucket, account_id)
      when is_binary(account_id) do
    case Repo.get(Account, account_id) do
      nil     -> distribute(payment_amount, bucket)
      account -> distribute_configured(payment_amount, bucket, account)
    end
  end

  @doc """
  Resolve the effective hierarchy for a product — exposed for statement/ops
  display and for `PaymentIntake`.
  """
  @spec configured_hierarchy(String.t(), String.t(), String.t(), String.t() | nil) ::
          [{atom(), String.t(), String.t()}]
  def configured_hierarchy(sys_id, bank_id, logo_id, block_id) do
    case ParameterEngine.get(sys_id, bank_id, logo_id, block_id || "",
                             :repayment_hierarchy_order) do
      {:ok, csv} when is_binary(csv) and csv != "" -> parse_hierarchy(csv)
      _ -> @default_hierarchy
    end
  end

  # Parse the CSV into hierarchy tuples; unknown names skipped with a log,
  # missing buckets appended in default order.
  defp parse_hierarchy(csv) do
    default_by_field = Map.new(@default_hierarchy, fn {f, c, l} -> {f, {f, c, l}} end)

    configured =
      csv
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.flat_map(fn name ->
        case Map.fetch(default_by_field, safe_bucket_atom(name)) do
          {:ok, tuple} ->
            [tuple]

          :error ->
            Logger.warning("[RepaymentDistributor] Unknown bucket in " <>
                           "repayment_hierarchy_order: #{inspect(name)} — skipped")
            []
        end
      end)
      |> Enum.uniq_by(fn {f, _, _} -> f end)

    case configured do
      [] ->
        @default_hierarchy

      _ ->
        configured_fields = Enum.map(configured, fn {f, _, _} -> f end)
        missing = Enum.reject(@default_hierarchy, fn {f, _, _} -> f in configured_fields end)
        configured ++ missing
    end
  end

  @known_buckets Map.new(
    ~w[unpaid_fees accrued_interest emi_balance cash_balance bt_balance retail_balance],
    fn name -> {name, String.to_atom(name)} end)

  defp safe_bucket_atom(name), do: Map.get(@known_buckets, name, :__unknown__)

  @doc """
  Post-payment hook: restore HCS company pool + individual limit for employee cards.
  Call this after distribute/2 completes successfully for an employee card account.
  No-op for non-HCS accounts.
  """
  def credit_hcs_limits(account_id, payment_amount) do
    VmuCore.HCS.LimitController.credit_limits(account_id, payment_amount)
  end

  @doc """
  Determine if the full statement balance was paid (grace period qualification).
  """
  def full_payment?(%{statement_balance: stmt}, payment_amount) do
    D.compare(payment_amount, stmt) != :lt
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp distribute_by(payment_amount, bucket, hierarchy) do
    {remainder, postings, new_bucket} =
      Enum.reduce(hierarchy, {payment_amount, [], bucket}, fn {field, code, _label}, {rem, posts, bkt} ->
        if D.compare(rem, D.new(0)) == :eq do
          {rem, posts, bkt}
        else
          current   = Map.get(bkt, field, D.new(0)) || D.new(0)
          allocated = D.min(rem, current)

          if D.compare(allocated, D.new(0)) == :eq do
            {rem, posts, bkt}
          else
            new_val = D.sub(current, allocated)
            new_rem = D.sub(rem, allocated)
            posting = %{bucket_field: field, transaction_code: code, amount: allocated}
            {new_rem, [posting | posts], Map.put(bkt, field, new_val)}
          end
        end
      end)

    # disputed_amount is untouched by payments
    {:ok, %{
      updated_bucket: new_bucket,
      gl_postings:    Enum.reverse(postings),
      remainder:      remainder
    }}
  end

  # Build the payment hierarchy using PlanSegment.payment_priority ordering.
  # Fees and interest always come first (priority 0 / fixed).
  # Principal buckets are sorted by the plan's payment_priority.
  #
  # Bug B2 fix (CMS-G1, 2026-07-04): plans are per-LOGO — the query previously
  # loaded ALL active plans across every product, so an account's payment
  # priority could follow another LOGO's plan configuration.
  defp build_plan_hierarchy(account_id) do
    account = Repo.get(Account, account_id)

    plans =
      if account do
        Repo.all(
          from p in PlanSegment,
            where: p.active == true
               and p.sys_id == ^account.sys_id
               and p.bank_id == ^account.bank_id
               and p.logo_id == ^account.logo_id,
            order_by: [asc: p.payment_priority]
        )
      else
        []
      end

    # Map plan_type → bucket_field
    plan_buckets =
      Enum.map(plans, fn plan ->
        {plan_type_to_bucket(plan.plan_type), plan_type_to_code(plan.plan_type), plan.plan_type}
      end)
      |> Enum.uniq_by(fn {field, _, _} -> field end)

    # Fees + interest always first, then plan-ordered principal buckets
    fixed = [
      {:unpaid_fees,      "FEE_PAYMENT",      "Fee payment"},
      {:accrued_interest, "INTEREST_PAYMENT", "Interest payment"},
      {:emi_balance,      "EMI_PAYMENT",      "EMI instalment"}
    ]

    # Any buckets not covered by active plans (e.g. cash if no CASH plan) go last
    all_principal_fields = [:cash_balance, :bt_balance, :retail_balance]
    plan_fields          = Enum.map(plan_buckets, fn {f, _, _} -> f end)
    remainder_buckets    = (all_principal_fields -- plan_fields)
                           |> Enum.map(fn f -> {f, default_code(f), "#{f}"} end)

    fixed ++ plan_buckets ++ remainder_buckets
  end

  defp plan_type_to_bucket("CASH"),             do: :cash_balance
  defp plan_type_to_bucket("BALANCE_TRANSFER"), do: :bt_balance
  defp plan_type_to_bucket("EMI"),              do: :emi_balance
  defp plan_type_to_bucket(_),                  do: :retail_balance

  defp plan_type_to_code("CASH"),             do: "CASH_PAYMENT"
  defp plan_type_to_code("BALANCE_TRANSFER"), do: "BT_PAYMENT"
  defp plan_type_to_code("EMI"),              do: "EMI_PAYMENT"
  defp plan_type_to_code(_),                  do: "RETAIL_PAYMENT"

  defp default_code(:cash_balance),  do: "CASH_PAYMENT"
  defp default_code(:bt_balance),    do: "BT_PAYMENT"
  defp default_code(:retail_balance), do: "RETAIL_PAYMENT"
  defp default_code(other),           do: "#{other}_PAYMENT" |> String.upcase()
end
