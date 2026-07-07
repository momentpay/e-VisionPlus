# ASM-P2.1 — Seed the default role → permission matrix.
#
#   mix run priv/repo/seed_role_permissions.exs
#
# Idempotent (on_conflict: :nothing). ADMIN gets no rows — it is a code
# short-circuit in VmuCore.ASM.Authz, which also makes the "operators"
# module ADMIN-only (no role rows grant it).

count = VmuCore.ASM.Authz.seed_default_matrix()
IO.puts("Role permission matrix seeded: #{count} new grant(s) inserted.")
