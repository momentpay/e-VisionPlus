defmodule VmuCoreWeb.ErrorHTML do
  use Phoenix.Component

  def render("404.html", assigns) do
    ~H"""
    <h1>404 — Page not found</h1>
    <p><a href="/dashboard">Go to Dashboard</a></p>
    """
  end

  def render("500.html", assigns) do
    ~H"""
    <h1>500 — Server error</h1>
    <p><a href="/dashboard">Go to Dashboard</a></p>
    """
  end

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
