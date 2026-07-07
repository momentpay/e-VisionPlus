# ASM-P1.5 — Seed the initial ADMIN operator.
#
#   mix run priv/repo/seed_operators.exs
#
# Credentials come from env so nothing secret lands in the repo:
#   VMU_ADMIN_USERNAME (default "admin")
#   VMU_ADMIN_PASSWORD (default "ChangeMe#2026" — CHANGE AT FIRST LOGIN)
#
# Idempotent: skips if the username already exists.

alias VmuCore.{Repo, ASM.Auth, ASM.Operator}

username = System.get_env("VMU_ADMIN_USERNAME", "admin")
password = System.get_env("VMU_ADMIN_PASSWORD", "ChangeMe#2026")

case Repo.get_by(Operator, username: username) do
  %Operator{} ->
    IO.puts("Operator '#{username}' already exists — skipped.")

  nil ->
    case Auth.create_operator(%{
           username: username,
           display_name: "System Administrator",
           password: password,
           role: "ADMIN"
         }) do
      {:ok, op} ->
        IO.puts("Created ADMIN operator '#{op.username}' (#{op.operator_id}).")
        IO.puts("⚠  Change the default password immediately after first login.")

      {:error, reason} ->
        IO.puts("Failed to create operator: #{inspect(reason)}")
        System.halt(1)
    end
end
