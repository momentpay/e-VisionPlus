defmodule VmuCore.CMS.WalletProductOpening do
  @moduledoc """
  Digital Wallet Phase W1 (2026-07-28) — opens a new `CMS.WalletProduct`
  together with its first `CMS.WalletAccount` (a wallet always starts
  with at least one currency account). Records a `CMS.Arrangement` row
  in the same transaction, same convention every other product's
  opening flow uses this session — `account_ref` is the product's own
  id (not the underlying currency account), matching `HCS.
  CompanyOnboarding`'s own reasoning: it's what an operator actually
  needs to click through to.

  `add_currency_account/1` adds a further single-currency account under
  an existing product — the genuine multi-currency case, exercised
  later once a real need for it shows up; not required for W1's own
  "open/load/close" proof.
  """

  alias VmuCore.{Repo, CMS.WalletProduct, CMS.WalletAccount, CMS.Arrangements}

  @doc """
  attrs = %{customer_id:, name:, sys_id:, bank_id:, logo_id:, block_id:,
            currency: (optional, default "AED")}
  """
  def open(attrs) do
    Repo.transaction(fn ->
      with {:ok, product} <-
             %WalletProduct{}
             |> WalletProduct.changeset(Map.take(attrs, [:customer_id, :name]))
             |> Repo.insert(),
           {:ok, account} <- do_add_currency_account(product, attrs),
           {:ok, _arrangement} <-
             Arrangements.record(%{
               customer_id: product.customer_id, product_type: "WALLET",
               account_ref: product.wallet_product_id, opened_at: account.opened_at
             }) do
        %{product: product, account: account}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  attrs = %{wallet_product_id:, sys_id:, bank_id:, logo_id:, block_id:,
            currency: (optional, default "AED")}
  """
  def add_currency_account(attrs) do
    product = Repo.get!(WalletProduct, attrs.wallet_product_id)
    do_add_currency_account(product, attrs)
  end

  defp do_add_currency_account(product, attrs) do
    %WalletAccount{}
    |> WalletAccount.changeset(%{
      wallet_product_id: product.wallet_product_id,
      customer_id: product.customer_id,
      sys_id: attrs[:sys_id] || attrs["sys_id"],
      bank_id: attrs[:bank_id] || attrs["bank_id"],
      logo_id: attrs[:logo_id] || attrs["logo_id"],
      block_id: attrs[:block_id] || attrs["block_id"],
      currency: attrs[:currency] || attrs["currency"] || "AED",
      opened_at: Date.utc_today()
    })
    |> Repo.insert()
  end
end
