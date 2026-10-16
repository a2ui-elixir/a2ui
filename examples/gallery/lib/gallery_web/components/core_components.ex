defmodule GalleryWeb.CoreComponents do
  @moduledoc "Small building blocks of the gallery's own pages."

  use Phoenix.Component

  @doc "A message log: what went to and came from the agent, newest first."
  attr :entries, :list, required: true
  attr :id, :string, required: true

  def message_log(assigns) do
    ~H"""
    <ol id={@id} class="log">
      <li :for={entry <- @entries} class={["log-entry", entry.direction]}>
        <div class="log-head">
          <span class="arrow">{arrow(entry.direction)}</span>
          <span class="kind">{entry.kind}</span>
          <span :if={entry[:note]} class="note">{entry.note}</span>
        </div>
        <pre :if={entry[:json]}>{entry.json}</pre>
      </li>
    </ol>
    """
  end

  defp arrow(:in), do: "agent → renderer"
  defp arrow(:out), do: "renderer → agent"
  defp arrow(:effect), do: "renderer"
  defp arrow(:user), do: "user"

  @doc "Pretty JSON for display."
  def pretty(value), do: Jason.encode!(value, pretty: true)
end
