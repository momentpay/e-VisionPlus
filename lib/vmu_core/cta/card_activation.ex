defmodule VmuCore.CTA.CardActivation do
  @moduledoc """
  Card activation workflow — transitions a physical card from issuance to live.

  Two activation methods:
    1. IVR activation — cardholder calls and validates last-4 + DOB
    2. First-use activation — card auto-activates on first successful POS transaction

  Flow:
    CTA tracks the physical plastic (embossing order → dispatched → delivered).
    CMS tracks the account (account_status: INACTIVE → ACTIVE).

  Activation:
    1. Verify activation credentials (IVR: last4 + DOB; first-use: successful auth)
    2. Set account_status = "ACTIVE" in CMS
    3. Refresh AccountStateCoordinator so OTB becomes live
    4. Update cta_embossing_orders.order_status = "DELIVERED"
    5. Post GL entry: card activated (for audit trail)
  """

  require Logger
  import Ecto.Query
  alias VmuCore.{Repo, CMS.Account, CMS.AccountStateCoordinator}

  @doc """
  Activate a card via IVR credential check.

  Credentials: %{last_four: "1234", date_of_birth: ~D[1990-01-15]}
  Returns :ok or {:error, :invalid_credentials | :account_not_found | :already_active}
  """
  def activate_via_ivr(pan_token, credentials) do
    pan_token_hashed = :crypto.hash(:sha256, pan_token) |> Base.encode16(case: :lower)

    with {:ok, account} <- find_account(pan_token_hashed),
         :ok            <- check_not_active(account),
         :ok            <- verify_ivr_credentials(account, credentials) do
      do_activate(account.account_id, :ivr)
    end
  end

  @doc """
  Auto-activate on first successful POS transaction.
  Called by FAS.Authorization after a successful auth on an INACTIVE account.
  """
  def activate_on_first_use(account_id) do
    with {:ok, account} <- {:ok, Repo.get!(Account, account_id)},
         :ok            <- check_not_active(account) do
      do_activate(account_id, :first_use)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp find_account(pan_token_hashed) do
    case Repo.one(from a in Account, where: a.pan_token == ^pan_token_hashed) do
      nil     -> {:error, :account_not_found}
      account -> {:ok, account}
    end
  end

  defp check_not_active(%Account{account_status: "ACTIVE"}), do: {:error, :already_active}
  defp check_not_active(_), do: :ok

  defp verify_ivr_credentials(account, %{last_four: last4, date_of_birth: dob}) do
    customer = Repo.get!(VmuCore.Shared.Customer, account.customer_id)

    if account.last_four == last4 and customer.date_of_birth == dob do
      :ok
    else
      {:error, :invalid_credentials}
    end
  end

  defp do_activate(account_id, method) do
    Repo.update_all(
      from(a in Account, where: a.account_id == ^account_id),
      set: [account_status: "ACTIVE", updated_at: NaiveDateTime.utc_now()]
    )

    # Update embossing order status
    Repo.update_all(
      from(o in "cta_embossing_orders",
        where: o.account_id == ^account_id and o.order_status in ["DISPATCHED", "DELIVERED"]),
      set: [order_status: "DELIVERED", delivered_at: NaiveDateTime.utc_now()]
    )

    AccountStateCoordinator.refresh(account_id)

    Logger.info("[CTA] Card activated: account=#{account_id} method=#{method}")
    :ok
  end
end
