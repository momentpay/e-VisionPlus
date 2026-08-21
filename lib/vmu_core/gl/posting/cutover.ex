defmodule VmuCore.Posting.Cutover do
  @moduledoc """
  Decides, per product, whether the new posting engine is authoritative
  (GL Phase C1).

  ## The whole change, in one line

  | | Shadow (Phase B) | Cutover (Phase C1) |
  |---|---|---|
  | Engine write fails | logged, swallowed, legacy posting stands | **legacy posting fails and rolls back** |

  The mapping is identical and already proven — 500 postings, 500 exact
  matches. What changes is who is allowed to say no.

  ## Why per product, not per call site

  Products are the real blast-radius boundary: a defect in prepaid posting
  cannot reach credit. And `InternalGlPoster` already resolves the product for
  shadow mode, so cutting a product over needs **no caller changes at all** —
  the twenty-odd call sites are untouched.

  ## Why the legacy table keeps being written

  `cms_ledger_entries` is read by at least twelve modules, including
  `CMS.AccountStateCoordinator` on the authorization path,
  `CMS.CoreBankingAdapter`'s GL extract, and the EOD jobs. Cutover flips *who
  is authoritative*, not *what is written*. Retiring the legacy table is a
  later step, after those readers move.

  ## Configuration

      config :vmu_core, VmuCore.Posting.Cutover,
        products: ["WALLET", "PREPAID"]

  Empty by default, so this module is inert until someone opts a product in.
  Reverting a cutover is deleting a string from that list.
  """

  @known_products ~w[CREDIT CREDIT_CARD DEBIT PREPAID WALLET]

  @doc "Products for which the engine is authoritative."
  @spec products() :: [String.t()]
  def products do
    :vmu_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:products, [])
  end

  @doc """
  True when a failed engine write should abort the legacy posting.

  False means shadow behaviour: mirror it, swallow any failure.
  """
  @spec authoritative?(String.t() | nil) :: boolean()
  def authoritative?(nil), do: false
  def authoritative?(product) when is_binary(product), do: product in products()

  @doc """
  Products configured but not recognised — a typo here would silently leave a
  product on the legacy path while looking cut over in config.
  """
  @spec unknown_products() :: [String.t()]
  def unknown_products, do: Enum.reject(products(), &(&1 in @known_products))

  @doc "Products still on the legacy path."
  @spec pending() :: [String.t()]
  def pending, do: @known_products -- products()

  def known_products, do: @known_products
end
