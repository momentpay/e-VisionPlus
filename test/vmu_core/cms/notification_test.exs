defmodule VmuCore.CMS.NotificationTest do
  @moduledoc """
  Real Postgres via Sandbox; outbound HTTP faked via `Req.Test` (a real
  Plug pipeline, not a mock) — see `NotificationDispatcher.HttpGateway`'s
  moduledoc and `config/test.exs`'s `:notification_http_plug` setting.
  Same fixture pattern as `PurchasePostingTest`/`PaymentAllocationTest`.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{Account, Notification, NotificationLog}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter,
                        ModuleConfigWriter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp parameter_hierarchy_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()

    %BankParameter{}
    |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"})
    |> Repo.insert!()

    %LogoParameter{}
    |> LogoParameter.changeset(%{
      sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test"
    })
    |> Repo.insert!()

    %BlockParameter{}
    |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id})
    |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  defp account_fixture(customer_attrs \\ %{}) do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(Map.merge(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Notif", last_name: "Test#{n}",
        id_type: "PASSPORT", id_number: "NOTIF-TEST-#{n}",
        email: "notif-test-#{n}@example.com", mobile_country: "+1", mobile_number: "5550#{n}"
      }, customer_attrs))
      |> Repo.insert!()

    %Account{}
    |> Account.changeset(%{
      customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
      block_id: block_id, pan_token: "notif-test-pan-#{n}", last_four: "9999",
      expiry_date: "1230", credit_limit: D.new("10000.00")
    })
    |> Repo.insert!()
  end

  defp enable_channels(account, channels) do
    ModuleConfigWriter.put(
      "cms", "notification_channels_enabled", channels,
      %{scope_type: "bank", sys_id: account.sys_id, bank_id: account.bank_id}, nil
    )
  end

  defp set_gateway_config(account, config) do
    ModuleConfigWriter.put(
      "cms", "notification_gateway_config", config,
      %{scope_type: "bank", sys_id: account.sys_id, bank_id: account.bank_id}, nil
    )
  end

  defp payment_details(reference) do
    %{amount: D.new("100.00"), allocated: D.new("100.00"), remainder: D.new("0.00"),
      payment_channel: "gateway", reference: reference}
  end

  describe "notify_payment_receipt/2" do
    test "no channels enabled — no-op, no rows written" do
      account = account_fixture()
      assert :ok = Notification.notify_payment_receipt(account, payment_details("ref-#{System.unique_integer([:positive])}"))
      assert Notification.list_for_account(account.account_id) == []
    end

    test "dispatches to an enabled, configured channel and logs SENT" do
      account = account_fixture()
      enable_channels(account, ["email"])
      set_gateway_config(account, %{"email" => %{"url" => "https://gw.test/email", "headers" => %{"Authorization" => "Bearer tok"}}})

      test_pid = self()

      Req.Test.stub(VmuCore.CMS.NotificationDispatcher.HttpGateway, fn conn ->
        send(test_pid, {:gateway_hit, conn.request_path, conn.body_params})
        Req.Test.json(conn, %{"status" => "queued"})
      end)

      ref = "ref-#{System.unique_integer([:positive])}"
      assert :ok = Notification.notify_payment_receipt(account, payment_details(ref))

      assert_receive {:gateway_hit, "/email", body}
      assert body["channel"] == "email"
      assert body["content_format"] == "text"
      assert body["reference"] == ref
      assert body["recipient"] =~ "@example.com"

      [log] = Notification.list_for_account(account.account_id)
      assert log.status == "SENT"
      assert log.channel == "email"
      assert log.response["status"] == "queued"
    end

    test "fans out to every enabled channel independently" do
      account = account_fixture()
      enable_channels(account, ["email", "sms", "webhook"])

      set_gateway_config(account, %{
        "email"   => %{"url" => "https://gw.test/email"},
        "sms"     => %{"url" => "https://gw.test/sms"},
        "webhook" => %{"url" => "https://gw.test/webhook"}
      })

      Req.Test.stub(VmuCore.CMS.NotificationDispatcher.HttpGateway, fn conn ->
        Req.Test.json(conn, %{"status" => "queued"})
      end)

      ref = "ref-#{System.unique_integer([:positive])}"
      assert :ok = Notification.notify_payment_receipt(account, payment_details(ref))

      logs = Notification.list_for_account(account.account_id)
      assert length(logs) == 3
      assert Enum.all?(logs, &(&1.status == "SENT"))

      webhook_log = Enum.find(logs, &(&1.channel == "webhook"))
      assert webhook_log.content_format == "json"
      assert {:ok, decoded} = Jason.decode(webhook_log.content)
      assert decoded["event"] == "payment_receipt"

      sms_log = Enum.find(logs, &(&1.channel == "sms"))
      assert sms_log.content_format == "text"
    end

    test "an enabled channel with no gateway config is SKIPPED, not FAILED" do
      account = account_fixture()
      enable_channels(account, ["whatsapp"])
      # notification_gateway_config left at its default (%{}) — no "whatsapp" key

      ref = "ref-#{System.unique_integer([:positive])}"
      assert :ok = Notification.notify_payment_receipt(account, payment_details(ref))

      [log] = Notification.list_for_account(account.account_id)
      assert log.status == "SKIPPED"
      assert log.response["reason"] == "not_configured"
    end

    test "a non-2xx gateway response is logged FAILED, never raises" do
      account = account_fixture()
      enable_channels(account, ["sms"])
      set_gateway_config(account, %{"sms" => %{"url" => "https://gw.test/sms"}})

      Req.Test.stub(VmuCore.CMS.NotificationDispatcher.HttpGateway, fn conn ->
        conn |> Plug.Conn.send_resp(500, "boom")
      end)

      ref = "ref-#{System.unique_integer([:positive])}"
      assert :ok = Notification.notify_payment_receipt(account, payment_details(ref))

      [log] = Notification.list_for_account(account.account_id)
      assert log.status == "FAILED"
    end

    test "is idempotent on the same reference+channel — second call does not re-dispatch" do
      account = account_fixture()
      enable_channels(account, ["email"])
      set_gateway_config(account, %{"email" => %{"url" => "https://gw.test/email"}})

      test_pid = self()

      Req.Test.stub(VmuCore.CMS.NotificationDispatcher.HttpGateway, fn conn ->
        send(test_pid, :gateway_hit)
        Req.Test.json(conn, %{"status" => "queued"})
      end)

      ref = "ref-#{System.unique_integer([:positive])}"
      details = payment_details(ref)

      assert :ok = Notification.notify_payment_receipt(account, details)
      assert :ok = Notification.notify_payment_receipt(account, details)

      assert_receive :gateway_hit
      refute_receive :gateway_hit, 100

      assert Repo.aggregate(NotificationLog, :count) == 1
    end
  end
end
