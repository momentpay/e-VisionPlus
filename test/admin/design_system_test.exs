defmodule VmuCoreWeb.DesignSystemTest do
  @moduledoc """
  Guards the contract between the admin screens and the stylesheet.

  This exists because of a real, wide failure. An audit of every
  `class="…"` in `lib/vmu_core_web` against `priv/static/assets/admin.css`
  found **44 distinct class names the screens used that the stylesheet never
  defined** — `.input` (283 uses), `.form-group` (294), `.form-label` (268),
  `.btn-ghost` (109), `.table-wrap` (48), `.admin-table` (7) and more.

  Nothing errored. The markup was correct, the CSS for it simply did not
  exist, so forms rendered as raw browser controls, tables sat unframed on
  the canvas and whole columns of buttons had no button styling. It was
  invisible to every test in the suite and obvious in the first screenshot.

  A missing class cannot warn at compile time, so it has to be asserted.
  """
  use ExUnit.Case, async: true

  @css_path Path.join([File.cwd!(), "priv", "static", "assets", "admin.css"])
  @source_root Path.join([File.cwd!(), "lib", "vmu_core_web"])

  # Fragments and foreign namespaces that are legitimately absent from
  # admin.css. Anything added here needs a reason alongside it.
  @allowed [
    # The operator sign-in page is a standalone document with its own inline
    # <style> block — it never loads admin.css.
    "login-wrap",
    "login-card",
    "login-error",
    "login-alt",
    "tag",
    # Interpolated class names (`class={"badge badge-#{kind}"}`) leave a
    # dangling prefix once the interpolation is stripped.
    "badge-",
    "alert-"
  ]

  defp defined_classes do
    @css_path
    |> File.read!()
    |> then(&Regex.scan(~r/\.([A-Za-z][A-Za-z0-9_-]*)/, &1))
    |> MapSet.new(fn [_, name] -> name end)
  end

  defp used_classes do
    Path.wildcard(Path.join(@source_root, "**/*.ex"))
    |> Enum.flat_map(fn file ->
      source = File.read!(file)

      # `class="a b c"` and the literal head of `class={"a b #{…}"}`.
      literal = Regex.scan(~r/class="([^"{}]*)"/, source)
      interpolated = Regex.scan(~r/class=\{"([^"\#{}]*)/, source)

      (literal ++ interpolated)
      |> Enum.flat_map(fn [_, raw] -> String.split(raw, ~r/\s+/, trim: true) end)
      |> Enum.map(&{&1, Path.basename(file)})
    end)
  end

  test "every class the screens use is defined in the stylesheet" do
    defined = defined_classes()

    missing =
      used_classes()
      |> Enum.reject(fn {class, _file} -> class in @allowed end)
      |> Enum.reject(fn {class, _file} -> MapSet.member?(defined, class) end)
      |> Enum.group_by(fn {class, _} -> class end, fn {_, file} -> file end)
      |> Enum.map(fn {class, files} -> "  .#{class} — #{files |> Enum.uniq() |> Enum.join(", ")}" end)
      |> Enum.sort()

    assert missing == [],
           "these classes are used by screens but defined nowhere in admin.css, " <>
             "so the markup renders unstyled:\n" <> Enum.join(missing, "\n")
  end

  test "the stylesheet defines both themes for every semantic token" do
    css = File.read!(@css_path)

    [light] = Regex.run(~r/^:root \{(.*?)^\}/ms, css, capture: :all_but_first)
    [dark] = Regex.run(~r/^\[data-theme="dark"\] \{(.*?)^\}/ms, css, capture: :all_but_first)

    token = fn block ->
      ~r/^\s*(--[a-z0-9-]+):/m
      |> Regex.scan(block)
      |> MapSet.new(fn [_, name] -> name end)
    end

    light_tokens = token.(light)
    dark_tokens = token.(dark)

    # Aliases and geometry are theme-independent by design; only the tokens
    # that carry colour have to be restated for dark.
    colour_like =
      light_tokens
      |> Enum.filter(&String.match?(&1, ~r/^--(bg|text|border|accent|success|warning|danger|info|shadow|dock-inset)/))
      |> Enum.reject(&(&1 in ~w(--bg-canvas --bg-card --text-primary --text-secondary --border-dark --accent-light)))
      |> MapSet.new()

    missing = MapSet.difference(colour_like, dark_tokens) |> MapSet.to_list() |> Enum.sort()

    assert missing == [],
           "defined for light but never redefined for dark, so they keep their " <>
             "light value on a dark ground: #{inspect(missing)}"
  end

  test "component styles carry no hardcoded colours outside the token blocks" do
    css = File.read!(@css_path)

    # Everything after the accent palette is component styling; colour there
    # must come from a token, or it will not theme.
    [_tokens, components] = String.split(css, "/* ── Base ──", parts: 2)

    offenders =
      ~r/^\s*(?:color|background(?:-color)?|border(?:-[a-z]+)?)\s*:\s*[^;]*#[0-9a-fA-F]{3,8}/m
      |> Regex.scan(components)
      |> Enum.map(fn [line | _] -> String.trim(line) end)
      # White text on a filled accent/status button is correct in both themes.
      |> Enum.reject(&String.match?(&1, ~r/#fff\b|#ffffff\b/))
      |> Enum.uniq()

    assert offenders == [],
           "hardcoded colours in component styles will not theme:\n  " <>
             Enum.join(offenders, "\n  ")
  end
end
