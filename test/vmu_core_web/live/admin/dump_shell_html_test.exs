defmodule VmuCoreWeb.Live.Admin.DumpShellHtmlTest do
  @moduledoc """
  Not an assertion test — a development utility that writes the admin shell's
  real rendered HTML to disk so the markup and stylesheet can be reviewed in a
  browser without booting the whole app and signing in.

  Tagged `:dump` and excluded from the default run (see test_helper.exs). Run
  it deliberately:

      mix test --only dump

  Output goes to `tmp/shell-dump/`, which is gitignored.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}

  @endpoint VmuCoreWeb.Endpoint
  @outdir Path.join([File.cwd!(), "tmp", "shell-dump"])

  @moduletag :dump

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Authz.seed_default_matrix()
    Authz.refresh()
    File.mkdir_p!(@outdir)
    :ok
  end

  test "dump the shell for a few representative screens" do
    operator =
      %Operator{}
      |> Operator.changeset(%{
        username: "shell_dump_#{System.unique_integer([:positive])}",
        display_name: "Amina Kowalski",
        pw_hash: "x",
        pw_salt: "x",
        role: "ADMIN",
        status: "ACTIVE"
      })
      |> Repo.insert!()

    conn =
      build_conn()
      |> init_test_session(%{
        "operator_id" => operator.operator_id,
        "logged_in_at" => System.os_time(:second)
      })

    for {name, path} <- [
          {"finance-gl", "/visionplus/admin/gl"},
          {"party-customer", "/visionplus/admin/customer"},
          {"loyalty-placeholder", "/visionplus/admin/loyalty"}
        ] do
      {:ok, _view, html} = live(conn, path)
      File.write!(Path.join(@outdir, name <> ".html"), html)
    end

    File.cp!(
      Path.join([File.cwd!(), "priv", "static", "assets", "admin.css"]),
      Path.join(@outdir, "admin.css")
    )

    IO.puts("\nShell HTML written to #{@outdir}")
    assert File.exists?(Path.join(@outdir, "finance-gl.html"))
  end
end
