defmodule SiteWeb.PageHTML do
  @moduledoc "The landing page (`page_html/home.html.heex`) and what it computes from `Site.Content`."
  use SiteWeb, :html

  alias Site.Content
  alias SiteWeb.Code

  embed_templates "page_html/*"

  @doc "The page's sections, for the navigation: `{label, id}`."
  def nav_links do
    [
      {"Architecture", "architecture"},
      {"Features", "features"},
      {"Catalog", "catalog"},
      {"Transports", "transports"},
      {"Code", "code"},
      {"Examples", "examples"},
      {"Conformance", "conformance"}
    ]
  end

  @doc "The hero message, a highlighted line at a time, with each line's index."
  def hero_lines do
    hero_message_lines()
    |> Enum.with_index(fn line, index -> {Code.highlight(line, :json), index} end)
  end

  @doc "How many lines the hero message has."
  def hero_line_count, do: length(hero_message_lines())

  @doc "How many components, bindings and actions the hero message holds."
  def hero_counts do
    message = Content.hero_message()

    %{
      components: count_of(message, ~s("component":)),
      bindings: count_of(message, ~s("@path":)),
      actions: count_of(message, ~s("action":))
    }
  end

  defp count_of(text, pattern), do: length(String.split(text, pattern)) - 1

  defp hero_message_lines,
    do: Content.hero_message() |> String.trim_trailing() |> String.split("\n")

  @doc "The package called `name`."
  def package(name), do: Enum.find(Content.packages(), &(&1.name == name))

  @doc "`number` as two digits."
  def pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc "Whether `message` exists in protocol `version`."
  def supports?(%{since: since}, version), do: rank(version) >= rank(since)

  defp rank("v0.9"), do: 0
  defp rank("v0.9.1"), do: 1
  defp rank("v1.0"), do: 2

  @doc "A module name that may break after each dot."
  def breakable(module) do
    module
    |> String.split(".")
    |> Enum.map(&(&1 |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()))
    |> Enum.join(".<wbr>")
    |> Phoenix.HTML.raw()
  end

  @doc "The resolved component tree of the hero's surface: depth, type, id and what it shows."
  def hero_tree do
    [
      {0, "Card", "root", nil},
      {1, "Column", "form", nil},
      {2, "Text", "title", ~s("Trattoria Roma")},
      {2, "TextField", "name", "⇄ /booking/name"},
      {2, "DateTimeInput", "when", "⇄ /booking/date"},
      {2, "Button", "book", "→ action book"}
    ]
  end

  @doc "The basic catalog's components, each with its kind."
  def components_flat,
    do: for({kind, names} <- Content.components(), name <- names, do: {kind, name})

  @doc "The suites' totals: cases, cases run and cases skipped."
  def suite_totals do
    total = Content.suites() |> Enum.map(& &1.total) |> Enum.sum()
    run = Content.suites() |> Enum.map(& &1.run) |> Enum.sum()
    %{total: total, run: run, skipped: total - run}
  end

  @doc "The share of a suite's cases that run, as a CSS length."
  def run_share(%{run: run, total: total}), do: "#{Float.round(run * 100 / total, 2)}%"

  @doc "How many items a list of `{kind, items}` groups holds."
  def count(groups), do: groups |> Enum.map(fn {_kind, items} -> length(items) end) |> Enum.sum()

  @doc "The rejected component of the validation example, its faulty value marked."
  def error_sent do
    Content.error_example().sent
    |> String.trim_trailing()
    |> Code.highlight(:json)
    |> Phoenix.HTML.safe_to_string()
    |> String.replace(
      ~s(<span class="t-s">&quot;h2&quot;</span>),
      ~s(<span class="t-s t-err">&quot;h2&quot;</span>)
    )
    |> Phoenix.HTML.raw()
  end

  @doc "The error the renderer reports for the validation example."
  def error_reported,
    do: Content.error_example().reported |> String.trim_trailing() |> Code.highlight(:json)

  @doc "The illustration of a feature tile: `messages`, `bindings`, `rpc`, `stream` or `error`."
  attr :name, :string, required: true

  def feature_visual(%{name: "messages"} = assigns) do
    ~H"""
    <div class="viz viz-messages">
      <p class="viz-caption"><span>messages</span><span>× protocol versions</span></p>
      <table class="matrix">
        <thead>
          <tr>
            <th scope="col">message</th>
            <th scope="col">from</th>
            <th :for={version <- Content.versions()} scope="col">{version}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={message <- Content.messages()}>
            <th scope="row"><code>{message.name}</code></th>
            <td><span class={["from", "from-" <> message.from]}>{message.from}</span></td>
            <td :for={version <- Content.versions()} class="mark">
              <span :if={supports?(message, version)} class="yes" title="yes">
                <.icon name="check" class="icon icon-xs" label="yes" />
              </span>
              <span :if={!supports?(message, version)} class="no" title="no">—</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  def feature_visual(%{name: "bindings"} = assigns) do
    ~H"""
    <div class="viz viz-bindings">
      <p class="viz-caption"><span>dynamic values</span><span>→ resolved</span></p>
      <div :for={binding <- Content.bindings()} class="binding">
        <code class="binding-value">{binding.value}</code>
        <span class="binding-result"><span aria-hidden="true">→</span> {binding.result}</span>
      </div>
    </div>
    """
  end

  def feature_visual(%{name: "catalog"} = assigns) do
    ~H"""
    <div class="viz viz-catalog">
      <p class="viz-caption"><span>basic/catalog.json</span><span>v1.0</span></p>
      <ul class="tree">
        <li>
          <span class="tree-key">catalogId</span><span class="tree-value">https://a2ui.org/…/basic/catalog.json</span>
        </li>
        <li>
          <span class="tree-key">components</span><span class="tree-value"><b>{count(
            Content.components()
          )}</b>
          Text Image Icon …</span>
        </li>
        <li>
          <span class="tree-key">functions</span><span class="tree-value"><b>{count(
            Content.functions()
          )}</b>
          required regex …</span>
        </li>
        <li>
          <span class="tree-key">instructions</span><span class="tree-value">rules and examples for the model</span>
        </li>
      </ul>
    </div>
    """
  end

  def feature_visual(%{name: "tree"} = assigns) do
    ~H"""
    <div class="viz viz-tree">
      <p class="viz-caption"><span>NodeResolver</span><span>surface booking</span></p>
      <ul class="nodes">
        <li :for={{depth, type, id, shows} <- hero_tree()} class="node" style={"--depth: #{depth}"}>
          <span class="node-type">{type}</span>
          <span class="node-id">#{id}</span>
          <span :if={shows} class="node-shows">{shows}</span>
        </li>
      </ul>
    </div>
    """
  end

  def feature_visual(%{name: "rpc"} = assigns) do
    ~H"""
    <div class="viz viz-rpc">
      <p class="viz-caption"><span>function calls</span><span>v1.0</span></p>
      <div class="seq">
        <div class="seq-heads"><span>renderer</span><span>agent</span></div>
        <div :for={call <- Content.rpc()} class={["seq-row", "to-" <> call.to]}>
          <code class="seq-label">{call.name}</code>
          <span class="seq-arrow" aria-hidden="true"></span>
        </div>
      </div>
    </div>
    """
  end

  def feature_visual(%{name: "stream"} = assigns) do
    ~H"""
    <div class="viz viz-stream">
      <p class="viz-caption"><span>Parser.parse_chunk/3</span><span>three chunks</span></p>
      <ol class="chunks">
        <li :for={{chunk, index} <- Enum.with_index(Content.stream(), 1)} class="chunk">
          <span class="chunk-num">chunk {index}</span>
          <code class="chunk-text">{chunk.chunk}</code>
          <span class="chunk-parts">
            <span :for={part <- chunk.parts} class={["part", part == "text" && "part-text"]}>
              {part}
            </span>
          </span>
        </li>
      </ol>
    </div>
    """
  end

  def feature_visual(%{name: "error"} = assigns) do
    ~H"""
    <div class="viz viz-error">
      <div class="viz-pane">
        <p class="viz-caption"><span>agent sends</span><span>strict</span></p>
        <pre><code>{error_sent()}</code></pre>
      </div>
      <div class="viz-pane">
        <p class="viz-caption"><span>renderer reports</span><span class="bad">rejected</span></p>
        <pre class="wrap"><code>{error_reported()}</code></pre>
      </div>
    </div>
    """
  end
end
