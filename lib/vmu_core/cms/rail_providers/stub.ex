defmodule VmuCore.CMS.RailProviders.Stub do
  @moduledoc """
  The default `CMS.RailProvider` — no real bank/aggregator is configured
  yet (Digital Wallet W011/W012 stay blocked on that vendor decision).
  Deliberately always declines rather than faking a success, so a caller
  never mistakes "no rail wired up" for "the payment actually moved."
  """

  @behaviour VmuCore.CMS.RailProvider

  @impl true
  def initiate(_payment), do: {:error, :rail_not_configured}

  @impl true
  def check_status(_payment), do: {:error, :rail_not_configured}
end
