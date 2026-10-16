defmodule SiteWeb.Code do
  @moduledoc """
  Syntax highlighting for the page's code samples: Elixir, JSON and shell
  text become escaped HTML with `<span class="t-…">` around each token.

      iex> SiteWeb.Code.highlight(~s(%{"a" => 1}), :elixir) |> Phoenix.HTML.safe_to_string()
      ~s(%{<span class="t-s">&quot;a&quot;</span> <span class="t-o">=&gt;</span> <span class="t-n">1</span>})
  """

  @elixir [
    {"s", ~r/\A~[A-Za-z]?"""[\s\S]*?"""/},
    {"s", ~r/\A"""[\s\S]*?"""/},
    {"c", ~r/\A#[^\n]*/},
    {"s", ~r/\A~[A-Za-z]"(?:\\.|[^"\\])*"/},
    {"s", ~r/\A"(?:\\.|[^"\\])*"/},
    {"a", ~r/\A@[a-z_]\w*/},
    {"a", ~r/\A:[a-z_]\w*[?!]?/},
    {"a", ~r/\A[a-z_]\w*[?!]?:(?=\s)/},
    {"k",
     ~r/\A(?:defmodule|defmacro|defp|def|do|end|fn|alias|import|use|require|when|case|cond|with|if|else|true|false|nil)\b/},
    {"m", ~r/\A[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*/},
    {"w", ~r/\A[a-z_][A-Za-z0-9_]*[?!]?/},
    {"n", ~r/\A\d[\d_]*(?:\.\d+)?/},
    {"o", ~r/\A(?:\|>|->|<-|=>|<>|&|\\\\)/}
  ]

  @json [
    {"a", ~r/\A"(?:\\.|[^"\\])*"(?=\s*:)/},
    {"s", ~r/\A"(?:\\.|[^"\\])*"/},
    {"k", ~r/\A(?:true|false|null)\b/},
    {"w", ~r/\A[A-Za-z_$][\w$-]*/},
    {"n", ~r/\A-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/}
  ]

  @shell [
    {"c", ~r/\A#[^\n]*/},
    {"s", ~r/\A"(?:\\.|[^"\\])*"/},
    {"s", ~r/\A'[^']*'/}
  ]

  @doc "The highlighted HTML of `code` in `language` (`:elixir`, `:json` or `:shell`)."
  def highlight(code, language) when is_binary(code) do
    {:safe, code |> tokens(rules(language), [], []) |> Enum.map(&to_html/1)}
  end

  defp rules(:elixir), do: @elixir
  defp rules(:json), do: @json
  defp rules(:shell), do: @shell

  defp tokens("", _rules, plain, acc), do: Enum.reverse(flush(plain, acc))

  defp tokens(text, rules, plain, acc) do
    case first_match(text, rules) do
      {class, token} ->
        rest = binary_part(text, byte_size(token), byte_size(text) - byte_size(token))
        tokens(rest, rules, [], [{class, token} | flush(plain, acc)])

      nil ->
        <<char::utf8, rest::binary>> = text
        tokens(rest, rules, [<<char::utf8>> | plain], acc)
    end
  end

  # Plain words (`w`) are matched whole, so keywords are only found at the
  # start of a word.
  defp first_match(text, rules) do
    Enum.find_value(rules, fn {class, regex} ->
      case Regex.run(regex, text) do
        [token | _] when token != "" -> {class, token}
        _no_match -> nil
      end
    end)
  end

  defp flush([], acc), do: acc
  defp flush(plain, acc), do: [{nil, plain |> Enum.reverse() |> IO.iodata_to_binary()} | acc]

  defp to_html({nil, text}), do: escape(text)
  defp to_html({"w", text}), do: escape(text)
  defp to_html({class, text}), do: [~s(<span class="t-), class, ~s(">), escape(text), "</span>"]

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
