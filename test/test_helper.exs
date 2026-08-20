# :dump tags are development utilities that write artefacts to tmp/ rather
# than asserting anything — run them deliberately with `mix test --only dump`.
ExUnit.start(exclude: [:dump])

Ecto.Adapters.SQL.Sandbox.mode(VmuCore.Repo, :manual)
