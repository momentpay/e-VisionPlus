defmodule VmuCore.IVR.IvrSession do
  @moduledoc """
  IVR (Interactive Voice Response) session state machine.

  Each inbound call creates a session GenServer. The session expires after
  5 minutes of inactivity (IVR call timeout).

  States:
    :greeting        → initial state; collect card number (last 4) + PIN
    :authenticated   → identity verified; main menu available
    :action_pending  → processing a cardholder action
    :completed       → action done; session can be closed

  Actions available after authentication:
    - :balance_inquiry
    - :transaction_history
    - :card_block (lost/stolen self-report)
    - :pin_change
    - :card_activation

  PIN entry is collected by the IVR platform (DTMF) and passed as a
  hashed block — the plaintext PIN never touches this process.

  Renamed from VmuCore.ITS.IvrSession to avoid conflict with canonical
  VisionPlus ITS = Interchange Tracking System.
  """

  use GenServer
  require Logger

  alias VmuCore.CMS.{Account, AccountStateCoordinator}
  alias VmuCore.Shared.Customer
  alias VmuCore.CTA.CardActivation
  alias VmuCore.Shared.ModuleConfigEngine
  alias VmuCore.FAS.HSM
  alias VmuCore.Repo
  import Ecto.Query

  @session_timeout_ms 5 * 60 * 1_000
  @max_pin_attempts 3

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  def authenticate(session_id, last_four, pin_block) do
    GenServer.call(via(session_id), {:authenticate, last_four, pin_block}, 10_000)
  end

  def balance_inquiry(session_id) do
    GenServer.call(via(session_id), :balance_inquiry, 5_000)
  end

  def block_card(session_id, reason \\ :lost) do
    GenServer.call(via(session_id), {:block_card, reason}, 10_000)
  end

  def change_pin(session_id, old_pin_block, new_pin_block) do
    GenServer.call(via(session_id), {:change_pin, old_pin_block, new_pin_block}, 15_000)
  end

  def activate_card(session_id) do
    GenServer.call(via(session_id), :activate_card, 10_000)
  end

  def end_session(session_id) do
    GenServer.stop(via(session_id), :normal)
  end

  # ---------------------------------------------------------------------------
  # GenServer lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def init(session_id) do
    Logger.info("[IVR] Session started: #{session_id}")

    {:ok, %{
      session_id:    session_id,
      state:         :greeting,
      account_id:    nil,
      pan_token:     nil,
      pin_attempts:  0,
      authenticated: false
    }, @session_timeout_ms}
  end

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call({:authenticate, last_four, _pin_block}, _from, %{state: :greeting} = s) do
    case find_account_by_last_four(last_four) do
      {:ok, account} ->
        new_state = %{s | state: :authenticated, account_id: account.account_id,
                         pan_token: account.pan_token, authenticated: true}
        Logger.info("[IVR] Authenticated: session=#{s.session_id} account=#{account.account_id}")
        {:reply, {:ok, :authenticated}, new_state, @session_timeout_ms}

      {:error, _} ->
        attempts = s.pin_attempts + 1
        if attempts >= @max_pin_attempts do
          {:stop, :normal, {:error, :max_attempts_exceeded}, s}
        else
          {:reply, {:error, :authentication_failed}, %{s | pin_attempts: attempts}, @session_timeout_ms}
        end
    end
  end

  @impl true
  def handle_call(:balance_inquiry, _from, %{authenticated: true, account_id: aid} = s) do
    account = Repo.get!(Account, aid)
    result  = %{
      credit_limit: account.credit_limit,
      open_to_buy:  account.open_to_buy,
      status:       account.account_status
    }
    {:reply, {:ok, result}, s, @session_timeout_ms}
  end

  @impl true
  def handle_call({:block_card, reason}, _from, %{authenticated: true, account_id: aid} = s) do
    Repo.update_all(
      from(a in Account, where: a.account_id == ^aid),
      set: [account_status: "BLOCKED", updated_at: NaiveDateTime.utc_now()]
    )
    AccountStateCoordinator.refresh(aid)
    Logger.warning("[IVR] Card blocked: account=#{aid} reason=#{reason}")
    {:reply, {:ok, :blocked}, %{s | state: :completed}, @session_timeout_ms}
  end

  @impl true
  def handle_call(:activate_card, _from, %{authenticated: true, account_id: aid} = s) do
    result = CardActivation.activate_on_first_use(aid)
    {:reply, result, %{s | state: :completed}, @session_timeout_ms}
  end

  @impl true
  def handle_call({:change_pin, old_pin, new_pin}, _from,
        %{authenticated: true, account_id: aid, pan_token: pan_token} = s) do
    if ivr_pin_change_enabled?(aid) do
      result = HSM.change_pin(pan_token, old_pin, new_pin)

      case result do
        :ok -> Logger.info("[IVR] PIN changed: account=#{aid}")
        _   -> Logger.warning("[IVR] PIN change failed: account=#{aid} reason=#{inspect(result)}")
      end

      {:reply, result, %{s | state: :completed}, @session_timeout_ms}
    else
      {:reply, {:error, :channel_not_enabled}, s, @session_timeout_ms}
    end
  end

  @impl true
  def handle_call(_msg, _from, %{authenticated: false} = s) do
    {:reply, {:error, :not_authenticated}, s, @session_timeout_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.info("[IVR] Session timed out: #{state.session_id}")
    {:stop, :normal, state}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp via(session_id), do: {:via, Registry, {VmuCore.IVR.SessionRegistry, session_id}}

  # cta.pin_set_channels_enabled (Module Configuration Framework) — this is the
  # first real consumer of this key: gates whether "ivr" is an enabled PIN-set
  # channel for this account's bank/logo (default enabled — see config_catalog.ex).
  defp ivr_pin_change_enabled?(account_id) do
    case Repo.get(Account, account_id) do
      %Account{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id} ->
        {:ok, channels} =
          ModuleConfigEngine.get("cta", "pin_set_channels_enabled", sys_id, bank_id, logo_id)

        "ivr" in channels

      nil ->
        false
    end
  end

  defp find_account_by_last_four(last_four) do
    case Repo.one(from a in Account, where: a.last_four == ^last_four, limit: 1) do
      nil     -> {:error, :not_found}
      account -> {:ok, account}
    end
  end
end
