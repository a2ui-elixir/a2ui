defmodule SiteWeb.CodeTest do
  use ExUnit.Case, async: true

  alias SiteWeb.Code

  doctest SiteWeb.Code
  doctest SiteWeb.Components, import: true

  defp html(code, language), do: code |> Code.highlight(language) |> Phoenix.HTML.safe_to_string()

  defp unhighlight(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  test "escapes what it highlights and what it does not" do
    assert html(~s(<a2ui-json>["<b>"]</a2ui-json>), :json) ==
             ~s(&lt;a2ui-json&gt;[<span class="t-s">&quot;&lt;b&gt;&quot;</span>]&lt;/a2ui-json&gt;)
  end

  test "JSON: keys, strings, numbers and keywords, and no numbers inside words" do
    assert html(~s({"a": "b", "n": -1.5e3, "t": true}), :json) ==
             ~s({<span class="t-a">&quot;a&quot;</span>: <span class="t-s">&quot;b&quot;</span>, ) <>
               ~s(<span class="t-a">&quot;n&quot;</span>: <span class="t-n">-1.5e3</span>, ) <>
               ~s(<span class="t-a">&quot;t&quot;</span>: <span class="t-k">true</span>})

    refute html("a2ui truest", :json) =~ "span"
  end

  test "Elixir: comments, atoms, modules, keywords and heredocs" do
    source = ~s|defmodule A.B do\n  @doc """\n  x\n  """\n  def f(:a, key: 1), do: nil # c\nend|
    highlighted = html(source, :elixir)

    assert highlighted =~ ~s(<span class="t-k">defmodule</span> <span class="t-m">A.B</span>)

    assert highlighted =~
             ~s(<span class="t-a">@doc</span> <span class="t-s">&quot;&quot;&quot;\n  x\n  &quot;&quot;&quot;</span>)

    assert highlighted =~
             ~s(<span class="t-a">:a</span>, <span class="t-a">key:</span> <span class="t-n">1</span>)

    assert highlighted =~ ~s(<span class="t-c"># c</span>)
  end

  test "shell: comments and strings" do
    assert html(~s(mix chat "hi" # say hi), :shell) ==
             ~s(mix chat <span class="t-s">&quot;hi&quot;</span> <span class="t-c"># say hi</span>)
  end

  test "keeps every character of the page's samples" do
    for sample <- Site.Content.samples() do
      assert sample.code |> html(sample.language) |> unhighlight() == sample.code
    end

    for format <- Site.Content.formats() do
      assert format.sample |> html(:json) |> unhighlight() == format.sample
    end

    hero = Site.Content.hero_message()
    assert hero |> html(:json) |> unhighlight() == hero
  end
end
