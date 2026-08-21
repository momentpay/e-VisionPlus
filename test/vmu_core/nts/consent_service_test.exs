defmodule VmuCore.NTS.ConsentServiceTest do
  @moduledoc "NTS Phase F5 (2026-08-02) — honest-stub coverage, no DB needed."

  use ExUnit.Case, async: true

  alias VmuCore.NTS.{ConsentService, PushProvisioningSession}

  test "notify_activation_code_required/2 always fails honestly — no Consent Service spec available" do
    session = %PushProvisioningSession{session_id: Ecto.UUID.generate(), status: "AUTH_REQUIRED"}
    assert {:error, :consent_service_spec_not_available} = ConsentService.notify_activation_code_required(session, "123456")
  end
end
