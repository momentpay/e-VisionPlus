defmodule VmuCore.Repo do
  use Ecto.Repo,
    otp_app: :vmu_core,
    adapter: Ecto.Adapters.Postgres
end
