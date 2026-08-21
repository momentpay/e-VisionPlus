defmodule VmuCoreWeb.Live.Admin.DebitComponent do
  @moduledoc """
  Admin LiveComponent: Debit account list/detail (Way4 parity plan Phase
  1 item 4, D5, 2026-07-26) — the first ops UI for real network-issued
  Debit accounts, distinct from Prepaid (closed-loop wallet, not built in
  this repo) and from Credit (`AccountComponent`).

  - Account list with search, and a "+ New Account" form (opens a new
    CIF customer + `CMS.DebitAccount` together — same inline-customer
    convention `HcsComponent`'s company creation already uses)
  - Account detail: balance, funding history, card roster, fund/issue
    actions. Card activate/block/unblock reuse `CTA.CardLifecycle`
    directly (confirmed to already work unchanged for a debit-issued
    card — see D5's own tracker notes for the two real bugs found and
    fixed making that true)

  Deliberately NOT in this pass: card replace/renew (`CardLifecycle.
  replace/3`/`renew/2` are not yet debit-aware — flagged, not fixed);
  the hot-card/lost-stolen-fraud blocklist (`FAS.HotCardCache` has no
  debit equivalent yet — its own design question).

  Visibility requires `debit:view`; create/fund/issue require `debit:edit`.
  """

  use Phoenix.LiveComponent
  import Ecto.Query
  import VmuCoreWeb.AdminUI
  import VmuCoreWeb.Components.AgGrid

  alias VmuCore.{Repo, CMS.DebitAccount, CMS.DebitAccountOpening, CMS.DebitFunding,
                 CMS.DebitFundingCommand, CMS.DebitAdjustmentCommand, CMS.DebitBlockHistory,
                 CMS.DebitNonMonetaryEvent, CTA.CardLifecycle, CTA.Cards}
  alias VmuCore.NTS.{Tokens, TokenLifecycle}
  alias VmuCore.Shared.{Customer, LogoParameter, BlockParameter}
  alias VmuCore.ASM.Authz

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
  @tri_state [{"Inherit", ""}, {"Enabled", "true"}, {"Disabled", "false"}]
  alias Decimal, as: D

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
       customer: nil,
       fundings: [],
       cards: [],
       nts_tokens: [],
       adjustments: [],
       block_history: [],
       nonmon_events: [],
       channels_card_id: nil,
       # Card Products UX Parity Phase 1e (2026-07-28) — module attribute
       # option lists must be lifted into assigns: inside a ~H sigil, @foo
       # always resolves against assigns, never a module attribute
       # (confirmed live via a KeyError — same convention AccountComponent
       # already uses for its own equivalent constants).
       block_codes: @block_codes,
       block_reason_codes: @block_reason_codes,
       unblock_reason_codes: @unblock_reason_codes,
       operator_roles: @operator_roles,
       tri_state: @tri_state,
       can_edit: false,
       loaded_deep_link_id: nil,
       embedded: false,
       # Card Products UX Parity Phase 1 (2026-07-28) — wizard-based
       # creation, replacing the old flat form that both hand-typed raw
       # SYS/BANK/LOGO/BLOCK IDs AND always created a brand-new Customer
       # (no way to open a Debit account for an existing one, unlike
       # Credit's wizard). Mirrors AccountComponent's own wizard state
       # shape so the pattern is legible across both components.
       wizard_step: 1,
       form_data: %{},
       customer_search: "",
       customer_results: [],
       logos_for_bank: [],
       blocks_for_logo: [],
       detail_tab: 1
     )
     |> load_accounts()}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    operator = socket.assigns[:current_operator]
    socket = assign(socket, can_edit: operator && Authz.can?(operator, "debit", "edit"))

    # Koṣa domain-model alignment (2026-07-28) — a "View in Debit Cards"
    # link lands here with ?view=<debit_account_id>; open straight to
    # that account's detail instead of the bare list.
    socket =
      case assigns[:deep_link_id] do
        id when is_binary(id) and id != "" and id != socket.assigns.loaded_deep_link_id ->
          socket |> assign(detail_tab: 1) |> load_detail(id) |> assign(loaded_deep_link_id: id)

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
    {:noreply, assign(socket, detail_tab: String.to_integer(t), active_action: :none)}
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
  # Account-level Block / Non-Monetary Events / Limits / KYC
  # (Card Products UX Parity Phase 1e, 2026-07-28) — own tables, own audit
  # trails, mirroring AccountComponent's equivalent handlers exactly.
  # ---------------------------------------------------------------------------

  def handle_event("debit_block_save", %{"action" => params}, socket) do
    acc   = socket.assigns.account
    op_id = normalize_uuid(params["operator_id"])

    case DebitBlockHistory.record_block(
      acc.debit_account_id, params["block_code"], params["reason_code"],
      params["reason_text"] || "", op_id, params["operator_role"] || "AGENT"
    ) do
      {:ok, _hist} ->
        {:noreply, socket
                    |> load_detail(acc.debit_account_id)
                    |> assign(active_action: :none, notice: "Block code #{params["block_code"]} applied.", notice_kind: :success)}

      {:error, cs} ->
        {:noreply, assign(socket, notice: "Block failed — #{cs_error_msg(cs)}", notice_kind: :error)}
    end
  end

  def handle_event("debit_unblock_save", %{"action" => params}, socket) do
    acc   = socket.assigns.account
    op_id = normalize_uuid(params["operator_id"])

    case DebitBlockHistory.record_unblock(
      acc.debit_account_id, acc.block_code || "L", params["reason_code"],
      params["reason_text"] || "", op_id, params["operator_role"] || "AGENT"
    ) do
      {:ok, _hist} ->
        {:noreply, socket
                    |> load_detail(acc.debit_account_id)
                    |> assign(active_action: :none, notice: "Block removed.", notice_kind: :success)}

      {:error, cs} ->
        {:noreply, assign(socket, notice: "Unblock failed — #{cs_error_msg(cs)}", notice_kind: :error)}
    end
  end

  def handle_event("debit_nonmon_save", %{"action" => params}, socket) do
    acc   = socket.assigns.account
    etype = params["event_type"]
    op_id = normalize_uuid(params["operator_id"])
    {old_val, new_val} = build_nonmon_values(etype, params, socket.assigns)

    case DebitNonMonetaryEvent.record(
      debit_account_id: acc.debit_account_id,
      event_type:        etype,
      old_value:         old_val,
      new_value:         new_val,
      reason:            params["reason"] || "",
      reference_id:      params["reference_id"],
      operator_id:       op_id,
      operator_role:     params["operator_role"] || "AGENT"
    ) do
      {:ok, _event} ->
        apply_nonmon_change(etype, params, socket.assigns)
        {:noreply, socket
                    |> load_detail(acc.debit_account_id)
                    |> assign(active_action: :none, notice: "#{etype_label(etype)} recorded.", notice_kind: :success)}

      {:error, cs} ->
        {:noreply, assign(socket, notice: "Event failed — #{cs_error_msg(cs)}", notice_kind: :error)}
    end
  end

  def handle_event("debit_limits_save", %{"action" => params}, socket) do
    acc   = socket.assigns.account
    op_id = normalize_uuid(params["operator_id"])

    new_limits = %{
      "POS" => %{"daily_count" => parse_int(params["pos_daily_count"]), "daily_amount" => parse_int(params["pos_daily_amount"])},
      "ATM" => %{"daily_count" => parse_int(params["atm_daily_count"]), "daily_amount" => parse_int(params["atm_daily_amount"])}
    }

    case acc |> DebitAccount.changeset(%{velocity_limits: new_limits}) |> Repo.update() do
      {:ok, _updated} ->
        DebitNonMonetaryEvent.record(
          debit_account_id: acc.debit_account_id,
          event_type:        "limit_change",
          old_value:         acc.velocity_limits || %{},
          new_value:         new_limits,
          reason:            "Velocity limits updated",
          operator_id:       op_id,
          operator_role:     "AGENT"
        )

        {:noreply, socket
                    |> load_detail(acc.debit_account_id)
                    |> assign(active_action: :none, notice: "Velocity limits updated.", notice_kind: :success)}

      {:error, cs} ->
        {:noreply, assign(socket, notice: "Update failed — #{cs_error_msg(cs)}", notice_kind: :error)}
    end
  end

  def handle_event("debit_kyc", %{"status" => status}, socket) do
    acc = socket.assigns.account

    attrs =
      if status == "VERIFIED",
        do: %{kyc_status: status, kyc_verified_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)},
        else: %{kyc_status: status, kyc_verified_at: nil}

    case acc |> DebitAccount.changeset(attrs) |> Repo.update() do
      {:ok, _updated} ->
        {:noreply, socket
                    |> load_detail(acc.debit_account_id)
                    |> assign(notice: "KYC status set to #{status}.", notice_kind: :success)}

      {:error, cs} ->
        {:noreply, assign(socket, notice: "KYC update failed — #{cs_error_msg(cs)}", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Create account — wizard (Card Products UX Parity Phase 1, 2026-07-28)
  # ---------------------------------------------------------------------------

  def handle_event("debit_new", _params, socket) do
    {:noreply, assign(socket,
      mode: :wizard, wizard_step: 1, form_data: %{},
      customer_search: "", customer_results: [],
      logos_for_bank: [], blocks_for_logo: [], notice: nil
    )}
  end

  # Real bug found live (2026-07-28): phx-keyup always sends the input's
  # live-typed text under "value" automatically — the old phx-value-q
  # binding just re-sent last render's @customer_search (stale, always
  # one keystroke behind, empty on the very first character), and this
  # handler was reading that stale key instead of the live one. Search
  # silently never worked as a result.
  def handle_event("cust_search_wizard", %{"value" => q}, socket) do
    results =
      if String.length(q || "") >= 2 do
        term = "%#{q}%"
        # Real bug found live (2026-07-28): matching first_name/last_name
        # separately means a combined "First Last" search (what an
        # operator naturally types) never matches either field alone —
        # also matches on the concatenated full name.
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
          "kyc_status" => cust.kyc_status,
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

      case DebitAccountOpening.open(%{
             customer_id: fd["customer_id"], sys_id: fd["sys_id"], bank_id: fd["bank_id"],
             logo_id: fd["logo_id"], block_id: fd["block_id"] || "DFLT"
           }) do
        {:ok, account} ->
          {:noreply, socket
                      |> assign(mode: :list, detail_tab: 1, notice: "Debit account opened for #{fd["customer_name"]}.", notice_kind: :success)
                      |> load_accounts()
                      |> then(&load_detail(&1, account.debit_account_id))}

        {:error, changeset} ->
          {:noreply, assign(socket, notice: "Create failed — #{inspect(changeset.errors)}", notice_kind: :error)}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot create debit accounts.", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Fund account
  # ---------------------------------------------------------------------------

  def handle_event("fund_account_save", %{"funding" => params}, socket) do
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

          case DebitFundingCommand.fund(%{
                 debit_account_id: socket.assigns.account.debit_account_id, amount: amount,
                 channel: channel, posted_by: operator.username,
                 external_reference: blank_to_nil(params["external_reference"])
               }) do
            {:ok, _result} ->
              {:noreply, socket
                          |> load_detail(socket.assigns.account.debit_account_id)
                          |> assign(active_action: :none, notice: "Account funded: #{money(amount)}.", notice_kind: :success)}

            {:error, reason} ->
              {:noreply, assign(socket, notice: "Funding failed — #{inspect(reason)}", notice_kind: :error)}
          end
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot fund debit accounts.", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Adjustments (Card Products UX Parity Phase 1c, 2026-07-28)
  # ---------------------------------------------------------------------------

  def handle_event("debit_adjustment_save", %{"adjustment" => params}, socket) do
    amount = parse_decimal(params["amount"])

    cond do
      is_nil(amount) ->
        {:noreply, assign(socket, notice: "A valid amount is required.", notice_kind: :error)}

      params["reference_id"] in [nil, ""] ->
        {:noreply, assign(socket, notice: "Reference ID is required.", notice_kind: :error)}

      true ->
        case resolve_checker(socket, params["supervisor_id"], amount) do
          {:ok, checker} ->
            attrs = %{
              debit_account_id: socket.assigns.account.debit_account_id,
              direction: params["direction"], amount: amount,
              reason: params["reason"] || "", reference_id: params["reference_id"],
              operator_id: maker_id(socket), supervisor_id: checker.username
            }

            case DebitAdjustmentCommand.post(attrs) do
              {:ok, _adjustment} ->
                {:noreply, socket
                            |> load_detail(socket.assigns.account.debit_account_id)
                            |> assign(active_action: :none, notice: "Adjustment posted.", notice_kind: :success)}

              {:error, :insufficient_funds} ->
                {:noreply, assign(socket, notice: "Adjustment failed — insufficient funds for a DEBIT of that amount.", notice_kind: :error)}

              {:error, %Ecto.Changeset{} = cs} ->
                {:noreply, assign(socket, notice: "Adjustment failed — #{inspect(cs.errors)}", notice_kind: :error)}

              {:error, reason} ->
                {:noreply, assign(socket, notice: "Adjustment failed — #{inspect(reason)}", notice_kind: :error)}
            end

          {:error, checker_error} ->
            {:noreply, assign(socket, notice: checker_error_msg(checker_error), notice_kind: :error)}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Card issuance / lifecycle
  # ---------------------------------------------------------------------------

  def handle_event("issue_card_save", %{"card" => params}, socket) do
    if socket.assigns.can_edit do
      card_type = params["card_type"] || "PRIMARY"

      case CardLifecycle.issue_new_debit(socket.assigns.account, card_type: card_type) do
        {:ok, _card} ->
          {:noreply, socket
                      |> load_detail(socket.assigns.account.debit_account_id)
                      |> assign(active_action: :none, notice: "#{card_type} card issued (INACTIVE).", notice_kind: :success)}

        {:error, reason} ->
          {:noreply, assign(socket, notice: "Card issuance failed — #{inspect(reason)}", notice_kind: :error)}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot issue cards.", notice_kind: :error)}
    end
  end

  def handle_event("card_activate", %{"id" => card_id}, socket) do
    if socket.assigns.can_edit do
      case CardLifecycle.activate(card_id, operator: socket.assigns.current_operator) do
        {:ok, _card} ->
          {:noreply, socket |> load_detail(socket.assigns.account.debit_account_id) |> assign(notice: "Card activated.", notice_kind: :success)}

        {:error, reason} ->
          {:noreply, assign(socket, notice: "Activation failed — #{inspect(reason)}", notice_kind: :error)}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot activate cards.", notice_kind: :error)}
    end
  end

  def handle_event("card_block", %{"id" => card_id}, socket) do
    if socket.assigns.can_edit do
      case CardLifecycle.block(card_id, "ADMIN", operator: socket.assigns.current_operator) do
        {:ok, _card} ->
          {:noreply, socket |> load_detail(socket.assigns.account.debit_account_id) |> assign(notice: "Card blocked.", notice_kind: :success)}

        {:error, reason} ->
          {:noreply, assign(socket, notice: "Block failed — #{inspect(reason)}", notice_kind: :error)}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot block cards.", notice_kind: :error)}
    end
  end

  def handle_event("card_unblock", %{"id" => card_id}, socket) do
    if socket.assigns.can_edit do
      case CardLifecycle.unblock(card_id, operator: socket.assigns.current_operator) do
        {:ok, _card} ->
          {:noreply, socket |> load_detail(socket.assigns.account.debit_account_id) |> assign(notice: "Card unblocked.", notice_kind: :success)}

        {:error, reason} ->
          {:noreply, assign(socket, notice: "Unblock failed — #{inspect(reason)}", notice_kind: :error)}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot unblock cards.", notice_kind: :error)}
    end
  end

  # NTS Phase E — admin console manual "remove device" action.
  def handle_event("nts_token_remove", %{"id" => token_id}, socket) do
    if socket.assigns.can_edit do
      case TokenLifecycle.delete_token(token_id, operator: socket.assigns.current_operator) do
        :ok ->
          {:noreply, socket |> load_detail(socket.assigns.account.debit_account_id) |> assign(notice: "Wallet token removed.", notice_kind: :success)}

        {:error, reason} ->
          {:noreply, assign(socket, notice: "Remove failed — #{inspect(reason)}", notice_kind: :error)}
      end
    else
      {:noreply, assign(socket, notice: "Your role cannot remove wallet tokens.", notice_kind: :error)}
    end
  end

  # Card Products UX Parity Phase 1e (2026-07-28) — per-card channel
  # controls, reusing CTA.CardLifecycle.set_channel_controls/2 directly
  # (already card-generic, confirmed unchanged for a debit-issued card).
  def handle_event("open_channels", %{"id" => card_id}, socket) do
    {:noreply, assign(socket, active_action: :card_channels, channels_card_id: card_id, notice: nil)}
  end

  def handle_event("card_channels_save", params, socket) do
    card_id = socket.assigns.channels_card_id

    controls = %{
      ecom_enabled:        tri_parse(params["ecom_enabled"]),
      atm_enabled:         tri_parse(params["atm_enabled"]),
      contactless_enabled: tri_parse(params["contactless_enabled"]),
      intl_enabled:        tri_parse(params["intl_enabled"])
    }

    case CardLifecycle.set_channel_controls(card_id, controls, operator: socket.assigns.current_operator) do
      {:ok, _card} ->
        {:noreply, socket
                    |> load_detail(socket.assigns.account.debit_account_id)
                    |> assign(active_action: :none, notice: "Channel controls updated.", notice_kind: :success)}

      {:error, reason} ->
        {:noreply, assign(socket, notice: "Update failed — #{inspect(reason)}", notice_kind: :error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — data loading
  # ---------------------------------------------------------------------------

  defp load_accounts(socket) do
    search = String.trim(socket.assigns[:search] || "")

    query =
      if search == "" do
        from(d in DebitAccount, order_by: [desc: d.inserted_at])
      else
        from(d in DebitAccount, join: c in Customer, on: c.customer_id == d.customer_id,
          where: ilike(c.first_name, ^"%#{search}%") or ilike(c.last_name, ^"%#{search}%") or
                 ilike(fragment("? || ' ' || ?", c.first_name, c.last_name), ^"%#{search}%"),
          order_by: [desc: d.inserted_at])
      end

    accounts =
      Repo.all(query)
      |> Enum.map(fn account ->
        customer = Repo.get(Customer, account.customer_id)
        Map.put(account, :customer_name, customer && "#{customer.first_name} #{customer.last_name}")
      end)

    assign(socket, accounts: accounts, mode: :list)
  end

  defp load_detail(socket, debit_account_id) do
    account = Repo.get!(DebitAccount, debit_account_id)
    customer = Repo.get(Customer, account.customer_id)
    account = Map.put(account, :customer_name, customer && "#{customer.first_name} #{customer.last_name}")
    cta_cards = Cards.by_debit_account(debit_account_id)

    assign(socket,
      mode: :detail,
      account: account,
      customer: customer,
      active_action: :none,
      notice: nil,
      fundings: Repo.all(from f in DebitFunding, where: f.debit_account_id == ^debit_account_id, order_by: [desc: f.inserted_at]),
      cards: cta_cards,
      nts_tokens: Tokens.list_for_cards(Enum.map(cta_cards, & &1.card_id)),
      adjustments: DebitAdjustmentCommand.list_for(debit_account_id),
      block_history: DebitBlockHistory.history_for(debit_account_id),
      nonmon_events: DebitNonMonetaryEvent.history_for(debit_account_id)
    )
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

  defp money(nil), do: "—"
  defp money(%D{} = d), do: d |> D.round(2) |> D.to_string()
  defp money(v), do: to_string(v)

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(s), do: String.to_integer(s)

  defp tri_parse("true"), do: true
  defp tri_parse("false"), do: false
  defp tri_parse(_), do: nil

  defp tri_selected(nil, ""), do: true
  defp tri_selected(true, "true"), do: true
  defp tri_selected(false, "false"), do: true
  defp tri_selected(_, _), do: false

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

  # ── Non-monetary helpers (Card Products UX Parity Phase 1e, 2026-07-28)
  # — mirrors AccountComponent's build_nonmon_values/apply_nonmon_change
  # exactly, scoped to Debit's smaller event-type set (no cycle/emboss
  # name changes at the account level for Debit).
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

  # ── ASM-P3.1-style 4-eyes identity helpers (Card Products UX Parity
  # Phase 1c, 2026-07-28) — same convention AccountComponent's Temp
  # Limit/Fee Waiver/Financial Adjustment actions already use.
  defp maker_id(socket) do
    case Map.get(socket.assigns, :current_operator) do
      %{username: username} -> username
      _ -> "SYSTEM"
    end
  end

  defp resolve_checker(socket, supervisor_username, amount) do
    case Map.get(socket.assigns, :current_operator) do
      %VmuCore.ASM.Operator{} = maker ->
        VmuCore.ASM.Authz.validate_checker(supervisor_username, maker, "debit", amount)

      _ ->
        {:error, :checker_not_found}
    end
  end

  defp checker_error_msg(:checker_not_found),
    do: "4-eyes: Supervisor username not found or not an active operator."
  defp checker_error_msg(:checker_is_maker),
    do: "4-eyes: You cannot approve your own action — enter a different supervisor."
  defp checker_error_msg(:checker_lacks_permission),
    do: "4-eyes: That operator's role cannot approve debit actions."
  defp checker_error_msg(:checker_exceeds_authority),
    do: "4-eyes: Amount exceeds that supervisor's authority limit."
  defp checker_error_msg(other),
    do: "4-eyes validation failed — #{inspect(other)}"

  defp status_cls("ACTIVE"),    do: "badge-green"
  defp status_cls("SUSPENDED"), do: "badge-yellow"
  defp status_cls("CLOSED"),    do: "badge-gray"
  defp status_cls("DORMANT"),   do: "badge-gray"
  defp status_cls("INACTIVE"),  do: "badge-blue"
  defp status_cls("BLOCKED"),   do: "badge-red"
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
        <.page_header title="Debit Cards" subtitle="Real, network-issued debit accounts (not Prepaid)">
          <:actions>
            <button :if={@can_edit} class="btn-sm btn-primary" phx-click="debit_new" phx-target={@myself}>+ New Account</button>
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
            <tr><th>Customer</th><th>Available Balance</th><th>Currency</th><th>Status</th><th></th></tr>
          </thead>
          <tbody>
            <%= if @accounts == [] do %>
              <tr><td colspan="5" class="empty-row" style="text-align:center;">No debit accounts found.</td></tr>
            <% end %>
            <%= for a <- @accounts do %>
              <tr>
                <td><%= a.customer_name || "—" %></td>
                <td class="mono"><%= money(a.available_balance) %></td>
                <td><%= a.currency %></td>
                <td><span class={"badge #{status_cls(a.status)}"}><%= a.status %></span></td>
                <td><button class="btn btn-xs" phx-click="view_account" phx-value-id={a.debit_account_id} phx-target={@myself}>View</button></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # Card Products UX Parity Phase 1 (2026-07-28) — wizard-based creation:
  # Customer (search existing, same as AccountComponent's wizard step 1 —
  # no more inline-create-a-new-customer, no more hand-typed SYS/BANK IDs)
  # -> Product (Logo/Block cascading dropdowns, same as AccountComponent's
  # wizard step 2) -> Review. No "Card & Credit" step: a Debit account has
  # no credit limit and no card is issued at account-opening time (that's
  # the separate "Issue Card" action once the account exists).
  def render(%{mode: :wizard} = assigns) do
    ~H"""
    <div id={@id} class="component-panel">
      <%= if not @embedded do %>
        <.page_header title="Debit Cards" subtitle="Real, network-issued debit accounts (not Prepaid)">
          <:actions>
            <button class="btn-sm" phx-click="back_to_list" phx-target={@myself}>← Back to list</button>
          </:actions>
        </.page_header>
      <% end %>

      <%= if @notice do %><.alert kind={@notice_kind} message={@notice} /><% end %>

      <div class="card">
        <div style="font-size:16px;font-weight:700;margin-bottom:20px;">Open New Debit Account — Step <%= @wizard_step %> of 3</div>

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
          <% 1 -> %> <%= debit_wizard_step1(assigns) %>
          <% 2 -> %> <%= debit_wizard_step2(assigns) %>
          <% 3 -> %> <%= debit_wizard_step3(assigns) %>
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
        <div style="font-size:16px;font-weight:700;margin-bottom:12px;"><%= @account.customer_name %> — Debit Account</div>
      <% else %>
        <.page_header title={"#{@account.customer_name} — Debit Account"} subtitle="Account detail">
          <:actions>
            <button class="btn-sm" phx-click="back_to_list" phx-target={@myself}>← Back to list</button>
          </:actions>
        </.page_header>
      <% end %>

      <%= if @notice do %><.alert kind={@notice_kind} message={@notice} /><% end %>

      <%!-- Card Products UX Parity Phase 1e (2026-07-28) — account-level
           actions, mirroring Credit's own toolbar exactly (own tables,
           own audit trails — docs/compare/Card_Products_UX_Parity_Tracker.md
           §6). Emboss Name deliberately NOT here: unlike Credit,
           DebitAccount has no emboss_name field of its own — it's a
           per-card property, so that action lives on each card row in
           the Cards tab instead, not this account-level toolbar. --%>
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
              phx-click="debit_kyc" phx-value-status="VERIFIED" phx-target={@myself}>✓ Verify</button>
          <% end %>
          <%= if @account.kyc_status != "REJECTED" do %>
            <button class="btn btn-sm btn-danger" phx-click="debit_kyc" phx-value-status="REJECTED" phx-target={@myself}>✗ Reject</button>
          <% end %>
          <%= if @account.kyc_status != "PENDING" do %>
            <button class="btn btn-sm btn-secondary" phx-click="debit_kyc" phx-value-status="PENDING" phx-target={@myself}>↺ Reset to Pending</button>
          <% end %>
          <span class={"badge #{kyc_badge_cls(@account.kyc_status)}"} style="margin-left:4px;"><%= @account.kyc_status %></span>
        </div>
      </div>

      <%= if @active_action in [:apply_block, :remove_block, :change_address, :change_phone, :change_email, :change_limits] do %>
        <%= debit_action_panel(assigns) %>
      <% end %>

      <div class="card" style="padding:0;overflow:hidden;">
        <div class="detail-tabs">
          <%= for {idx, label, icon} <- [{1, "Overview", "📋"}, {2, "Funding History", "💰"}, {3, "Cards", "💳"}, {4, "Adjustments", "🧾"}, {5, "History", "📜"}] do %>
            <div class={"detail-tab#{if @detail_tab == idx, do: " active"}"}
              phx-click="detail_tab" phx-value-t={idx} phx-target={@myself}>
              <%= icon %> <%= label %>
            </div>
          <% end %>
        </div>
        <div style="padding:20px;">
          <%= case @detail_tab do %>
            <% 1 -> %> <%= debit_tab_overview(assigns) %>
            <% 2 -> %> <%= debit_tab_funding_history(assigns) %>
            <% 3 -> %> <%= debit_tab_cards(assigns) %>
            <% 4 -> %> <%= debit_tab_adjustments(assigns) %>
            <% 5 -> %> <%= debit_tab_history(assigns) %>
            <% _ -> %> <p>Invalid tab.</p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Account-level action panels (Card Products UX Parity Phase 1e, 2026-07-28)
  # ---------------------------------------------------------------------------

  defp debit_action_panel(%{active_action: :apply_block} = assigns) do
    ~H"""
    <div class="action-panel action-panel-danger" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>🔒 Apply Block Code</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <form phx-submit="debit_block_save" phx-target={@myself}>
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
            <input type="text" class="input" name="action[reason_text]" maxlength="200" placeholder="Additional details…"/>
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

  defp debit_action_panel(%{active_action: :remove_block} = assigns) do
    ~H"""
    <div class="action-panel" style="margin-bottom:16px;border-color:#bbf7d0;background:#f0fdf4;">
      <div class="action-panel-title">
        <span>🔓 Remove Block Code <%= @account.block_code %></span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <form phx-submit="debit_unblock_save" phx-target={@myself}>
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
            <input type="text" class="input" name="action[reason_text]" maxlength="200" placeholder="Reason for removing block…"/>
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

  defp debit_action_panel(%{active_action: act} = assigns) when act in [:change_address, :change_phone, :change_email] do
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
      <form phx-submit="debit_nonmon_save" phx-target={@myself}>
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
            <input type="text" class="input" name="action[reason]" placeholder="Call centre ref or reason…"/>
          </div>
          <div class="form-group">
            <label class="form-label">Reference ID (ticket / call ID)</label>
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

  defp debit_action_panel(%{active_action: :change_limits} = assigns) do
    current = assigns.account.velocity_limits || %{}
    pos = Map.get(current, "POS", %{})
    atm = Map.get(current, "ATM", %{})
    assigns = assign(assigns, pos: pos, atm: atm)

    ~H"""
    <div class="action-panel" style="margin-bottom:16px;">
      <div class="action-panel-title">
        <span>📊 Change Transaction/Velocity Limits</span>
        <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
      </div>
      <div class="text-sm text-muted" style="margin-bottom:8px;">
        Stored and admin-editable only in this pass — not yet enforced on
        the live authorization path (see the tracker's Phase 1e scope note).
      </div>
      <form phx-submit="debit_limits_save" phx-target={@myself}>
        <div class="form-grid-2">
          <div class="form-group">
            <label class="form-label">POS Daily Count</label>
            <input type="number" class="input" name="action[pos_daily_count]" value={@pos["daily_count"]} min="0"/>
          </div>
          <div class="form-group">
            <label class="form-label">POS Daily Amount</label>
            <input type="number" class="input" name="action[pos_daily_amount]" value={@pos["daily_amount"]} min="0" step="100"/>
          </div>
          <div class="form-group">
            <label class="form-label">ATM Daily Count</label>
            <input type="number" class="input" name="action[atm_daily_count]" value={@atm["daily_count"]} min="0"/>
          </div>
          <div class="form-group">
            <label class="form-label">ATM Daily Amount</label>
            <input type="number" class="input" name="action[atm_daily_amount]" value={@atm["daily_amount"]} min="0" step="100"/>
          </div>
          <div class="form-group" style="grid-column:1/-1;">
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
  # Detail tab partials (Card Products UX Parity Phase 1b, 2026-07-28)
  # ---------------------------------------------------------------------------

  defp debit_tab_overview(assigns) do
    ~H"""
    <div class="form-pane-section-title" style="display:flex;justify-content:space-between;align-items:center;">
      <span>Balance</span>
      <button :if={@can_edit} class="btn btn-sm btn-primary" phx-click="open_action" phx-value-a="fund_account" phx-target={@myself}>+ Fund Account</button>
    </div>

    <%= if @active_action == :fund_account do %>
      <div class="action-panel" style="margin-bottom:16px;">
        <div class="action-panel-title">
          <span>💰 Fund Debit Account</span>
          <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
        </div>
        <form phx-submit="fund_account_save" phx-target={@myself}>
          <div class="form-grid-2">
            <div class="form-group"><label class="form-label">Amount *</label>
              <input class="input" type="text" name="funding[amount]" placeholder="100.00" required/></div>
            <div class="form-group"><label class="form-label">Channel</label>
              <select class="input" name="funding[channel]">
                <option value="INTERNAL_TRANSFER">Internal Transfer</option>
                <option value="ADMIN_MANUAL">Admin Manual</option>
                <option value="EXTERNAL_BANK_TRANSFER">External Bank Transfer</option>
                <option value="CASH_DEPOSIT">Cash Deposit</option>
              </select></div>
            <div class="form-group"><label class="form-label">Reference (required for external channels)</label>
              <input class="input" type="text" name="funding[external_reference]"/></div>
          </div>
          <div style="display:flex;gap:8px;margin-top:12px;">
            <button type="submit" class="btn btn-primary">Fund</button>
            <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
          </div>
        </form>
      </div>
    <% end %>

    <div class="table-wrap">
      <table class="data-table">
        <tbody>
          <tr><td>Available Balance</td><td class="mono"><%= money(@account.available_balance) %> <%= @account.currency %></td></tr>
          <tr><td>Status</td><td><span class={"badge #{status_cls(@account.status)}"}><%= @account.status %></span></td></tr>
          <tr><td>Opened</td><td><%= @account.opened_at %></td></tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp debit_tab_funding_history(assigns) do
    ~H"""
    <div class="form-pane-section-title">
      Funding History (<%= length(@fundings) %>)
    </div>
    <.ag_grid
      id="debit-funding-history-grid"
      empty_message="No funding yet."
      columns={[
        %{field: "at", header: "Date", width: 160},
        %{field: "amount", header: "Amount", type: "money", width: 130},
        %{field: "channel", header: "Channel", width: 130},
        %{field: "external_reference", header: "Reference", width: 150},
        %{field: "posted_by", header: "By", type: "mono", width: 130}
      ]}
      rows={Enum.map(@fundings, &funding_row/1)}
    />
    """
  end

  defp debit_tab_cards(assigns) do
    ~H"""
    <div class="form-pane-section-title" style="display:flex;justify-content:space-between;align-items:center;">
      <span>Cards (<%= length(@cards) %>)</span>
      <button :if={@can_edit} class="btn btn-sm btn-primary" phx-click="open_action" phx-value-a="issue_card" phx-target={@myself}>+ Issue Card</button>
    </div>

    <%= if @active_action == :issue_card do %>
      <div class="action-panel" style="margin-bottom:16px;">
        <div class="action-panel-title">
          <span>💳 Issue Card</span>
          <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
        </div>
        <form phx-submit="issue_card_save" phx-target={@myself}>
          <div class="form-grid-2">
            <div class="form-group"><label class="form-label">Card Type</label>
              <select class="input" name="card[card_type]">
                <option value="PRIMARY">Primary</option>
                <option value="VIRTUAL">Virtual</option>
                <option value="SUPPLEMENTARY">Supplementary</option>
              </select></div>
          </div>
          <div style="display:flex;gap:8px;margin-top:12px;">
            <button type="submit" class="btn btn-primary">Issue Card</button>
            <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
          </div>
        </form>
      </div>
    <% end %>

    <%= if @active_action == :card_channels do %>
      <% channels_card = Enum.find(@cards, &(&1.card_id == @channels_card_id)) %>
      <% assigns = assign(assigns, :channels_card, channels_card) %>
      <div class="action-panel" style="margin-bottom:16px;">
        <div class="action-panel-title">
          <span>📶 Channel Controls — **** <%= @channels_card && @channels_card.last_four %></span>
          <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
        </div>
        <div class="form-hint" style="margin-bottom:10px;">
          Overrides the product's channel defaults for this card only. "Inherit" restores normal product behavior.
        </div>
        <form phx-submit="card_channels_save" phx-target={@myself}>
          <div class="form-grid-2">
            <div class="form-group">
              <label class="form-label">E-Commerce</label>
              <select class="input" name="ecom_enabled">
                <%= for {label, val} <- @tri_state do %>
                  <option value={val} selected={tri_selected(@channels_card && @channels_card.ecom_enabled, val)}><%= label %></option>
                <% end %>
              </select>
            </div>
            <div class="form-group">
              <label class="form-label">ATM</label>
              <select class="input" name="atm_enabled">
                <%= for {label, val} <- @tri_state do %>
                  <option value={val} selected={tri_selected(@channels_card && @channels_card.atm_enabled, val)}><%= label %></option>
                <% end %>
              </select>
            </div>
            <div class="form-group">
              <label class="form-label">Contactless</label>
              <select class="input" name="contactless_enabled">
                <%= for {label, val} <- @tri_state do %>
                  <option value={val} selected={tri_selected(@channels_card && @channels_card.contactless_enabled, val)}><%= label %></option>
                <% end %>
              </select>
            </div>
            <div class="form-group">
              <label class="form-label">International</label>
              <select class="input" name="intl_enabled">
                <%= for {label, val} <- @tri_state do %>
                  <option value={val} selected={tri_selected(@channels_card && @channels_card.intl_enabled, val)}><%= label %></option>
                <% end %>
              </select>
            </div>
          </div>
          <div style="display:flex;gap:8px;margin-top:12px;">
            <button type="submit" class="btn btn-primary">Save Controls</button>
            <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
          </div>
        </form>
      </div>
    <% end %>

    <div class="table-wrap">
      <table class="data-table">
        <thead><tr><th>PAN (last 4)</th><th>Type</th><th>Status</th><th>Expiry</th><th></th></tr></thead>
        <tbody>
          <%= if @cards == [] do %>
            <tr><td colspan="5" class="empty-row" style="text-align:center;">No cards issued.</td></tr>
          <% end %>
          <%= for c <- @cards do %>
            <tr>
              <td class="mono">•••• <%= c.last_four %></td>
              <td><%= c.card_type %></td>
              <td><span class={"badge #{status_cls(c.status)}"}><%= c.status %></span></td>
              <td><%= c.expiry %></td>
              <td>
                <div :if={@can_edit} style="display:flex;gap:6px;">
                  <button :if={c.status == "INACTIVE"} class="btn btn-xs" phx-click="card_activate" phx-value-id={c.card_id} phx-target={@myself}>Activate</button>
                  <button :if={c.status == "ACTIVE"} class="btn btn-xs" phx-click="card_block" phx-value-id={c.card_id} phx-target={@myself}>Block</button>
                  <button :if={c.status == "BLOCKED"} class="btn btn-xs" phx-click="card_unblock" phx-value-id={c.card_id} phx-target={@myself}>Unblock</button>
                  <button class="btn btn-xs" phx-click="open_channels" phx-value-id={c.card_id} phx-target={@myself}>Channels</button>
                </div>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>

    <.nts_tokens_panel tokens={@nts_tokens} myself={@myself} />
    """
  end

  # Card Products UX Parity Phase 1c (2026-07-28) — Debit's first manual
  # balance-correction capability, 4-eyes approved (same
  # ASM.Authz.validate_checker/4 pattern Credit's Temp Limit/Fee Waiver/
  # Financial Adjustment already use). CREDIT increases available_balance,
  # DEBIT decreases it — real banking terminology for a deposit/asset
  # account (the opposite polarity from Credit's card-side adjustment).
  defp debit_tab_adjustments(assigns) do
    ~H"""
    <div class="form-pane-section-title" style="display:flex;justify-content:space-between;align-items:center;">
      <span>Adjustments (<%= length(@adjustments) %>)</span>
      <button :if={@can_edit} class="btn btn-sm btn-primary" phx-click="open_action" phx-value-a="adjustment" phx-target={@myself}>+ New Adjustment</button>
    </div>

    <%= if @active_action == :adjustment do %>
      <div class="action-panel" style="margin-bottom:16px;">
        <div class="action-panel-title">
          <span>🧾 New Adjustment (4-eyes)</span>
          <button class="btn btn-sm btn-ghost" phx-click="action_close" phx-target={@myself}>✕ Close</button>
        </div>
        <form phx-submit="debit_adjustment_save" phx-target={@myself}>
          <div class="form-grid-2">
            <div class="form-group"><label class="form-label">Direction *</label>
              <select class="input" name="adjustment[direction]" required>
                <option value="CREDIT">Credit (increase balance)</option>
                <option value="DEBIT">Debit (decrease balance)</option>
              </select></div>
            <div class="form-group"><label class="form-label">Amount *</label>
              <input class="input" type="text" name="adjustment[amount]" placeholder="50.00" required/></div>
            <div class="form-group"><label class="form-label">Reason *</label>
              <input class="input" type="text" name="adjustment[reason]" maxlength="100" required/></div>
            <div class="form-group"><label class="form-label">Reference ID *</label>
              <input class="input" type="text" name="adjustment[reference_id]" placeholder="CAS-1234" required/></div>
            <div class="form-group"><label class="form-label">Approving Supervisor (username) *</label>
              <input class="input" type="text" name="adjustment[supervisor_id]" required/></div>
          </div>
          <div style="display:flex;gap:8px;margin-top:12px;">
            <button type="submit" class="btn btn-primary">Post Adjustment</button>
            <button type="button" class="btn btn-ghost" phx-click="action_close" phx-target={@myself}>Cancel</button>
          </div>
        </form>
      </div>
    <% end %>

    <.ag_grid
      id="debit-adjustments-grid"
      empty_message="No adjustments posted."
      columns={[
        %{field: "at", header: "Date", width: 160},
        %{field: "direction", header: "Direction", type: "badge", classField: "direction_class", width: 110},
        %{field: "amount", header: "Amount", type: "money", width: 130},
        %{field: "reason", header: "Reason", flex: 1},
        %{field: "reference_id", header: "Reference", width: 150},
        %{field: "maker_checker", header: "Maker / Checker", type: "mono", width: 220}
      ]}
      rows={Enum.map(@adjustments, &adjustment_row/1)}
    />
    """
  end

  # Card Products UX Parity Phase 1e (2026-07-28) — combined account-level
  # audit trail: block/unblock actions and non-monetary maintenance events,
  # merged and sorted, mirroring Credit's own History tab shape.
  defp debit_tab_history(assigns) do
    entries =
      (Enum.map(assigns.block_history, fn h ->
         %{
           at: h.applied_at,
           kind: h.action,
           detail: "#{h.block_code || "—"} — #{h.reason_code}#{if h.reason_text, do: ": #{h.reason_text}", else: ""}",
           operator: h.operator_id
         }
       end) ++
         Enum.map(assigns.nonmon_events, fn e ->
           %{
             at: e.applied_at,
             kind: String.upcase(e.event_type),
             detail: e.reason || "—",
             operator: e.operator_id
           }
         end))
      |> Enum.sort_by(& &1.at, {:desc, NaiveDateTime})

    assigns = assign(assigns, :entries, entries)

    ~H"""
    <div class="form-pane-section-title">Account History (<%= length(@entries) %>)</div>
    <.ag_grid
      id="debit-account-history-grid"
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
  # Wizard step partials (Card Products UX Parity Phase 1, 2026-07-28)
  # ---------------------------------------------------------------------------

  defp debit_wizard_step1(assigns) do
    ~H"""
    <div>
      <div class="form-pane-section-title">Step 1 — Select Customer</div>

      <%= if @form_data["customer_id"] do %>
        <div style="background:#f0fdf4;border:1px solid #bbf7d0;padding:12px 16px;border-radius:8px;margin-bottom:16px;display:flex;justify-content:space-between;align-items:center;">
          <div>
            <div style="font-weight:600;"><%= @form_data["customer_name"] %></div>
            <div style="font-size:12px;color:var(--text-secondary);">
              Bank: <%= @form_data["bank_id"] %> · KYC: <%= @form_data["kyc_status"] %>
            </div>
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
              <thead><tr><th>Name</th><th>Email</th><th>Bank</th><th>KYC</th><th></th></tr></thead>
              <tbody>
                <%= for c <- @customer_results do %>
                  <tr>
                    <td><%= c.first_name %> <%= c.last_name %></td>
                    <td style="font-size:12px;"><%= c.email %></td>
                    <td><%= c.bank_id %></td>
                    <td><span class={"badge #{if c.kyc_status == "VERIFIED", do: "badge-green", else: "badge-yellow"}"}><%= c.kyc_status %></span></td>
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

  defp debit_wizard_step2(assigns) do
    ~H"""
    <div>
      <div class="form-pane-section-title">Step 2 — Select Product (LOGO + BLOCK)</div>
      <form phx-change="wizard_change" phx-target={@myself}>
        <div class="form-grid-2">
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

  defp debit_wizard_step3(assigns) do
    ~H"""
    <div>
      <div class="form-pane-section-title">Step 3 — Review</div>
      <.kv_detail rows={[
        {"Customer", @form_data["customer_name"]},
        {"Bank", @form_data["bank_id"]},
        {"Logo (Product)", @form_data["logo_id"]},
        {"Block (Sub-product)", @form_data["block_id"] || "DFLT"}
      ]}/>
      <div style="display:flex;gap:8px;margin-top:20px;">
        <button class="btn btn-secondary" phx-click="wizard_step" phx-value-s="2" phx-target={@myself}>← Back</button>
        <button class="btn btn-primary" phx-click="wizard_save" phx-target={@myself}>Open Account</button>
      </div>
    </div>
    """
  end

  defp funding_row(f) do
    %{
      at: Calendar.strftime(f.inserted_at, "%Y-%m-%d %H:%M"),
      amount: f.amount,
      channel: f.channel,
      external_reference: f.external_reference || "—",
      posted_by: f.posted_by
    }
  end

  defp adjustment_row(a) do
    %{
      at: Calendar.strftime(a.inserted_at, "%Y-%m-%d %H:%M"),
      direction: a.direction,
      direction_class: if(a.direction == "CREDIT", do: "badge-green", else: "badge-red"),
      amount: a.amount,
      reason: a.reason,
      reference_id: a.reference_id,
      maker_checker: "#{a.operator_id} / #{a.supervisor_id}"
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
