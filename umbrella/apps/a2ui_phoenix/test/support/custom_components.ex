defmodule A2UIPhoenix.Test.CustomComponents do
  @moduledoc false
  # Components a host could bring to replace a basic one, and a markdown
  # renderer.

  use Phoenix.Component

  def map(names), do: Map.take(%{"Text" => &custom_text/1}, names)

  def markdown(text), do: Phoenix.HTML.raw("<p class=\"md\">" <> text <> "</p>")

  def custom_text(assigns) do
    ~H"""
    <p class="custom-text" {@attrs}>{@props["text"]}</p>
    """
  end
end
