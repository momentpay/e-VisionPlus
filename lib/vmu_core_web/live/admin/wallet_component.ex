defmodule VmuCoreWeb.Live.Admin.WalletComponent do
  @moduledoc """
  Admin LiveComponent: Digital Wallet account list/detail (Way4 parity
  plan Phase 2, Digital Wallet Phase W4, 2026-07-28) — the first admin
  UI for `CMS.WalletAccount`/`CMS.WalletProduct`, built on top of
  Phases W1-W3's backend (open/load/withdraw/close, wallet-to-wallet
  transfer, personal QR).

  - Account list with search, and a "+ New Wallet" wizard (Customer
    search+select existing / Product name+Logo+Block+currency / Review),
    same 3-step shape Debit/Prepaid's own wizards use.
  - Account detail: Overview (balance + Load action), Transfers (send
    money to another wallet + transfer history), QR (generate a
    receive code, pay a scanned/pasted one), History (combined
    block/non-monetary-event audit trail) — plus an account-level
    toolbar mirroring Debit/Prepaid's Phase 1e/2d parity items: Block/
    Unblock, Address/Phone/Email change, Change (velocity) Limits, KYC
    Verify/Reject/Reset. Deliberately NOT included: Channel Controls,
    Supplementary Card — Wallet has no `CTA.Card` in this scope at all
    (account-first, not card-first, per `docs/wallet/
    DIGITAL_WALLET_Module_Requirements.md`), so there is no card to
    apply either item to. An honest gap, not an invented one.

  Visibility requires `wallet:view`; create/load/transfer/QR/toolbar
  actions require `wallet:edit`.
  """

  use Phoenix.LiveComponent
  import Ecto.Query
  import VmuCoreWeb.AdminUI
  import VmuCoreWeb.Components.AgGrid

  alias VmuCore.{Repo, CMS.WalletAccount, CMS.WalletProduct, CMS.WalletProductOpening,
                 CMS.WalletFundingCommand, CMS.WalletTransferCommand, CMS.WalletTransfer,
                 CMS.WalletQrIdentity, CMS.WalletQrPaymentCommand,
                 CMS.WalletBlockHistory, CMS.WalletNonMonetaryEvent}
  alias VmuCore.Shared.{Customer, LogoParameter, BlockParameter}
  alias VmuCore.ASM.Authz
  alias Decimal, as: D

  @default_operator_id "00000000-0000-0000-0000-000000000001"

  @block_codes [
    {"L — Lost Card",        "L"},
    {"S — Stolen Card",      "S"},
    {"F — Fraud Suspicion",  "F"},
    {"C — Collections Hold", "C"}
  ]

  @block_reason_codes [
    {"Cardholder reported card lost",          "REPORTED_LOST"},
    {"Cardholder reported card stolen",        "REPORTED_STOLEN"},
    {"Fraud team flagged suspicious activity", "FRAUD_ALERT"},
    {"Account moved to collections queue",     "COLLECTIONS_HOLD"},
    {"Cardholder requested temporary block",   "CUSTOMER_REQUEST"},
    {"Applied by automated EOD batch",         "EOD_AUTOMATED"}
  ]

  @unblock_reason_codes [
    {"Investigation completed, block lifted", "INVESTIGATION_CLOSED"},
    {"Manual override by supervisor",         "SUPERVISOR_OVERRIDE"},
    {"Cardholder requested unblock",          "CUSTOMER_REQUEST"}
  ]

  @operator_roles [{"Agent", "AGENT"}, {"Supervisor", "SUPERVISOR"}, {"System", "SYSTEM"}]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       mode: :list,
       search: "",
       accounts: [],
       notice: nil,
       notice_kind: :info,
       active_action: :none,
       account: nil,
       product: nil,
       customer: nil,
       transfers: [],
       block_history: [],
       nonmon_events: [],
       generated_qr: nil,
       can_edit: false,
       loaded_deep_link_id: nil,
       embedded: false,
       wizard_step: 1,
       form_data: %{},
       customer_search: "",
       customer_results: [],
       logos_for_bank: [],
       blocks_for_logo: [],
       xfer_search: "",
       xfer_results: [],
       xfer_selected: nil,
       detail_tab: 1,
       block_codes: @block_codes,
       block_reason_codes: @block_reason_codes,
       unblock_reason_codes: @unblock_reason_codes,
       operator_roles: @operator_roles
     )
     |> load_accounts()}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    operator = socket.assigns[:current_operator]
    socket = assign(socket, can_edit: operator && Authz.can?(operator, "wallet", "edit"))

    socket =
      case assigns[:deep_link_id] do
        id when is_binary(id) and id != "" and id != socket.assigns.loaded_deep_link_id ->
          socket |> assign(detail_tab: 1) |> load_detail_by_product(id) |> assign(loaded_deep_link_id: id)

        _ ->
          socket
      end

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # List events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(search: q) |> load_accounts()}
  end

  def handle_event("view_account", %{"id" => id}, socket) do
    {:noreply, socket |> assign(detail_tab: 1) |> load_detail(id)}
  end

  def handle_event("detail_tab", %{"t" => t}, socket) do
    {:noreply, assign(socket, detail_tab: String.to_integer(t), active_action: :none, generated_qr: nil)}
  end

  def handle_event("back_to_list", _, socket) do
    {:noreply, socket |> assign(mode: :list, active_action: :none, notice: nil) |> load_accounts()}
  end

  def handle_event("open_action", %{"a" => action}, socket) do
    {:noreply, assign(socket, active_action: String.to_atom(action), notice: nil)}
  end

  def handle_event("action_close", _, socket) do
    {:noreply, assign(socket, active_action: :none)}
  end

  # ---------------------------------------------------------------------------
  # Create wallet — wizard (Digital Wallet Phase W4, 2026-07-28)
  # ---------------------------------------------------------------------------

  def handle_event("wallet_new", _params, socket) do
    {:noreply, assign(socket,
      mode: :wizard, wizard_step: 1, form_data: %{},
      customer_search: "", customer_results: [],
      logos_for_bank: [], blocks_for_logo: [], notice: nil
    )}
  end

  def handle_event("cust_search_wizard", %{"value" => q}, socket) do
    results =
      if String.length(q || "") >= 2 do
        term = "%#{q}%"
        Repo.all(
          from c in Customer,
            where: ilike(c.first_name, ^term) or ilike(c.last_name, ^term) or
                   ilike(fragment("? || ' ' || ?", c.first_name, c.last_name), ^term) or
                   ilike(c.email, ^term) or ilike(c.mobile_number, ^term),
            limit: 10
        )
      else
        []
      end
    {:noreply, assign(socket, customer_search: q, customer_results: results)}
  end

  def handle_event("select_customer", %{"id" => cust_id}, socket) do
    case Repo.get(Customer, cust_id) do
      nil -> {:noreply, socket}
      cust ->
        fd = Map.merge(socket.assigns.form_data, %{
          "customer_id" => to_string(cust.customer_id),
          "customer_name" => "#{cust.first_name} #{cust.last_name}",
          "wallet_name" => "#{cust.first_name} #{cust.last_name}'s Wallet",
          "bank_id" => cust.bank_id,
          "sys_id" => cust.sys_id
        })
        logos = Repo.all(from l in LogoParameter, where: l.bank_id == ^cust.bank_id, order_by: [asc: l.logo_id])
        {:noreply, assign(socket,
          form_data: fd, customer_search: "", customer_results: [],
          logos_for_bank: logos, wizard_step: 2
        )}
    end
  end

  def handle_event("wizard_step", %{"s" => s}, socket) do
    {:noreply, assign(socket, wizard_step: String.to_integer(s))}
  end

  def handle_event("wizard_change", %{"acc" => params}, socket) do
    fd = Map.merge(socket.assigns.form_data, params)

    socket =
      if params["logo_id"] && params["logo_id"] != socket.assigns.form_data["logo_id"] do
        logo_id = params["logo_id"]
        bank_id = fd["bank_id"] || ""
        blocks =
          Repo.all(
            from b in BlockParameter,
              where: b.logo_id == ^logo_id and b.bank_id == ^bank_id,
              order_by: [asc: b.block_id]
          )
        assign(socket, form_data: fd, blocks_for_logo: blocks)
      else
        assign(socket, form_data: fd)
      end

    {:noreply, socket}
  end

  def handle_event("wizard_save", _params, socket) do
    if socket.assigns.can_edit do
      fd = socket.assigns.form_data

      case WalletProductOpening.open(%{
             customer_id: fd["customer_id"], name: fd["wallet_name"] || "Wallet",
             sys_id: fd["sys_id"], bank_id: fd["bank_id"],
             logo_id: fd["logo_id"], block_id: fd["block_id"] || "DFLT",
             currency: fd["currency"] || "AED"
           }) do
        {:ok, %{account: account}} ->
          {:noreply, socket
                      |> assign(mode: :list, detail_tab: 1, notice: "Wallet opened for #{fd["customer_name"]}.", notice_kind: :success)
                      |> load_accounts()
                      |> then(&load_detail(&1, account.wallet_account_id))}

        {:error, changeset} ->
          {:noreply, assign(socket, notice: "Create failed — #{inspect(changeset.errors)}", notice_kind: :error)}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot create wallets.", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Load account
  # ---------------------------------------------------------------------------

  def handle_event("load_account_save", %{"load" => params}, socket) do
    if socket.assigns.can_edit do
      amount = parse_decimal(params["amount"])
      channel = params["channel"]

      cond do
        is_nil(amount) or D.compare(amount, D.new(0)) != :gt ->
          {:noreply, assign(socket, notice: "Amount must be a positive number.", notice_kind: :error)}

        channel in ["EXTERNAL_BANK_TRANSFER", "CASH_DEPOSIT"] and blank?(params["external_reference"]) ->
          {:noreply, assign(socket, notice: "A reference is required for this channel.", notice_kind: :error)}

        true ->
          operator = socket.assigns.current_operator

          case WalletFundingCommand.fund(%{
                 wallet_account_id: socket.assigns.account.wallet_account_id, amount: amount,
                 channel: channel, posted_by: operator.username,
                 external_reference: blank_to_nil(params["external_reference"])
               }) do
            {:ok, _result} ->
              {:noreply, socket
                          |> load_detail(socket.assigns.account.wallet_account_id)
                          |> assign(active_action: :none, notice: "Wallet loaded: #{money(amount)}.", notice_kind: :success)}

            {:error, reason} ->
              {:noreply, assign(socket, notice: "Load failed — #{inspect(reason)}", notice_kind: :error)}
          end
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot load wallets.", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Transfers (Digital Wallet Phase W4, 2026-07-28)
  # ---------------------------------------------------------------------------

  def handle_event("xfer_search", %{"value" => q}, socket) do
    account = socket.assigns.account
    results =
      if String.length(q || "") >= 2 do
        term = "%#{q}%"
        Repo.all(
          from a in WalletAccount,
            join: c in Customer, on: c.customer_id == a.customer_id,
            where: a.wallet_account_id != ^account.wallet_account_id and
                   (ilike(c.first_name, ^term) or ilike(c.last_name, ^term) or
                    ilike(fragment("? || ' ' || ?", c.first_name, c.last_name), ^term)),
            limit: 8,
            select: %{wallet_account_id: a.wallet_account_id, currency: a.currency,
                      first_name: c.first_name, last_name: c.last_name}
        )
      else
        []
      end
    {:noreply, assign(socket, xfer_search: q, xfer_results: results)}
  end

  def handle_event("xfer_select", %{"id" => id}, socket) do
    receiver = Enum.find(socket.assigns.xfer_results, &(&1.wallet_account_id == id))
    {:noreply, assign(socket, xfer_selected: receiver, xfer_search: "", xfer_results: [])}
  end

  def handle_event("xfer_clear", _, socket) do
    {:noreply, assign(socket, xfer_selected: nil)}
  end

  def handle_event("transfer_save", %{"transfer" => params}, socket) do
    amount = parse_decimal(params["amount"])
    operator = socket.assigns.current_operator
    receiver = socket.assigns.xfer_selected

    cond do
      is_nil(receiver) ->
        {:noreply, assign(socket, notice: "Select a recipient wallet first.", notice_kind: :error)}

      is_nil(amount) or D.compare(amount, D.new(0)) != :gt ->
        {:noreply, assign(socket, notice: "Amount must be a positive number.", notice_kind: :error)}

      true ->
        case WalletTransferCommand.transfer(%{
               from_wallet_account_id: socket.assigns.account.wallet_account_id,
               to_wallet_account_id: receiver.wallet_account_id,
               amount: amount, initiated_by: operator.username, reason: blank_to_nil(params["reason"])
             }) do
          {:ok, _transfer} ->
            {:noreply, socket
                        |> load_detail(socket.assigns.account.wallet_account_id)
                        |> assign(active_action: :none, xfer_selected: nil, notice: "Transfer sent: #{money(amount)}.", notice_kind: :success)}

          {:error, reason} ->
            {:noreply, assign(socket, notice: "Transfer failed — #{transfer_error_msg(reason)}", notice_kind: :error)}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # QR — receive + pay (Digital Wallet Phase W4, 2026-07-28)
  # ---------------------------------------------------------------------------

  def handle_event("generate_qr_save", %{"qr" => params}, socket) do
    account = socket.assigns.account
    amount = parse_decimal(params["amount"])

    qr = WalletQrIdentity.generate(account.wallet_account_id, account.currency, amount, params["label"] || "")
    {:noreply, assign(socket, generated_qr: qr, notice: nil)}
  end

  def handle_event("pay_qr_save", %{"pay" => params}, socket) do
    operator = socket.assigns.current_operator
    amount = parse_decimal(params["amount"])

    case WalletQrPaymentCommand.pay(%{
           qr_string: String.trim(params["qr_string"] || ""),
           from_wallet_account_id: socket.assigns.account.wallet_account_id,
           initiated_by: operator.username, amount: amount
         }) do
      {:ok, transfer} ->
        {:noreply, socket
                    |> load_detail(socket.assigns.account.wallet_account_id)
                    |> assign(active_action: :none, notice: "Paid #{money(transfer.amount)} via QR.", notice_kind: :success)}

      {:error, reason} ->
        {:noreply, assign(socket, notice: "QR payment failed — #{qr_error_msg(reason)}", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Account-level Block / Non-Monetary Events / Limits / KYC
  # (Digital Wallet Phase W4, 2026-07-28) — same shape as Debit/Prepaid's
  # Phase 1e/2d toolbar.
  # ---------------------------------------------------------------------------

  def handle_event("wallet_block_save", %{"action" => params}, socket) do
    account = socket.assigns.account
    op_id = normalize_uuid(params["operator_id"])

    case WalletBlockHistory.record_block(
      account.wallet_account_id, params["block_code"], params["reason_code"],
      params["reason_text"] || "", op_id, params["operator_role"] || "AGENT"
    ) do
      {:ok, _hist} ->
        {:noreply, socket
                    |> load_detail(account.wallet_account_id)
                    |> assign(active_action: :none, notice: "Block code #{params["block_code"]} applied.", notice_kind: :success)}

      {:error, cs} ->
        {:noreply, assign(socket, notice: "Block failed — #{cs_error_msg(cs)}", notice_kind: :error)}
    end
  end

  def handle_event("wallet_unblock_save", %{"action" => params}, socket) do
    account = socket.assigns.account
    op_id = normalize_uuid(params["operator_id"])

    case WalletBlockHistory.record_unblock(
      account.wallet_account_id, account.block_code || "L", params["reason_code"],
      params["reason_text"] || "", op_id, params["operator_role"] || "AGENT"
    ) do
      {:ok, _hist} ->
        {:noreply, socket
                    |> load_detail(account.wallet_account_id)
                    |> assign(active_action: :none, notice: "Block removed.", notice_kind: :success)}

      {:error, cs} ->
        {:noreply, assign(socket, notice: "Unblock failed — #{cs_error_msg(cs)}", notice_kind: :error)}
    end
  end

  def handle_event("wallet_nonmon_save", %{"action" => params}, socket) do
    account = socket.assigns.account
    etype = params["event_type"]
    op_id = normalize_uuid(params["operator_id"])
    {old_val, new_val} = build_nonmon_values(etype, params, socket.assigns)

    case WalletNonMonetaryEvent.record(
      wallet_account_id: account.wallet_account_id, event_type: etype,
      old_value: old_val, new_value: new_val,
      reason: params["reason"] || "", reference_id: params["reference_id"],
      operator_id: op_id, operator_role: params["operator_role"] || "AGENT"
    ) do
      {:ok, _event} ->
        apply_nonmon_change(etype, params, socket.assigns)
        {:noreply, socket
                    |> load_detail(account.wallet_account_id)
                    |> assign(active_action: :none, notice: "#{etype_label(etype)} recorded.", notice_kind: :success)}

      {:error, cs} ->
        {:noreply, assign(socket, notice: "Event failed — #{cs_error_msg(cs)}", notice_kind: :error)}
    end
  end

  def handle_event("wallet_limits_save", %{"action" => params}, socket) do
    account = socket.assigns.account
    op_id = normalize_uuid(params["operator_id"])

    new_limits = %{
      "DAILY" => %{"count" => parse_int(params["daily_count"]), "amount" => parse_int(params["daily_amount"])},
      "MONTHLY" => %{"amount" => parse_int(params["monthly_amount"])}
    }

    case account |> WalletAccount.changeset(%{velocity_limits: new_limits}) |> Repo.update() do
      {:ok, _updated} ->
        WalletNonMonetaryEvent.record(
          wallet_account_id: account.wallet_account_id, event_type: "limit_change",
          old_value: account.velocity_limits || %{}, new_value: new_limits,
          reason: "Velocity limits updated", operator_id: op_id, operator_role: "AGENT"
        )

        {:noreply, socket
                    |> load_detail(account.wallet_account_id)
                    |> assign(active_action: :none, notice: "Velocity limits updated.", notice_kind: :success)}

      {:error, cs} ->
        {:noreply, assign(socket, notice: "Update failed — #{cs_error_msg(cs)}", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-currency (Digital Wallet Phase W7, 2026-07-30) — WalletProductOpening.
  # add_currency_account/1 already existed since Phase W1 but had no real
  # caller anywhere; this is its first one.
  # ---------------------------------------------------------------------------

  def handle_event("switch_currency", %{"id" => wallet_account_id}, socket) do
    {:noreply, load_detail(socket, wallet_account_id)}
  end

  def handle_event("add_currency_save", %{"action" => params}, socket) do
    if socket.assigns.can_edit do
      account = socket.assigns.account
      currency = params["currency"] |> to_string() |> String.trim() |> String.upcase()

      case WalletProductOpening.add_currency_account(%{
             wallet_product_id: account.wallet_product_id,
             sys_id: account.sys_id, bank_id: account.bank_id,
             logo_id: account.logo_id, block_id: account.block_id,
             currency: currency
           }) do
        {:ok, new_account} ->
          {:noreply, socket
                      |> load_detail(new_account.wallet_account_id)
                      |> assign(notice: "#{currency} account added to this wallet.", notice_kind: :success)}

        {:error, cs} ->
          {:noreply, assign(socket, notice: "Add currency failed — #{cs_error_msg(cs)}", notice_kind: :error)}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot modify wallets.", notice_kind: :error)}
    end
  end

  def handle_event("wallet_kyc", %{"status" => status}, socket) do
    account = socket.assigns.account

    attrs =
      if status == "VERIFIED",
        do: %{kyc_status: status, kyc_verified_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)},
        else: %{kyc_status: status, kyc_verified_at: nil}

    case account |> WalletAccount.changeset(attrs) |> Repo.update() do
      {:ok, _updated} ->
        {:noreply, socket
                    |> load_detail(account.wallet_account_id)
                    |> assign(notice: "KYC status set to #{status}.", notice_kind: :success)}

      {:error, cs} ->
        {:noreply, assign(socket, notice: "KYC update failed — #{cs_error_msg(cs)}", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — data loading
  # ---------------------------------------------------------------------------

  defp load_accounts(socket) do
    search = String.trim(socket.assigns[:search] || "")

    query =
      if search == "" do
        from(w in WalletAccount, order_by: [desc: w.inserted_at])
      else
        from(w in WalletAccount, join: c in Customer, on: c.customer_id == w.customer_id,
          where: ilike(c.first_name, ^"%#{search}%") or ilike(c.last_name, ^"%#{search}%") or
                 ilike(fragment("? || ' ' || ?", c.first_name, c.last_name), ^"%#{search}%"),
          order_by: [desc: w.inserted_at])
      end

    accounts =
      Repo.all(query)
      |> Enum.map(fn account ->
        customer = Repo.get(Customer, account.customer_id)
        Map.put(account, :customer_name, customer && "#{customer.first_name} #{customer.last_name}")
      end)

    assign(socket, accounts: accounts, mode: :list)
  end

  defp load_detail(socket, wallet_account_id) do
    account = Repo.get!(WalletAccount, wallet_account_id)
    customer = Repo.get(Customer, account.customer_id)
    product = Repo.get(WalletProduct, account.wallet_product_id)
    account = Map.put(account, :customer_name, customer && "#{customer.first_name} #{customer.last_name}")

    sibling_accounts =
      Repo.all(
        from a in WalletAccount,
          where: a.wallet_product_id == ^account.wallet_product_id,
          order_by: [asc: a.currency]
      )

    assign(socket,
      mode: :detail,
      account: account,
      customer: customer,
      product: product,
      sibling_accounts: sibling_accounts,
      active_action: :none,
      notice: nil,
      generated_qr: nil,
      transfers:
        Repo.all(
          from t in WalletTransfer,
            where: t.from_wallet_account_id == ^wallet_account_id or t.to_wallet_account_id == ^wallet_account_id,
            order_by: [desc: t.inserted_at]
        ),
      block_history: WalletBlockHistory.history_for(wallet_account_id),
      nonmon_events: WalletNonMonetaryEvent.history_for(wallet_account_id)
    )
  end

  # Deep-link resolution — a "View in Digital Wallet" link lands here
  # with ?view=<wallet_product_id> (a product, not an individual
  # currency account, same "point at what the customer-facing concept
  # actually is" reasoning `HCS.CompanyOnboarding`/`WalletProductOpening`
  # already established for their own Arrangement account_ref). Opens
  # the product's earliest (primary) account.
  defp load_detail_by_product(socket, wallet_product_id) do
    case Repo.one(
           from a in WalletAccount, where: a.wallet_product_id == ^wallet_product_id,
             order_by: [asc: a.inserted_at], limit: 1
         ) do
      nil -> socket
      account -> load_detail(socket, account.wallet_account_id)
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil
  defp parse_decimal(str) do
    case D.parse(str) do
      {d, ""} -> d
      _ -> nil
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(s), do: String.to_integer(s)

  defp normalize_uuid(""), do: @default_operator_id
  defp normalize_uuid(nil), do: @default_operator_id
  defp normalize_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> @default_operator_id
    end
  end

  defp cs_error_msg(cs) do
    Enum.map_join(cs.errors, "; ", fn {f, {m, _}} -> "#{f}: #{m}" end)
  end

  defp etype_label("address_change"), do: "Address change"
  defp etype_label("phone_change"), do: "Phone change"
  defp etype_label("email_change"), do: "Email change"
  defp etype_label(t), do: t

  defp transfer_error_msg(:currency_mismatch), do: "sender and recipient wallets use different currencies"
  defp transfer_error_msg(:cannot_transfer_to_self), do: "cannot transfer to the same wallet"
  defp transfer_error_msg(:sender_not_active), do: "your wallet is not active"
  defp transfer_error_msg(:receiver_not_active), do: "recipient wallet is not active"
  defp transfer_error_msg(:insufficient_funds), do: "insufficient funds"
  defp transfer_error_msg(:sender_not_found), do: "sender wallet not found"
  defp transfer_error_msg(:receiver_not_found), do: "recipient wallet not found"
  defp transfer_error_msg(other), do: inspect(other)

  defp qr_error_msg(:invalid_format), do: "not a valid wallet QR code"
  defp qr_error_msg(:unsupported_version), do: "unsupported QR version"
  defp qr_error_msg(:checksum_mismatch), do: "QR code appears corrupted or tampered with"
  defp qr_error_msg(:invalid_qr_account_id), do: "QR code encodes an invalid account reference"
  defp qr_error_msg(:amount_required), do: "this QR has no fixed amount — enter one"
  defp qr_error_msg(:amount_mismatch), do: "entered amount does not match this QR's fixed amount"
  defp qr_error_msg(other), do: transfer_error_msg(other)

  # ── Non-monetary helpers — same shape as Debit/Prepaid's own copies,
  # targeting the wallet's linked Shared.Customer.
  defp build_nonmon_values("address_change", params, assigns) do
    c = assigns.customer
    old = %{"line1" => c && c.address_line1, "city" => c && c.city, "country" => c && c.country}
    new = %{"line1" => params["new_line1"], "line2" => params["new_line2"],
            "city" => params["new_city"], "postal" => params["new_postal"],
            "country" => params["new_country"]}
    {old, new}
  end
  defp build_nonmon_values("phone_change", params, assigns) do
    c = assigns.customer
    old = %{"mobile_country" => c && c.mobile_country, "mobile_number" => c && c.mobile_number}
    new = %{"mobile_country" => params["new_mobile_country"], "mobile_number" => params["new_mobile_number"]}
    {old, new}
  end
  defp build_nonmon_values("email_change", params, assigns) do
    c = assigns.customer
    {%{"email" => c && c.email}, %{"email" => params["new_email"]}}
  end
  defp build_nonmon_values(_, _, _), do: {nil, nil}

  defp apply_nonmon_change("address_change", params, %{customer: c}) when not is_nil(c) do
    c |> Customer.changeset(%{
      address_line1: params["new_line1"], address_line2: params["new_line2"],
      city: params["new_city"], postal_code: params["new_postal"], country: params["new_country"]
    }) |> Repo.update()
  end
  defp apply_nonmon_change("phone_change", params, %{customer: c}) when not is_nil(c) do
    c |> Customer.changeset(%{
      mobile_country: params["new_mobile_country"], mobile_number: params["new_mobile_number"]
    }) |> Repo.update()
  end
  defp apply_nonmon_change("email_change", params, %{customer: c}) when not is_nil(c) do
    c |> Customer.changeset(%{email: params["new_email"]}) |> Repo.update()
  end
  defp apply_nonmon_change(_, _, _), do: :ok

  defp money(nil), do: "—"
  defp money(%D{} = d), do: d |> D.round(2) |> D.to_string()
  defp money(v), do: to_string(v)

  defp status_cls("ACTIVE"),    do: "badge-green"
  defp status_cls("SUSPENDED"), do: "badge-yellow"
  defp status_cls("CLOSED"),    do: "badge-gray"
  defp status_cls("DORMANT"),   do: "badge-gray"
  defp status_cls("COMPLETED"), do: "badge-green"
  defp status_cls(_),           do: "badge-gray"

  defp kyc_badge_cls("VERIFIED"), do: "badge-green"
  defp kyc_badge_cls("REJECTED"), do: "badge-red"
  defp kyc_badge_cls(_),          do: "badge-yellow"

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(%{mode: :list} = assigns) do
    ~H"""
    <div id={@id} class="component-panel">
      <%= if not @embedded do %>
        <.page_header title="Digital Wallet" subtitle="Stored-value wallet accounts">
          <:actions>
            <button :if={@can_edit} class="btn-sm btn-primary" phx-click="wallet_new" phx-target={@myself}>+ New Wallet</button>
          </:actions>
        </.page_header>
      <% end %>

      <%= if @notice do %><.alert kind={@notice_kind} message={@notice} /><% end %>

      <form phx-change="search" phx-target={@myself} style="margin-bottom:12px;">
        <input class="input" type="text" name="q" value={@search} placeholder="Search customer name…" style="max-width:320px;"/>
      </form>

      <div class="table-wrap">
        <table class="data-table">
          <thead>
            <tr><th>Customer</th><th>Balance</th><th>Currency</th><th>Status</th><th></th></tr>
          </thead>
          <tbody>
            <%= if @accounts == [] do %>
              <tr><td colspan="5" class="empty-row" style="text-align:center;">No wallets found.</td></tr>
            <% end %>
            <%= for a <- @accounts do %>
              <tr>
                <td><%= a.customer_name || "—" %></td>
                <td class="mono"><%= money(a.available_balance) %></td>
                <td><%= a.currency %></td>
                <td><span class={"badge #{status_cls(a.status)}"}><%= a.status %></span></td>
                <td><button class="btn btn-xs" phx-click="view_account" phx-value-id={a.wallet_account_id} phx-target={@myself}>View</button></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  def render(%{mode: :wizard} = assigns) do
    ~H"""
    <div id={@id} class="component-panel">
      <%= if not @embedded do %>
        <.page_header title="Digital Wallet" subtitle="Stored-value wallet accounts">
          <:actions>
            <button class="btn-sm" phx-click="back_to_list" phx-target={@myself}>← Back to list</button>
          </:actions>
        </.page_header>
      <% end %>

      <%= if @notice do %><.alert kind={@notice_kind} message={@notice} /><% end %>

      <div class="card">
        <div style="font-size:16px;font-weight:700;margin-bottom:20px;">Open New Wallet — Step <%= @wizard_step %> of 3</div>

        <div style="display:flex;gap:4px;margin-bottom:24px;">
          <%= for {s, label} <- [{1, "Customer"}, {2, "Product"}, {3, "Review"}] do %>
            <div style={"flex:1;padding:6px 8px;text-align:center;font-size:12px;font-weight:600;border-radius:4px;cursor:pointer;
              background:#{if s <= @wizard_step, do: "var(--accent)", else: "var(--bg-canvas)"};
              color:#{if s <= @wizard_step, do: "#fff", else: "var(--text-secondary)"};"}
              phx-click={if s < @wizard_step, do: "wizard_step"} phx-value-s={s} phx-target={@myself}>
              <%= s %>. <%= label %>
            </div>
          <% end %>
        </div>

        <%= case @wizard_step do %>
          <% 1 -> %> <%= wallet_wizard_step1(assigns) %>
          <% 2 -> %> <%= wallet_wizard_step2(assigns) %>
          <% 3 -> %> <%= wallet_wizard_step3(assigns) %>
          <% _ -> %> <p>Invalid step.</p>
        <% end %>
      </div>
    </div>
    """
  end

  def render(%{mode: :detail} = assigns) do
    ~H"""
    <div id={@id} class="component-panel">
      <%= if @embedded do %>
        <div style="font-size:16px;font-weight:700;margin-bottom:12px;"><%= @account.customer_name %> — Digital Wallet</div>
      <% else %>
        <.page_header title={"#{@account.customer_name} — Digital Wallet"} subtitle="Wallet detail">
          <:actions>
            <button class="btn-sm" phx-click="back_to_list" phx-target={@myself}>← Back to list</button>
          </:actions>
        </.page_header>
      <% end %>

      <%= if @notice do %><.alert kind={@notice_kind} message={@notice} /><% end %>

      <div class="card" style="margin-bottom:16px;">
        <div style="display:flex;gap:8px;flex-wrap:wrap;">
          <%= if is_nil(@account.block_code) do %>
            <button class="btn btn-sm btn-danger" phx-click="open_action" phx-value-a="apply_block" phx-target={@myself}>🔒 Apply Block</button>
          <% else %>
            <button class="btn btn-sm btn-secondary" phx-click="open_action" phx-value-a="remove_block" phx-target={@myself}>🔓 Remove Block</button>
          <% end %>
          <button class="btn btn-sm btn-secondary" phx-click="open_action" phx-value-a="change_address" phx-target={@myself}>📬 Address Change</button>
          <button class="btn btn-sm btn-secondary" phx-click="open_action" phx-value-a="change_phone" phx-target={@myself}>📱 Phone Change</button>
          <button class="btn btn-sm btn-secondary" phx-click="open_action" phx-value-a="change_email" phx-target={@myself}>✉️ Email Change</button>
          <button class="btn btn-sm btn-secondary" phx-click="open_action" phx-value-a="change_limits" phx-target={@myself}>📊 Change Limits</button>
        </div>
        <div style="display:flex;gap:8px;margin-top:8px;flex-wrap:wrap;padding-top:8px;border-top:1px solid var(--border);">
          <span style="font-size:11px;color:var(--text-muted);align-self:center;font-weight:600;">KYC:</span>
          <%= if @account.kyc_status != "VERIFIED" do %>
            <button class="btn btn-sm btn-primary" style="background:var(--success);border-color:var(--success);"
              phx-click="wallet_kyc" phx-value-status="VERIFIED" phx-target={@myself}>✓ Verify</button>
          <% end %>
          <%= if @account.kyc_status != "REJECTED" do %>
            <button class="btn btn-sm btn-danger" phx-click="wallet_kyc" phx-value-status="REJECTED" phx-target={@myself}>✗ Reject</button>
          <% end %>
          <%= if @account.kyc_status != "PENDING" do %>
            <button class="btn btn-sm btn-secondary" phx-click="wallet_kyc" phx-value-status="PENDING" phx-target={@myself}>↺ Reset to Pending</button>
          <% end %>
          <span class={"badge #{kyc_badge_cls(@account.kyc_status)}"} style="margin-left:4px;"><%= @account.kyc_status %></span>
        </div>
      </div>

      <%= if @active_action in [:apply_block, :remove_block, :change_address, :change_phone, :change_email, :change_limits] do %>
        <%= wallet_action_panel(assigns) %>
      <% end %>

      <div class="card" style="padding:0;overflow:hidden;">
        <div class="detail-tabs">
          <%= for {idx, label, icon} <- [{1, "Overview", "📋"}, {2, "Transfers", "🔁"}, {3, "QR", "🔳"}, {4, "History", "📜"}] do %>
            <div class={"detail-tab#{if @detail_tab == idx, do: " active"}"}
              phx-click="detail_tab" phx-value-t={idx} phx-target={@myself}>
              <%= icon %> <%= label %>
            </div>
          <% end %>
        </div>
        <div style="padding:20px;">
          <%= case @detail_tab do %>
            <% 1 -> %> <%= wallet_tab_overview(assigns) %>
            <% 2 -> %> <%= wallet_tab_transfers(assigns) %>
            <% 3 -> %> <%= wallet_tab_qr(assigns) %>
            <% 4 -> %> <%= wallet_tab_history(assigns) %>
            <% _ -> %> <p>Invalid tab.</p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Account-level action panels (Digital Wallet Phase W4, 2026-07-28)
  # ---------------------------------------------------------------------------

  defp wallet_action_panel(%{active_action: :apply_block} = assigns) do
    ~H"""
    <div class="action-panel action-panel-danger" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>🔒 Apply Block Code</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <form phx-submit="wallet_block_save" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">Block Code *</label>
            <select class="input" name="action[block_code]" required>
              <option value="">— Select —</option>
              <%= for {label, val} <- @block_codes do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Reason Code *</label>
            <select class="input" name="action[reason_code]" required>
              <option value="">— Select —</option>
              <%= for {label, val} <- @block_reason_codes do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Free Text (optional)</label>
            <input type="text" class="input" name="action[reason_text]" maxlength="200"/>
          </div>
          <div class="form-group">
            <label class="form-label">Operator Role</label>
            <select class="input" name="action[operator_role]">
              <%= for {label, val} <- @operator_roles do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group" style="grid-column:1/-1;">
            <label class="form-label">Operator ID (UUID)</label>
            <input type="text" class="input" name="action[operator_id]" placeholder="00000000-0000-0000-0000-000000000001" style="font-family:monospace;"/>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-danger">Apply Block</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp wallet_action_panel(%{active_action: :remove_block} = assigns) do
    ~H"""
    <div class="action-panel" style="margin-bottom:16px;border-color:#bbf7d0;background:#f0fdf4;">
      <div class="action-panel-title">
        <span>🔓 Remove Block Code <%= @account.block_code %></span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <form phx-submit="wallet_unblock_save" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">Reason Code *</label>
            <select class="input" name="action[reason_code]" required>
              <option value="">— Select —</option>
              <%= for {label, val} <- @unblock_reason_codes do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Operator Role</label>
            <select class="input" name="action[operator_role]">
              <%= for {label, val} <- @operator_roles do %>
                <option value={val}><%= label %></option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Notes (optional)</label>
            <input type="text" class="input" name="action[reason_text]" maxlength="200"/>
          </div>
          <div class="form-group">
            <label class="form-label">Operator ID (UUID)</label>
            <input type="text" class="input" name="action[operator_id]" placeholder="00000000-0000-0000-0000-000000000001" style="font-family:monospace;"/>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-success">Remove Block</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp wallet_action_panel(%{active_action: act} = assigns) when act in [:change_address, :change_phone, :change_email] do
    ~H"""
    <div class="action-panel" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>
          <%= case @active_action do
            :change_address -> "📬 Address Change"
            :change_phone   -> "📱 Phone Change"
            :change_email   -> "✉️ Email Change"
          end %>
        </span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <form phx-submit="wallet_nonmon_save" phx-target={@myself}>
        <input type="hidden" name="action[event_type]" value={
          case @active_action do
            :change_address -> "address_change"
            :change_phone   -> "phone_change"
            :change_email   -> "email_change"
          end
        }/>
        <%= if @active_action == :change_address do %>
          <div class="form-grid-2">
            <div class="form-group" style="grid-column:1/-1;">
              <label class="form-label">New Address Line 1 *</label>
              <input type="text" class="input" name="action[new_line1]" required value={@customer && @customer.address_line1}/>
            </div>
            <div class="form-group" style="grid-column:1/-1;">
              <label class="form-label">Address Line 2</label>
              <input type="text" class="input" name="action[new_line2]" value={@customer && @customer.address_line2}/>
            </div>
            <div class="form-group">
              <label class="form-label">City *</label>
              <input type="text" class="input" name="action[new_city]" required value={@customer && @customer.city}/>
            </div>
            <div class="form-group">
              <label class="form-label">Postal Code</label>
              <input type="text" class="input" name="action[new_postal]" value={@customer && @customer.postal_code}/>
            </div>
            <div class="form-group">
              <label class="form-label">Country</label>
              <input type="text" class="input" name="action[new_country]" value={@customer && @customer.country}/>
            </div>
          </div>
        <% end %>
        <%= if @active_action == :change_phone do %>
          <div class="form-grid-2">
            <div class="form-group">
              <label class="form-label">Country Code</label>
              <input type="text" class="input" name="action[new_mobile_country]" value={@customer && @customer.mobile_country} placeholder="971"/>
            </div>
            <div class="form-group">
              <label class="form-label">Mobile Number *</label>
              <input type="text" class="input" name="action[new_mobile_number]" required value={@customer && @customer.mobile_number}/>
            </div>
          </div>
        <% end %>
        <%= if @active_action == :change_email do %>
          <div class="form-group">
            <label class="form-label">New Email Address *</label>
            <input type="email" class="input" name="action[new_email]" required value={@customer && @customer.email}/>
          </div>
        <% end %>
        <div class="form-grid-2" style="margin-top:12px;">
          <div class="form-group">
            <label class="form-label">Reason / Notes</label>
            <input type="text" class="input" name="action[reason]" placeholder="Reason…"/>
          </div>
          <div class="form-group">
            <label class="form-label">Reference ID</label>
            <input type="text" class="input" name="action[reference_id]" maxlength="50"/>
          </div>
          <div class="form-group">
            <label class="form-label">Operator ID (UUID)</label>
            <input type="text" class="input" name="action[operator_id]" placeholder="00000000-0000-0000-0000-000000000001" style="font-family:monospace;"/>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-primary">Save Change</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  defp wallet_action_panel(%{active_action: :change_limits} = assigns) do
    current = assigns.account.velocity_limits || %{}
    daily = Map.get(current, "DAILY", %{})
    monthly = Map.get(current, "MONTHLY", %{})
    assigns = assign(assigns, daily: daily, monthly: monthly)

    ~H"""
    <div class="action-panel" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>📊 Change Transaction/Velocity Limits</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <div class="text-sm text-muted" style="margin-bottom:8px;">
        Enforced on every load and incoming transfer (`WalletVelocityLimits`).
        A breach declines the transaction and auto-triggers a step-up WALLET
        KYC request for this customer. Leave a field blank for no cap.
      </div>
      <form phx-submit="wallet_limits_save" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">Daily Transaction Count</label>
            <input type="number" class="input" name="action[daily_count]" value={@daily["count"]} min="0"/>
          </div>
          <div class="form-group">
            <label class="form-label">Daily Amount</label>
            <input type="number" class="input" name="action[daily_amount]" value={@daily["amount"]} min="0" step="100"/>
          </div>
          <div class="form-group">
            <label class="form-label">Monthly Amount</label>
            <input type="number" class="input" name="action[monthly_amount]" value={@monthly["amount"]} min="0" step="100"/>
          </div>
          <div class="form-group">
            <label class="form-label">Operator ID (UUID)</label>
            <input type="text" class="input" name="action[operator_id]" placeholder="00000000-0000-0000-0000-000000000001" style="font-family:monospace;"/>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px;">
          <button type="submit" class="btn btn-primary">Save Limits</button>
          <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Detail tab partials (Digital Wallet Phase W4, 2026-07-28)
  # ---------------------------------------------------------------------------

  defp wallet_tab_overview(assigns) do
    ~H"""
    <div class="form-pane-section-title" style="display:flex;justify-content:space-between;align-items:center;">
      <span>Balance</span>
      <button :if={@can_edit} class="btn btn-sm btn-primary" phx-click="open_action" phx-value-a="load_account" phx-target={@myself}>+ Load Wallet</button>
    </div>

    <%= if @active_action == :load_account do %>
      <div class="action-panel" style="margin-bottom:16px;">
        <div class="action-panel-title">
          <span>💰 Load Wallet</span>
          <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
        </div>
        <form phx-submit="load_account_save" phx-target={@myself}>
          <div class="form-grid-2">
            <div class="form-group"><label class="form-label">Amount *</label>
              <input class="input" type="text" name="load[amount]" placeholder="100.00" required/></div>
            <div class="form-group"><label class="form-label">Channel</label>
              <select class="input" name="load[channel]">
                <option value="ADMIN_MANUAL">Admin Manual</option>
                <option value="EXTERNAL_BANK_TRANSFER">External Bank Transfer</option>
                <option value="CASH_DEPOSIT">Cash Deposit</option>
              </select></div>
            <div class="form-group"><label class="form-label">Reference (required for external channels)</label>
              <input class="input" type="text" name="load[external_reference]"/></div>
          </div>
          <div style="display:flex;gap:8px;margin-top:12px;">
            <button type="submit" class="btn btn-primary">Load</button>
            <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
          </div>
        </form>
      </div>
    <% end %>

    <div class="table-wrap">
      <table class="data-table">
        <tbody>
          <tr><td>Wallet</td><td><%= @product && @product.name %></td></tr>
          <tr><td>Balance</td><td class="mono"><%= money(@account.available_balance) %> <%= @account.currency %></td></tr>
          <tr><td>Status</td><td><span class={"badge #{status_cls(@account.status)}"}><%= @account.status %></span></td></tr>
          <tr><td>Opened</td><td><%= @account.opened_at %></td></tr>
        </tbody>
      </table>
    </div>

    <div class="form-pane-section-title" style="display:flex;justify-content:space-between;align-items:center;margin-top:16px;">
      <span>Currencies (<%= length(@sibling_accounts) %>)</span>
      <button :if={@can_edit} class="btn btn-sm btn-secondary" phx-click="open_action" phx-value-a="add_currency" phx-target={@myself}>+ Add Currency</button>
    </div>

    <%= if @active_action == :add_currency do %>
      <div class="action-panel" style="margin-bottom:16px;">
        <div class="action-panel-title">
          <span>💱 Add a Currency to this Wallet</span>
          <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
        </div>
        <div class="text-sm text-muted" style="margin-bottom:8px;">
          Opens a new single-currency account under the same wallet, using
          this account's SYS/BANK/LOGO/BLOCK scope. Each currency is its
          own balance — money doesn't move between currencies automatically.
        </div>
        <form phx-submit="add_currency_save" phx-target={@myself}>
          <div class="form-grid-2">
            <div class="form-group"><label class="form-label">Currency (ISO 4217) *</label>
              <input class="input" type="text" name="action[currency]" placeholder="USD" maxlength="3" required/></div>
          </div>
          <div style="display:flex;gap:8px;margin-top:12px;">
            <button type="submit" class="btn btn-primary">Add Currency</button>
            <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
          </div>
        </form>
      </div>
    <% end %>

    <div class="table-wrap">
      <table class="data-table">
        <thead><tr><th>Currency</th><th>Balance</th><th>Status</th><th></th></tr></thead>
        <tbody>
          <%= for sib <- @sibling_accounts do %>
            <tr class={if sib.wallet_account_id == @account.wallet_account_id, do: "row-active", else: ""}>
              <td><%= sib.currency %></td>
              <td class="mono"><%= money(sib.available_balance) %></td>
              <td><span class={"badge #{status_cls(sib.status)}"}><%= sib.status %></span></td>
              <td>
                <%= if sib.wallet_account_id == @account.wallet_account_id do %>
                  <span class="text-sm text-muted">Viewing</span>
                <% else %>
                  <button class="btn btn-sm btn-ghost" phx-click="switch_currency" phx-value-id={sib.wallet_account_id} phx-target={@myself}>View →</button>
                <% end %>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp wallet_tab_transfers(assigns) do
    ~H"""
    <div class="form-pane-section-title" style="display:flex;justify-content:space-between;align-items:center;">
      <span>Transfers (<%= length(@transfers) %>)</span>
      <button :if={@can_edit} class="btn btn-sm btn-primary" phx-click="open_action" phx-value-a="send_transfer" phx-target={@myself}>+ Send Money</button>
    </div>

    <%= if @active_action == :send_transfer do %>
      <div class="action-panel" style="margin-bottom:16px;">
        <div class="action-panel-title">
          <span>🔁 Send Money</span>
          <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
        </div>

        <%= if @xfer_selected do %>
          <div style="background:#f0fdf4;border:1px solid #bbf7d0;padding:10px 14px;border-radius:8px;margin-bottom:12px;display:flex;justify-content:space-between;align-items:center;">
            <div><strong><%= @xfer_selected.first_name %> <%= @xfer_selected.last_name %></strong> (<%= @xfer_selected.currency %>)</div>
            <button class="btn btn-sm btn-ghost" phx-click="xfer_clear" phx-target={@myself}>Change</button>
          </div>

          <form phx-submit="transfer_save" phx-target={@myself}>
            <div class="form-grid-2">
              <div class="form-group"><label class="form-label">Amount *</label>
                <input class="input" type="text" name="transfer[amount]" placeholder="50.00" required/></div>
              <div class="form-group"><label class="form-label">Reason (optional)</label>
                <input class="input" type="text" name="transfer[reason]" maxlength="255"/></div>
            </div>
            <div style="display:flex;gap:8px;margin-top:12px;">
              <button type="submit" class="btn btn-primary">Send</button>
              <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
            </div>
          </form>
        <% else %>
          <div style="margin-bottom:12px;">
            <input type="text" class="input" placeholder="Search recipient by name…"
              value={@xfer_search} phx-keyup="xfer_search" phx-debounce="300"
              phx-target={@myself} style="width:100%;max-width:480px;"/>
          </div>
          <%= if @xfer_results != [] do %>
            <div class="table-wrap">
              <table class="data-table">
                <thead><tr><th>Name</th><th>Currency</th><th></th></tr></thead>
                <tbody>
                  <%= for r <- @xfer_results do %>
                    <tr>
                      <td><%= r.first_name %> <%= r.last_name %></td>
                      <td><%= r.currency %></td>
                      <td><button class="btn btn-sm btn-primary" phx-click="xfer_select" phx-value-id={r.wallet_account_id} phx-target={@myself}>Select</button></td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
          <%= if @xfer_search != "" && @xfer_results == [] do %>
            <div class="empty-row" style="padding:20px;text-align:center;">No matching wallets found.</div>
          <% end %>
        <% end %>
      </div>
    <% end %>

    <div class="table-wrap">
      <.ag_grid
        id="wallet-transfers-grid"
        empty_message="No transfers yet."
        columns={[
          %{field: "at", header: "Date", width: 160},
          %{field: "direction", header: "Direction", type: "badge", classField: "direction_class", width: 120},
          %{field: "amount", header: "Amount", flex: 1},
          %{field: "reason", header: "Reason", flex: 1},
          %{field: "initiated_by", header: "By", type: "mono", width: 130}
        ]}
        rows={Enum.map(@transfers, &transfer_row(&1, @account))}
      />
    </div>
    """
  end

  defp wallet_tab_qr(assigns) do
    ~H"""
    <div class="form-pane-section-title">Receive via QR</div>
    <form phx-submit="generate_qr_save" phx-target={@myself}>
      <div class="form-grid-2">
        <div class="form-group"><label class="form-label">Amount (optional — leave blank for open amount)</label>
          <input class="input" type="text" name="qr[amount]" placeholder="25.00"/></div>
        <div class="form-group"><label class="form-label">Label (optional)</label>
          <input class="input" type="text" name="qr[label]" maxlength="60" placeholder="e.g. Rent"/></div>
      </div>
      <div style="margin-top:12px;">
        <button type="submit" class="btn btn-primary">Generate QR</button>
      </div>
    </form>

    <%= if @generated_qr do %>
      <div class="table-wrap" style="margin-top:16px;">
        <div class="form-pane-section-title">QR Code (wire format — copy to share)</div>
        <textarea class="input" readonly rows="2" style="font-family:monospace;font-size:12px;width:100%;"><%= @generated_qr %></textarea>
      </div>
    <% end %>

    <div class="form-pane-section-title" style="margin-top:24px;">Pay a QR Code</div>
    <form phx-submit="pay_qr_save" phx-target={@myself}>
      <div class="form-grid-2">
        <div class="form-group" style="grid-column:1/-1;"><label class="form-label">QR Code String *</label>
          <textarea class="input" name="pay[qr_string]" rows="2" style="font-family:monospace;font-size:12px;width:100%;" required></textarea></div>
        <div class="form-group"><label class="form-label">Amount (only if the QR is open-amount)</label>
          <input class="input" type="text" name="pay[amount]" placeholder="25.00"/></div>
      </div>
      <div style="margin-top:12px;">
        <button type="submit" class="btn btn-primary">Pay</button>
      </div>
    </form>
    """
  end

  defp wallet_tab_history(assigns) do
    entries =
      (Enum.map(assigns.block_history, fn h ->
         %{
           at: h.applied_at, kind: h.action,
           detail: "#{h.block_code || "—"} — #{h.reason_code}#{if h.reason_text, do: ": #{h.reason_text}", else: ""}",
           operator: h.operator_id
         }
       end) ++
         Enum.map(assigns.nonmon_events, fn e ->
           %{at: e.applied_at, kind: String.upcase(e.event_type), detail: e.reason || "—", operator: e.operator_id}
         end))
      |> Enum.sort_by(& &1.at, {:desc, NaiveDateTime})

    assigns = assign(assigns, :entries, entries)

    ~H"""
    <div class="form-pane-section-title">Account History (<%= length(@entries) %>)</div>
    <.ag_grid
      id="wallet-account-history-grid"
      empty_message="No history yet."
      columns={[
        %{field: "at", header: "Date", width: 160},
        %{field: "kind", header: "Event", type: "badge", classField: "kind_class", width: 150},
        %{field: "detail", header: "Detail", flex: 2},
        %{field: "operator", header: "Operator", type: "mono", width: 140}
      ]}
      rows={Enum.map(@entries, &history_entry_row/1)}
    />
    """
  end

  # ---------------------------------------------------------------------------
  # Wizard step partials (Digital Wallet Phase W4, 2026-07-28)
  # ---------------------------------------------------------------------------

  defp wallet_wizard_step1(assigns) do
    ~H"""
    <div>
      <div class="form-pane-section-title">Step 1 — Select Customer</div>

      <%= if @form_data["customer_id"] do %>
        <div style="background:#f0fdf4;border:1px solid #bbf7d0;padding:12px 16px;border-radius:8px;margin-bottom:16px;display:flex;justify-content:space-between;align-items:center;">
          <div>
            <div style="font-weight:600;"><%= @form_data["customer_name"] %></div>
            <div style="font-size:12px;color:var(--text-secondary);">Bank: <%= @form_data["bank_id"] %></div>
          </div>
          <button class="btn btn-sm btn-ghost" phx-click="wizard_step" phx-value-s="1" phx-target={@myself}>Change</button>
        </div>
        <div style="display:flex;justify-content:flex-end;">
          <button class="btn btn-primary" phx-click="wizard_step" phx-value-s="2" phx-target={@myself}>
            Next: Select Product →
          </button>
        </div>
      <% else %>
        <div style="margin-bottom:12px;">
          <input type="text" class="input" placeholder="Search by name, email, or mobile…"
            value={@customer_search} phx-keyup="cust_search_wizard" phx-debounce="300"
            phx-target={@myself} style="width:100%;max-width:480px;"/>
        </div>

        <%= if @customer_results != [] do %>
          <div class="table-wrap">
            <table class="data-table">
              <thead><tr><th>Name</th><th>Email</th><th>Bank</th><th></th></tr></thead>
              <tbody>
                <%= for c <- @customer_results do %>
                  <tr>
                    <td><%= c.first_name %> <%= c.last_name %></td>
                    <td style="font-size:12px;"><%= c.email %></td>
                    <td><%= c.bank_id %></td>
                    <td><button class="btn btn-sm btn-primary" phx-click="select_customer" phx-value-id={c.customer_id} phx-target={@myself}>Select</button></td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>

        <%= if @customer_search != "" && @customer_results == [] do %>
          <div class="empty-row" style="padding:20px;text-align:center;">No customers found. Try a different search.</div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp wallet_wizard_step2(assigns) do
    ~H"""
    <div>
      <div class="form-pane-section-title">Step 2 — Select Product (LOGO + BLOCK)</div>
      <form phx-change="wizard_change" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group" style="grid-column:1/-1;">
            <label class="form-label">Wallet Name</label>
            <input class="input" type="text" name="acc[wallet_name]" value={@form_data["wallet_name"]}/>
          </div>
          <div class="form-group">
            <label class="form-label">Logo (Product) *</label>
            <select class="input" name="acc[logo_id]" required>
              <option value="">— Select Logo —</option>
              <%= for l <- @logos_for_bank do %>
                <option value={l.logo_id} selected={@form_data["logo_id"] == l.logo_id}>
                  <%= l.logo_id %> — <%= l.description || l.logo_id %>
                </option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Block (Sub-product)</label>
            <select class="input" name="acc[block_id]">
              <option value="DFLT">DFLT — Default Block</option>
              <%= for b <- @blocks_for_logo do %>
                <option value={b.block_id} selected={@form_data["block_id"] == b.block_id}>
                  <%= b.block_id %> — <%= b.description || b.block_id %>
                </option>
              <% end %>
            </select>
          </div>
          <div class="form-group">
            <label class="form-label">Currency</label>
            <select class="input" name="acc[currency]">
              <option value="AED" selected={@form_data["currency"] in [nil, "AED"]}>AED</option>
              <option value="USD" selected={@form_data["currency"] == "USD"}>USD</option>
              <option value="EUR" selected={@form_data["currency"] == "EUR"}>EUR</option>
            </select>
          </div>
        </div>
      </form>

      <div style="display:flex;gap:8px;margin-top:20px;">
        <button class="btn btn-secondary" phx-click="wizard_step" phx-value-s="1" phx-target={@myself}>← Back</button>
        <button class="btn btn-primary" phx-click="wizard_step" phx-value-s="3" phx-target={@myself}
          disabled={is_nil(@form_data["logo_id"]) or @form_data["logo_id"] == ""}>
          Next: Review →
        </button>
      </div>
    </div>
    """
  end

  defp wallet_wizard_step3(assigns) do
    ~H"""
    <div>
      <div class="form-pane-section-title">Step 3 — Review</div>
      <.kv_detail rows={[
        {"Customer", @form_data["customer_name"]},
        {"Wallet Name", @form_data["wallet_name"]},
        {"Bank", @form_data["bank_id"]},
        {"Logo (Product)", @form_data["logo_id"]},
        {"Block (Sub-product)", @form_data["block_id"] || "DFLT"},
        {"Currency", @form_data["currency"] || "AED"}
      ]}/>
      <div style="display:flex;gap:8px;margin-top:20px;">
        <button class="btn btn-secondary" phx-click="wizard_step" phx-value-s="2" phx-target={@myself}>← Back</button>
        <button class="btn btn-primary" phx-click="wizard_save" phx-target={@myself}>Open Wallet</button>
      </div>
    </div>
    """
  end

  defp transfer_row(t, account) do
    %{
      at: Calendar.strftime(t.inserted_at, "%Y-%m-%d %H:%M"),
      direction: if(t.from_wallet_account_id == account.wallet_account_id, do: "SENT", else: "RECEIVED"),
      direction_class: if(t.from_wallet_account_id == account.wallet_account_id, do: "badge-red", else: "badge-green"),
      amount: "#{money(t.amount)} #{t.currency}",
      reason: t.reason || "—",
      initiated_by: t.initiated_by
    }
  end

  defp history_entry_row(e) do
    %{
      at: Calendar.strftime(e.at, "%Y-%m-%d %H:%M"),
      kind: e.kind,
      kind_class: if(e.kind in ["BLOCKED"], do: "badge-red", else: "badge-blue"),
      detail: e.detail,
      operator: e.operator
    }
  end
end
