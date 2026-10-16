defmodule A2UIAgent.PayloadFixer do
  @moduledoc """
  Reads a JSON payload a model wrote, fixing the mistakes models commonly
  make, as the reference SDKs' payload fixer (`parse_and_fix`) does.

      iex> A2UIAgent.PayloadFixer.parse_and_fix(~s({"text": "Hi",}))
      {:ok, [%{"text" => "Hi"}]}

  Curly quotes are made straight, raw control characters inside strings
  are accepted, and when the payload does not read, trailing commas
  before a closing bracket are dropped and it is read again. A single
  object comes back wrapped in a list.

  The direct JSON parser reads blocks with the more forgiving
  `A2UIAgent.DirectJson.JsonReader`; this fixer is for code that wants
  the reference's exact rules.
  """

  alias A2UICore.Error

  @moduledoc since: "0.1.0"

  @valid_escapes ~c(" \\ / b f n r t u)

  @doc """
  Reads `payload`. Fails with a `:parse` error that says what is wrong,
  with a hint for a backslash that is not escaped.
  """
  @spec parse_and_fix(String.t()) :: {:ok, [term()]} | {:error, Error.t()}
  def parse_and_fix(payload) when is_binary(payload) do
    normalized = normalize_quotes(payload)

    with {:error, _first} <- parse(normalized) do
      normalized |> String.replace(~r/,(?=\s*[\]}])/, "") |> parse()
    end
  end

  defp normalize_quotes(text) do
    text
    |> String.replace(["“", "”"], ~s("))
    |> String.replace(["‘", "’"], "'")
  end

  defp parse(payload) do
    case invalid_escape(payload) do
      nil ->
        case Jason.decode(escape_control_characters(payload)) do
          {:ok, list} when is_list(list) -> {:ok, list}
          {:ok, value} -> {:ok, [value]}
          {:error, error} -> {:error, failure(Exception.message(error), "")}
        end

      {offset, line, column} ->
        {:error,
         failure(
           "Invalid " <> <<92>> <> "escape: line #{line} column #{column} (char #{offset})",
           " - Help: Unescaped backslash found at line #{line}, col #{column}. In JSON " <>
             "strings, all backslashes must be escaped as '" <>
             <<92, 92>> <> "' (e.g. '" <> <<92, 92>> <> "approx', '" <> <<92, 92>> <> "alpha')."
         )}
    end
  end

  defp failure(reason, hint),
    do: Error.new(:parse, "PARSE_ERROR", "Failed to parse JSON: #{reason}#{hint}")

  # The first backslash in a string that starts no valid escape, as its
  # character offset and its 1-based line and column.
  defp invalid_escape(payload), do: scan_escapes(payload, 0, false, 1, 1)

  defp scan_escapes(<<>>, _offset, _in_string, _line, _column), do: nil

  defp scan_escapes(<<?\\, next::utf8, rest::binary>>, offset, true, line, column) do
    if next in @valid_escapes,
      do: scan_escapes(rest, offset + 2, true, line, column + 2),
      else: {offset, line, column}
  end

  defp scan_escapes(<<?", rest::binary>>, offset, in_string, line, column),
    do: scan_escapes(rest, offset + 1, not in_string, line, column + 1)

  defp scan_escapes(<<?\n, rest::binary>>, offset, in_string, line, _column),
    do: scan_escapes(rest, offset + 1, in_string, line + 1, 1)

  defp scan_escapes(<<_char::utf8, rest::binary>>, offset, in_string, line, column),
    do: scan_escapes(rest, offset + 1, in_string, line, column + 1)

  defp scan_escapes(<<_byte, rest::binary>>, offset, in_string, line, column),
    do: scan_escapes(rest, offset + 1, in_string, line, column + 1)

  # Python reads with `strict=False`, which accepts control characters
  # inside strings; JSON proper needs them escaped.
  defp escape_control_characters(payload), do: escape_controls(payload, false, [])

  defp escape_controls(<<>>, _in_string, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp escape_controls(<<?\\, next, rest::binary>>, true, acc),
    do: escape_controls(rest, true, [<<?\\, next>> | acc])

  defp escape_controls(<<?", rest::binary>>, in_string, acc),
    do: escape_controls(rest, not in_string, [?" | acc])

  defp escape_controls(<<char, rest::binary>>, true, acc) when char < 0x20 do
    hex = char |> Integer.to_string(16) |> String.pad_leading(4, "0")
    escape_controls(rest, true, [<<92, ?u>> <> hex | acc])
  end

  defp escape_controls(<<char, rest::binary>>, in_string, acc),
    do: escape_controls(rest, in_string, [char | acc])
end
