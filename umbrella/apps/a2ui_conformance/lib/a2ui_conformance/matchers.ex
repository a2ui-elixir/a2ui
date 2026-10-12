defmodule A2UIConformance.Matchers do
  @moduledoc false

  # Assertion helpers that mirror the reference Python harness exactly:
  #
  # * `assert_error/2` ports `assert_raises`: expected category (with the
  #   reference's category→exception aliasing), message matching
  #   (case-sensitive substring → per-detail substring → escaped-regex →
  #   raw-regex → the lowercase fuzzy synonym table), and the top-level
  #   `code` check (present in detail codes, the error code, or the
  #   message). One deliberate deviation, documented: the searchable
  #   string also includes detail *codes* so "missing_field" /
  #   "type_mismatch" / "extra_field" satisfy the "missing" / "type
  #   mismatch" / "extra" fuzzy synonyms naturally.
  #
  # * `subset?/2` implements the reference's contains/subset semantics
  #   for `expect`: every expected key must be present and equal (maps
  #   recurse; lists must have equal length and match pairwise).

  alias A2UICore.Error

  import ExUnit.Assertions

  # A YAML `category` expectation may accept several of our categories
  # (the Python harness maps categories to exception *tuples*).
  @category_aliases %{
    "ParseError" => [:parse, :expression],
    "ValidationError" => [:validation],
    "CatalogError" => [:catalog],
    "IntegrityError" => [:integrity, :recursion],
    "RecursionError" => [:recursion],
    "CompilationError" => [:compilation],
    "DataError" => [:data],
    "ExpressionError" => [:expression],
    "StateError" => [:state]
  }

  @doc """
  Asserts that `actual` (an `%A2UICore.Error{}` or `{:error, error}`
  tuple, plus its details) satisfies the YAML `expectError` expectation
  (a message string or a map of `category`/`message`/`code`).
  """
  @spec assert_error(term(), term()) :: true
  def assert_error(expected, actual) do
    error = unwrap(actual)
    details = error_details(error)

    {category, message, code} = parse_expectation(expected)

    assert_category!(category, error)
    assert_message!(message, error, details)
    assert_code!(code, error, details)
  end

  defp unwrap({:error, error}), do: error
  defp unwrap(%Error{} = error), do: error
  defp unwrap(other), do: other

  defp error_details(%Error{details: details}), do: Enum.map(details, &normalize_detail/1)
  defp error_details(_), do: []

  defp normalize_detail(%{code: c, message: m}), do: %{code: to_string(c), message: m}
  defp normalize_detail(detail) when is_map(detail), do: detail
  defp normalize_detail(other), do: %{code: "", message: to_string(other)}

  defp parse_expectation(expected) when is_binary(expected), do: {nil, expected, nil}

  defp parse_expectation(expected) when is_map(expected) do
    {
      expected["category"] || expected["error"],
      expected["message"],
      expected["code"]
    }
  end

  defp assert_category!(nil, _error), do: true

  defp assert_category!(category, error) when is_binary(category) do
    allowed = Map.fetch!(@category_aliases, category)

    actual =
      case error do
        %Error{category: actual_category} -> actual_category
        _other -> :unknown
      end

    unless actual in allowed do
      flunk(
        "expected error category #{inspect(category)} (any of #{inspect(allowed)}), " <>
          "got #{inspect(actual)}"
      )
    end

    true
  end

  defp assert_message!(nil, _error, _details), do: true

  defp assert_message!(message, error, details) do
    err_text = error_text(error)
    detail_messages = Enum.map(details, & &1.message)
    detail_codes = Enum.map(details, & &1.code)

    err_str =
      String.downcase(
        Enum.join([err_text, Enum.join(detail_messages, " "), Enum.join(detail_codes, " ")], " ")
      )

    msg_norm = String.downcase(message)

    matched? =
      String.contains?(err_text, message) or
        Enum.any?(detail_messages, &String.contains?(&1, message)) or
        regex_search?(escape_regex(message), err_text) or
        regex_search?(message, err_text) or
        fuzzy_match?(msg_norm, err_str)

    unless matched? do
      flunk("expected error message #{inspect(message)} not found in #{inspect(err_str)}")
    end

    true
  end

  defp assert_code!(nil, _error, _details), do: true

  defp assert_code!(code, error, details) do
    detail_codes = Enum.map(details, & &1.code)
    error_code = error_code(error)

    matched? =
      code in detail_codes or
        code == error_code or
        String.contains?(error_text(error), code)

    unless matched? do
      flunk(
        "expected error code #{inspect(code)} not found in details #{inspect(detail_codes)} " <>
          "or error code #{inspect(error_code)}"
      )
    end

    true
  end

  defp error_code(%Error{code: code}), do: code
  defp error_code(_), do: nil

  defp error_text(%Error{message: message}), do: to_string(message)
  defp error_text(other), do: inspect(other)

  defp regex_search?(pattern, subject) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, subject)
      {:error, _} -> false
    end
  rescue
    _ -> false
  end

  defp escape_regex(message), do: Regex.escape(message)

  # The reference's lowercase fuzzy synonym table: `{expected substring,
  # synonyms that satisfy it in the actual error string}`. Each entry
  # corresponds to one `or` branch of the reference's `assert_raises`.
  @fuzzy_synonyms [
    {"not of type", ["input should be", "type_mismatch", "must be a"]},
    {"is a required property", ["field required", "missing"]},
    {"additional properties are not allowed", ["extra inputs are not permitted", "extra"]},
    {"circular", ["circular", "self-reference"]},
    {"orphan", ["orphan"]},
    {"was unexpected", ["unrecognized", "unexpected"]},
    {"cannot contain child", ["cannot contain child"]},
    {"cannot be placed under parent", ["cannot be placed under parent"]},
    {"protocol version mismatch", ["mismatched protocol", "protocol version mismatch"]},
    {"mismatched protocol", ["mismatched protocol", "protocol version mismatch"]}
  ]

  defp fuzzy_match?(msg_norm, err_str) do
    Enum.any?(@fuzzy_synonyms, fn {expected, synonyms} ->
      String.contains?(msg_norm, expected) and
        Enum.any?(synonyms, &String.contains?(err_str, &1))
    end)
  end

  # ------------------------------------------------------------ expect ----

  @doc """
  Subset/contains matching for `expect` blocks: every expected key must
  be present; maps recurse; lists must be equal length and pair off;
  scalars compare with JSON equality (so `1` matches `1.0`).
  """
  @spec subset?(term(), term()) :: boolean()
  def subset?(expected, actual) when is_map(expected) and is_map(actual) do
    Enum.all?(expected, fn {key, value} ->
      Map.has_key?(actual, key) and subset?(value, Map.get(actual, key))
    end)
  end

  def subset?(expected, actual) when is_list(expected) and is_list(actual) do
    length(expected) == length(actual) and
      Enum.all?(Enum.zip(expected, actual), fn {e, a} -> subset?(e, a) end)
  end

  def subset?(expected, actual), do: json_equal?(expected, actual)

  defp json_equal?(a, b) when is_number(a) and is_number(b), do: a == b
  defp json_equal?(a, b) when is_map(a) and is_map(b), do: subset?(a, b) and subset?(b, a)
  defp json_equal?(a, b) when is_list(a) and is_list(b), do: json_list_equal?(a, b)
  defp json_equal?(a, b), do: a === b

  defp json_list_equal?(a, b) do
    length(a) == length(b) and Enum.all?(Enum.zip(a, b), fn {x, y} -> json_equal?(x, y) end)
  end

  @doc """
  Asserts the subset expectation, raising a helpful message on failure.
  """
  @spec assert_subset(term(), term(), String.t()) :: true
  def assert_subset(expected, actual, what) do
    unless subset?(expected, actual) do
      flunk(
        "#{what}:\nexpected #{inspect(expected, pretty: true)} to be a subset of\n" <>
          inspect(actual, pretty: true, limit: :infinity)
      )
    end

    true
  end
end
